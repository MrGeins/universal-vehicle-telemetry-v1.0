"""
Universal Telemetry Simulator v1.0

Routing matrix:
  CAR / MOTO / TRUCK / BICYCLE / PEDESTRIAN  →  OpenRouteService
  PLANE  →  ORS geocode → Nominatim nearest airport → great-circle
  TRAIN  →  HERE Transit API v8  (highSpeedTrain,intercityTrain,…)
  BUS    →  HERE Transit API v8  (bus)
  TRAM   →  HERE Transit API v8  (lightRail)

Environment variables:
  SERVER_URL    – backend URL (default: http://localhost:8080)
  ORS_API_KEY   – OpenRouteService key
  HERE_API_KEY  – HERE platform key (required for TRAIN / BUS / TRAM)
"""

import os, sys, math, time, random, logging, argparse
from datetime import datetime, timedelta
import requests
from dataclasses import dataclass
from typing import List, Dict, Optional, Tuple

# ── Config ────────────────────────────────────────────────────────────────────
CONFIG = {
    "SERVER_URL":        os.getenv("SERVER_URL", "http://localhost:8080"),
    "ORS_API_KEY":       os.getenv("ORS_API_KEY",
        "eyJvcmciOiI1YjNjZTM1OTc4NTExMTAwMDFjZjYyNDgiLCJpZCI6ImVlNmNlOGU1ZjQ2YjRlMTk4YjQyNmJiOGE5OWZjOTYxIiwiaCI6Im11cm11cjY0In0="),
    "HERE_API_KEY":      os.getenv("HERE_API_KEY", "5xfwqdwl46kIiuKNiGwC0np1foCmi2vJ703_g4E4pb0"),
    "POLL_INTERVAL_S":   2.0,
    "FRAME_INTERVAL_S":  1.0,
    "REQUEST_TIMEOUT_S": 8,
    "MAX_ROUTE_POINTS":  500,
    "AIRPORT_RADIUS_KM": 300,
}

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s.%(msecs)03d  %(levelname)-7s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("simulator")

# ── Vehicle profiles ──────────────────────────────────────────────────────────
@dataclass
class VehicleProfile:
    name:            str
    routing:         str    # "ors" | "here-transit" | "plane"
    ors_profile:     str
    here_modes:      str    # comma-separated HERE transit mode names
    max_speed_kmh:   float
    accel_kmh_s:     float
    decel_kmh_s:     float
    cruise_alt_m:    float
    climb_rate_ms:   float
    base_temp_c:     float
    temp_per_kmh:    float
    max_temp_warn:   float
    bat_drain_pct_s: float
    speed_noise:     float

PROFILES: Dict[str, VehicleProfile] = {
    "PEDESTRIAN": VehicleProfile("PEDESTRIAN","ors","foot-walking","",
        6,2,4,0,0,36.5,0.5,40,0.020,1),
    "BICYCLE":    VehicleProfile("BICYCLE","ors","cycling-regular","",
        30,5,10,0,0,25,0.05,50,0.015,2),
    "MOTO":       VehicleProfile("MOTO","ors","driving-car","",
        150,25,30,0,0,85,0.20,125,0.003,15),
    "CAR":        VehicleProfile("CAR","ors","driving-car","",
        130,12,18,0,0,70,0.18,108,0.004,6),
    "TRUCK":      VehicleProfile("TRUCK","ors","driving-hgv","",
        90,4,8,0,0,80,0.25,115,0.005,3),
    "BUS":        VehicleProfile("BUS","here-transit","","bus",
        60,5,9,0,0,75,0.22,110,0.006,4),
    "TRAM":       VehicleProfile("TRAM","here-transit","","lightRail",
        50,4,7,0,0,55,0.15,100,0.004,3),
    # FIX: intercityTrain (lowercase 'c') – HERE API is case-sensitive
    "TRAIN":      VehicleProfile("TRAIN","here-transit","",
        "highSpeedTrain,intercityTrain,regionalTrain,cityTrain",
        300,8,12,0,0,65,0.10,120,0.006,2),
    "PLANE":      VehicleProfile("PLANE","plane","","",
        870,25,35,10_500,12,55,0.07,150,0.002,10),
}

# ── Geo utils ─────────────────────────────────────────────────────────────────
def haversine_km(lat1, lon1, lat2, lon2) -> float:
    R = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a  = math.sin(dp/2)**2 + math.cos(p1)*math.cos(p2)*math.sin(dl/2)**2
    return R * 2 * math.asin(math.sqrt(a))

def bearing_deg(lat1, lon1, lat2, lon2) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dl = math.radians(lon2 - lon1)
    x  = math.sin(dl) * math.cos(p2)
    y  = math.cos(p1)*math.sin(p2) - math.sin(p1)*math.cos(p2)*math.cos(dl)
    return (math.degrees(math.atan2(x, y)) + 360) % 360

# ── HERE Flexible Polyline decoder ────────────────────────────────────────────
def _fp_char_val(c: str) -> int:
    o = ord(c)
    if 65 <= o <= 90:  return o - 65
    if 97 <= o <= 122: return o - 97 + 26
    if 48 <= o <= 57:  return o - 48 + 52
    if o == 45: return 62
    if o == 95: return 63
    raise ValueError(f"Invalid flexible-polyline char: {c!r}")

def _fp_read_uint(s: str, idx: int) -> Tuple[int, int]:
    val, shift = 0, 0
    while True:
        cv = _fp_char_val(s[idx]); idx += 1
        val |= (cv & 0x1F) << shift; shift += 5
        if (cv & 0x20) == 0: break
    return val, idx

def _fp_read_sint(s: str, idx: int) -> Tuple[int, int]:
    u, idx = _fp_read_uint(s, idx)
    return (~(u >> 1) if u & 1 else u >> 1), idx

def decode_here_polyline(encoded: str) -> List[Dict]:
    if not encoded: return []
    version = _fp_char_val(encoded[0])
    if version != 1:
        raise ValueError(f"Unsupported flexible-polyline version: {version}")
    idx = 1
    header, idx = _fp_read_uint(encoded, idx)
    precision = header & 0xF
    third_dim = (header >> 4) & 0x7
    factor    = 10 ** precision
    last_lat = last_lng = 0
    points = []
    while idx < len(encoded):
        dlat, idx = _fp_read_sint(encoded, idx)
        dlng, idx = _fp_read_sint(encoded, idx)
        last_lat += dlat; last_lng += dlng
        if third_dim and idx < len(encoded):
            _, idx = _fp_read_sint(encoded, idx)
        points.append({"lat": last_lat / factor, "lon": last_lng / factor})
    return points

# ── HERE Transit: dynamic departure time ──────────────────────────────────────
def next_service_departure() -> str:
    """
    Return an ISO-8601 datetime string that always falls on the next
    weekday between 08:00–18:00 local time.

    Why: HERE Transit returns NO results when the requested departure is
    outside service hours (nights, weekends).  By always requesting a
    future weekday morning we guarantee a valid timetable response
    regardless of when the test is actually run.
    """
    now    = datetime.now().astimezone()
    target = now.replace(hour=10, minute=0, second=0, microsecond=0)

    # If it's already past 10:00 today, move to the next day
    if now >= target:
        target += timedelta(days=1)

    # Skip Saturday (5) and Sunday (6)
    while target.weekday() >= 5:
        target += timedelta(days=1)

    # Build "+HH:MM" UTC-offset string without external dependencies
    offset_sec = int(target.utcoffset().total_seconds())
    sign       = "+" if offset_sec >= 0 else "-"
    h, rem     = divmod(abs(offset_sec), 3600)
    m          = rem // 60
    return target.strftime("%Y-%m-%dT%H:%M:%S") + f"{sign}{h:02d}:{m:02d}"

# ── Geocoding (ORS) ───────────────────────────────────────────────────────────
def geocode(query: str) -> List[float]:
    """Return [lon, lat] via ORS Geocoding."""
    r = requests.get(
        "https://api.openrouteservice.org/geocode/search",
        params={"api_key": CONFIG["ORS_API_KEY"], "text": query, "size": 1},
        timeout=CONFIG["REQUEST_TIMEOUT_S"],
    )
    r.raise_for_status()
    features = r.json().get("features", [])
    if not features:
        raise ValueError(f"Place not found: {query!r}")
    return features[0]["geometry"]["coordinates"]   # [lon, lat]

# ── Airport search via Nominatim (replaces Overpass, no API key needed) ───────
def find_nearest_airport(city_name: str, city_lat: float,
                          city_lon: float) -> Tuple[float, float, str]:
    """
    Find the nearest commercial airport to a city using Nominatim.
    Tries several query variants to maximise hit rate.
    Returns (lat, lon, display_name).
    """
    headers = {
        "User-Agent":    "UniversalTelemetrySimulator/3.1 (educational project)",
        "Accept":        "application/json",
        "Accept-Language": "it,en",
    }
    url = "https://nominatim.openstreetmap.org/search"

    # Query variants from most specific to broadest
    queries = [
        f"aeroporto {city_name}",
        f"airport {city_name}",
        f"international airport {city_name}",
        f"aeroport {city_name}",
    ]

    best: Optional[Tuple[float, float, str]] = None
    best_dist = float("inf")

    for q in queries:
        try:
            r = requests.get(
                url,
                params={"q": q, "format": "json", "limit": 10,
                        "addressdetails": 0, "extratags": 1},
                headers=headers,
                timeout=CONFIG["REQUEST_TIMEOUT_S"],
            )
            r.raise_for_status()
            results = r.json()
        except Exception as e:
            log.warning("Nominatim query %r failed: %s", q, e)
            time.sleep(0.5)
            continue

        for res in results:
            rlat = float(res.get("lat", 0))
            rlon = float(res.get("lon", 0))
            dist = haversine_km(city_lat, city_lon, rlat, rlon)
            if dist > CONFIG["AIRPORT_RADIUS_KM"]:
                continue

            # Accept if result looks like an airport
            rclass   = res.get("class", "")
            rtype    = res.get("type", "")
            disp     = res.get("display_name", "").lower()
            is_ap    = (rclass == "aeroway"
                        or rtype in ("aerodrome", "airport")
                        or "airport" in disp
                        or "aeroporto" in disp
                        or "aeroport" in disp)
            if is_ap and dist < best_dist:
                best_dist = dist
                tags = res.get("extratags") or {}
                iata = tags.get("iata", "")
                name = res.get("display_name", "Unknown Airport").split(",")[0]
                display = f"{name} ({iata})" if iata else name
                best = (rlat, rlon, display)

        if best:
            break

        time.sleep(0.5)   # Nominatim rate-limit: 1 req/s

    if best is None:
        raise ValueError(
            f"No commercial airport found within {CONFIG['AIRPORT_RADIUS_KM']} km "
            f"of {city_name!r}. Try a larger city or one with a known airport."
        )

    log.info("Airport for %r: %s  (%.1f km away)", city_name, best[2], best_dist)
    return best

# ── Route builders ────────────────────────────────────────────────────────────
def great_circle_route(start: List[float], end: List[float], n: int = 60) -> List[Dict]:
    """Linear geodesic interpolation.  start/end = [lon, lat]."""
    pts = []
    for i in range(n):
        t = i / (n - 1)
        pts.append({
            "lat":   start[1] + (end[1] - start[1]) * t,
            "lon":   start[0] + (end[0] - start[0]) * t,
            "limit": PROFILES["PLANE"].max_speed_kmh,
        })
    return pts

def _downsample(all_pts: List[Dict], speed_limit: float) -> List[Dict]:
    step = max(1, len(all_pts) // CONFIG["MAX_ROUTE_POINTS"])
    sampled = all_pts[::step]
    for p in sampled:
        p.setdefault("limit", speed_limit)
    last = all_pts[-1]
    last.setdefault("limit", speed_limit)
    if sampled[-1] != last:
        sampled.append(last)
    return sampled

def get_ors_route(start: List[float], end: List[float],
                  profile: str, max_speed: float) -> List[Dict]:
    url = (f"https://api.openrouteservice.org/v2/directions/{profile}"
           f"?api_key={CONFIG['ORS_API_KEY']}"
           f"&start={start[0]},{start[1]}&end={end[0]},{end[1]}"
           f"&extra_info=maxspeed")
    r = requests.get(url, timeout=CONFIG["REQUEST_TIMEOUT_S"]); r.raise_for_status()
    data   = r.json()
    coords = data["features"][0]["geometry"]["coordinates"]

    point_limits = [max_speed] * len(coords)
    extras = data["features"][0].get("properties", {}).get("extras", {})
    if "maxspeed" in extras:
        for seg in extras["maxspeed"].get("values", []):
            s, e, lim = seg
            if lim and lim > 0:
                for i in range(s, min(e + 1, len(coords))):
                    point_limits[i] = min(lim, max_speed)

    all_pts = [{"lat": c[1], "lon": c[0], "limit": point_limits[i]}
               for i, c in enumerate(coords)]
    return _downsample(all_pts, max_speed)

def get_here_transit_route(start: List[float], end: List[float],
                            modes: str, max_speed: float) -> List[Dict]:
    """
    Fetch transit route from HERE Transit Routing API v8.

    v3.2 fixes:
      • departure: always a future weekday 10:00 → service is guaranteed
      • return=polyline,travelSummary → use section duration to compute a
        realistic per-section speed limit (not just profile max_speed)
      • walking sections get a 5 km/h cap automatically
    """
    key = CONFIG["HERE_API_KEY"]
    if not key:
        raise ValueError(
            "HERE_API_KEY not set – required for TRAIN / BUS / TRAM. "
            "Set the HERE_API_KEY environment variable or edit CONFIG in simulator.py."
        )

    params: Dict = {
        "origin":      f"{start[1]},{start[0]}",
        "destination": f"{end[1]},{end[0]}",
        "return":      "polyline,travelSummary",   # travelSummary gives us duration per section
        "departure":   next_service_departure(),   # always within service hours
        "apikey":      key,
    }
    if modes:
        params["modes"] = modes

    r = requests.get(
        "https://transit.router.hereapi.com/v8/routes",
        params=params,
        timeout=CONFIG["REQUEST_TIMEOUT_S"],
    )

    if r.status_code != 200:
        body = r.json() if r.headers.get("content-type", "").startswith("application/json") else {}
        msg  = body.get("title") or body.get("message") or f"HTTP {r.status_code}"
        raise ValueError(f"HERE Transit API error: {msg}")

    data = r.json()
    if not data.get("routes"):
        raise ValueError(
            f"HERE Transit found no route (modes={modes!r}). "
            "Check that origin/destination are served by the requested transit mode."
        )

    all_pts: List[Dict] = []
    for section in data["routes"][0]["sections"]:
        raw = section.get("polyline", "")
        if not raw:
            continue

        pts = decode_here_polyline(raw)
        if not pts:
            continue

        # ── Per-section speed limit from travelSummary ────────────────────────
        # travelSummary.duration is in seconds; we estimate the section distance
        # from the decoded polyline and derive average speed from that.
        section_type = section.get("type", "transit")
        summary      = section.get("travelSummary", {})
        duration_s   = summary.get("duration", 0)

        if section_type == "pedestrian":
            # Walking transfer – cap at walking speed
            section_limit = 5.0
        elif duration_s > 0 and len(pts) > 1:
            # Compute chord distance along the polyline
            section_dist_km = sum(
                haversine_km(pts[i]["lat"], pts[i]["lon"],
                             pts[i + 1]["lat"], pts[i + 1]["lon"])
                for i in range(len(pts) - 1)
            )
            if section_dist_km > 0.05:
                avg_speed = section_dist_km / (duration_s / 3600)
                # Allow up to 30 % above average (accel/decel headroom)
                section_limit = min(round(avg_speed * 1.30), max_speed)
            else:
                section_limit = max_speed
        else:
            section_limit = max_speed

        section_limit = max(1.0, section_limit)
        log.debug("Section type=%s  duration=%ds  limit=%.0f km/h",
                  section_type, duration_s, section_limit)

        for pt in pts:
            pt["limit"] = section_limit

        all_pts.extend(pts)

    if not all_pts:
        raise ValueError("HERE Transit route contained no geometry.")

    return _downsample(all_pts, max_speed)


def get_plane_route(origin_name: str, dest_name: str) -> List[Dict]:
    """
    Geocode both cities, find the nearest IATA airport for each via Nominatim,
    validate they are sufficiently far apart, return a great-circle route.
    FIX v3.1: passes city_name to find_nearest_airport for targeted search.
    """
    log.info("Geocoding origin city: %r", origin_name)
    city_start = geocode(origin_name)
    log.info("Geocoding destination city: %r", dest_name)
    city_end   = geocode(dest_name)

    log.info("Searching departure airport near %r…", origin_name)
    alat1, alon1, aname1 = find_nearest_airport(origin_name, city_start[1], city_start[0])
    log.info("Searching arrival airport near %r…", dest_name)
    alat2, alon2, aname2 = find_nearest_airport(dest_name,   city_end[1],   city_end[0])

    if haversine_km(alat1, alon1, alat2, alon2) < 10:
        raise ValueError(
            f"Departure and arrival airports are the same or too close: "
            f"{aname1} ≈ {aname2}. Choose more distant cities."
        )

    log.info("Flight route: %s → %s", aname1, aname2)
    return great_circle_route([alon1, alat1], [alon2, alat2],
                              n=CONFIG["MAX_ROUTE_POINTS"])

def get_route(origin: str, destination: str, vehicle_type: str) -> List[Dict]:
    profile = PROFILES.get(vehicle_type, PROFILES["CAR"])

    if profile.routing == "plane":
        return get_plane_route(origin, destination)

    if profile.routing == "here-transit":
        log.info("Geocoding for HERE Transit route…")
        start = geocode(origin)
        end   = geocode(destination)
        log.info("Fetching HERE Transit route (modes=%s)…", profile.here_modes)
        return get_here_transit_route(start, end, profile.here_modes, profile.max_speed_kmh)

    # ORS routing (CAR, MOTO, TRUCK, BICYCLE, PEDESTRIAN)
    log.info("Geocoding via ORS…")
    start = geocode(origin)
    end   = geocode(destination)
    log.info("Fetching ORS route (profile=%s)…", profile.ors_profile)
    return get_ors_route(start, end, profile.ors_profile, profile.max_speed_kmh)

# ── Physics engine ────────────────────────────────────────────────────────────
@dataclass
class PhysicsState:
    speed:       float = 0.0
    altitude:    float = 0.0
    engine_temp: float = 0.0
    battery:     float = 100.0
    warning:     bool  = False
    heading:     float = 0.0

def update_physics(ps: PhysicsState, profile: VehicleProfile,
                   target_speed: float, dt: float,
                   total_pts: int, idx: int) -> PhysicsState:
    # Speed (accel/decel with cruise noise)
    diff = target_speed - ps.speed
    ps.speed = (min(ps.speed + profile.accel_kmh_s * dt, target_speed) if diff > 0
                else max(ps.speed + diff * 0.4, target_speed))
    if abs(ps.speed - target_speed) < 2:
        ps.speed = max(0, ps.speed + random.uniform(
            -profile.speed_noise * 0.5, profile.speed_noise * 0.5))

    # Altitude (plane only – climb / cruise / descent phases)
    if profile.cruise_alt_m > 0:
        climb_frac   = total_pts * 0.15
        descent_frac = total_pts * 0.85
        if idx < climb_frac:
            target_alt = profile.cruise_alt_m * (idx / climb_frac)
        elif idx > descent_frac:
            frac = (idx - descent_frac) / (total_pts - descent_frac)
            target_alt = profile.cruise_alt_m * max(0.0, 1 - frac)
        else:
            target_alt = profile.cruise_alt_m
        diff_alt    = target_alt - ps.altitude
        ps.altitude = max(0, ps.altitude + max(-profile.climb_rate_ms * dt * 2,
                                                min(profile.climb_rate_ms * dt, diff_alt)))
    else:
        ps.altitude = max(0, ps.altitude + random.uniform(-1.5, 1.5))

    # Engine / body temperature (first-order thermal lag)
    target_temp    = profile.base_temp_c + ps.speed * profile.temp_per_kmh
    ps.engine_temp += (target_temp + random.uniform(-1, 1) - ps.engine_temp) * 0.05

    # Battery drain (proportional to relative speed)
    speed_factor = max(0.2, ps.speed / max(1, profile.max_speed_kmh))
    ps.battery   = max(0, ps.battery - profile.bat_drain_pct_s * speed_factor * dt)

    ps.warning = ps.engine_temp > profile.max_temp_warn or ps.battery < 12.0
    return ps

# ── Server communication ──────────────────────────────────────────────────────
def post_json(server: str, path: str, payload: dict) -> bool:
    try:
        r = requests.post(f"{server}{path}", json=payload,
                          timeout=CONFIG["REQUEST_TIMEOUT_S"])
        return r.status_code in (200, 201)
    except requests.RequestException as e:
        log.warning("POST %s error: %s", path, e)
        return False

def report_error(server: str, mission: dict, msg: str) -> None:
    m = dict(mission); m["status"] = "ERROR"; m["error_message"] = msg
    post_json(server, "/api/mission", m)

def mark_running(server: str, mission: dict) -> None:
    m = dict(mission); m["status"] = "RUNNING"
    post_json(server, "/api/mission", m)

def mark_completed(server: str, mission: dict) -> None:
    m = dict(mission); m["status"] = "COMPLETED"
    post_json(server, "/api/mission", m)

def check_abort(server: str) -> bool:
    try:
        r = requests.get(f"{server}/api/mission", timeout=1)
        return r.json().get("status") in ("IDLE", "ERROR")
    except Exception:
        return False

# ── Mission runner ────────────────────────────────────────────────────────────
def run_mission(server: str, mission: dict) -> None:
    origin      = mission.get("origin",      "Milano")
    destination = mission.get("destination", "Roma")
    v_type      = mission.get("vehicle_type","CAR").upper()
    profile     = PROFILES.get(v_type, PROFILES["CAR"])

    log.info("=" * 60)
    log.info("MISSION  %s → %s  [%s]", origin, destination, profile.name)
    log.info("=" * 60)

    try:
        route = get_route(origin, destination, v_type)
    except Exception as e:
        err = str(e)
        log.error("Route calculation failed: %s", err)
        report_error(server, mission, err)
        return

    mark_running(server, mission)
    n  = len(route)
    dt = CONFIG["FRAME_INTERVAL_S"]
    ps = PhysicsState(engine_temp=profile.base_temp_c)
    v_id = f"{profile.name}-001"

    for idx, pt in enumerate(route):
        if idx % 3 == 0 and check_abort(server):
            log.info("STOP signal received – aborting mission.")
            return

        is_last     = (idx == n - 1)
        decel_start = int(n * 0.85)
        seg_limit   = pt.get("limit", profile.max_speed_kmh)

        if is_last:
            target_spd = 0.0
        elif idx > decel_start:
            progress   = (idx - decel_start) / max(1, n - decel_start)
            target_spd = seg_limit * max(0.0, 1 - progress)
        else:
            target_spd = seg_limit

        if idx < n - 1:
            nxt = route[idx + 1]
            ps.heading = bearing_deg(pt["lat"], pt["lon"], nxt["lat"], nxt["lon"])

        ps = update_physics(ps, profile, target_spd, dt, n, idx)

        if is_last:
            ps.speed = 0.0
            if profile.cruise_alt_m > 0: ps.altitude = 0.0

        payload = {
            "vehicle_id":   v_id,
            "vehicle_type": v_type,
            "physics": {
                "speed_kmh":    round(ps.speed,    2),
                "heading":      round(ps.heading,  1),
                "acceleration": round((target_spd - ps.speed) / dt, 3),
            },
            "gps": {
                "latitude":  round(pt["lat"],   6),
                "longitude": round(pt["lon"],   6),
                "altitude":  round(ps.altitude, 1),
            },
            "system_status": {
                "engine_temp":    round(ps.engine_temp, 1),
                "battery_level":  round(ps.battery,     1),
                "warning_light":  ps.warning,
                "mission_status": "COMPLETED" if is_last else "RUNNING",
            },
        }

        ok  = post_json(server, "/api/telemetry", payload)
        log.info("[%3d/%d] %s  %.5f,%.5f  %5.0f km/h  alt=%5.0f m"
                 "  T=%.1f°C  bat=%.0f%%%s",
                 idx + 1, n, "✓" if ok else "✗",
                 pt["lat"], pt["lon"],
                 ps.speed, ps.altitude, ps.engine_temp, ps.battery,
                 "  ⚠" if ps.warning else "")

        time.sleep(dt)

    mark_completed(server, mission)
    log.info("MISSION COMPLETE ✓  %d frames transmitted", n)
    log.info("=" * 60)

# ── Main polling loop ─────────────────────────────────────────────────────────
def main(server: str) -> None:
    log.info("Simulator v3.1  →  %s", server)
    log.info("Polling every %.1f s…", CONFIG["POLL_INTERVAL_S"])
    while True:
        try:
            r = requests.get(f"{server}/api/mission",
                             timeout=CONFIG["REQUEST_TIMEOUT_S"])
            if r.status_code == 200 and r.json().get("status") == "PENDING":
                run_mission(server, r.json())
        except requests.RequestException as e:
            log.debug("Poll error: %s", e)
        except KeyboardInterrupt:
            log.info("Simulator stopped."); sys.exit(0)
        time.sleep(CONFIG["POLL_INTERVAL_S"])

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Universal Telemetry Simulator v3.1")
    parser.add_argument("--server", default=CONFIG["SERVER_URL"])
    main(parser.parse_args().server)
