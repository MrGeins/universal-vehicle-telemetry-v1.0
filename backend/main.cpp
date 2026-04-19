// ─────────────────────────────────────────────────────────────────────────────
//  Universal Telemetry Backend  –  v2.0
//  Requires: httplib.h (cpp-httplib), nlohmann/json.hpp
//  Build:    g++ -std=c++17 -O2 -o server telemetry_server.cpp -lpthread
// ─────────────────────────────────────────────────────────────────────────────
#include <httplib.h>
#include <nlohmann/json.hpp>
#include <iostream>
#include <shared_mutex>
#include <chrono>
#include <deque>
#include <iomanip>
#include <sstream>
#include <csignal>
#include <atomic>

using json = nlohmann::json;

// ── ANSI colours ──────────────────────────────────────────────────────────────
namespace col {
    constexpr auto RST  = "\033[0m";
    constexpr auto CYAN = "\033[36m";
    constexpr auto GRN  = "\033[32m";
    constexpr auto YEL  = "\033[33m";
    constexpr auto RED  = "\033[31m";
    constexpr auto DIM  = "\033[2m";
    constexpr auto BOLD = "\033[1m";
}

// ── Helpers ───────────────────────────────────────────────────────────────────
static std::string timestamp_now() {
    auto now   = std::chrono::system_clock::now();
    auto t     = std::chrono::system_clock::to_time_t(now);
    auto ms    = std::chrono::duration_cast<std::chrono::milliseconds>(
                     now.time_since_epoch()) % 1000;
    std::ostringstream ss;
    ss << std::put_time(std::localtime(&t), "%H:%M:%S")
       << '.' << std::setfill('0') << std::setw(3) << ms.count();
    return ss.str();
}

static void log(const std::string& tag, const std::string& msg,
                const char* colour = col::DIM) {
    std::cout << col::DIM << "[" << timestamp_now() << "] "
              << col::RST << colour << std::setw(10) << std::left << tag
              << col::RST << " " << msg << "\n";
}

static void set_cors(httplib::Response& res) {
    res.set_header("Access-Control-Allow-Origin",  "*");
    res.set_header("Access-Control-Allow-Headers", "Content-Type");
    res.set_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
}

static void json_ok(httplib::Response& res, const json& body) {
    set_cors(res);
    res.set_content(body.dump(), "application/json");
}

static void json_err(httplib::Response& res, int code, const std::string& msg) {
    set_cors(res);
    res.status = code;
    res.set_content(json{{"error", msg}}.dump(), "application/json");
}

// ── Shared state ──────────────────────────────────────────────────────────────
struct State {
    // Current telemetry snapshot
    json telemetry = {
        {"vehicle_id",    "WAITING..."},
        {"physics",       {{"speed_kmh", 0.0}, {"heading", 0.0}, {"acceleration", 0.0}}},
        {"gps",           {{"latitude", 0.0},  {"longitude", 0.0}, {"altitude", 0.0}}},
        {"system_status", {{"engine_temp", 0.0}, {"battery_level", 100}, {"warning_light", false}}},
        {"received_at",   ""}
    };

    // Current mission
    json mission = {
        {"status",       "IDLE"},
        {"origin",       ""},
        {"destination",  ""},
        {"vehicle_type", "UNKNOWN"},
        {"started_at",   ""}
    };

    // Circular telemetry history (last 500 frames for stats)
    static constexpr size_t HISTORY_CAP = 500;
    std::deque<json> history;

    // Server statistics
    std::atomic<uint64_t> total_frames{0};
    std::atomic<uint64_t> total_missions{0};

    mutable std::shared_mutex mtx;
} state;

// ── Graceful shutdown ─────────────────────────────────────────────────────────
static httplib::Server* g_svr = nullptr;
static void on_signal(int) {
    std::cout << "\n" << col::YEL << "[SHUTDOWN] Signal received – stopping server…"
              << col::RST << "\n";
    if (g_svr) g_svr->stop();
}

// ─────────────────────────────────────────────────────────────────────────────
int main() {
    std::signal(SIGINT,  on_signal);
    std::signal(SIGTERM, on_signal);

    httplib::Server svr;
    g_svr = &svr;

    std::cout << col::BOLD << col::CYAN
              << "╔══════════════════════════════════════╗\n"
              << "║   Universal Telemetry Backend v2.0   ║\n"
              << "╚══════════════════════════════════════╝\n"
              << col::RST;

    // ── CORS pre-flight ───────────────────────────────────────────────────────
    svr.set_pre_routing_handler([](const httplib::Request&, httplib::Response& res) {
        set_cors(res);
        return httplib::Server::HandlerResponse::Unhandled;
    });
    svr.Options(".*", [](const httplib::Request&, httplib::Response& res) {
        set_cors(res);
        res.status = 204;
    });

    // ── POST /api/telemetry ───────────────────────────────────────────────────
    svr.Post("/api/telemetry", [](const httplib::Request& req, httplib::Response& res) {
        try {
            auto data = json::parse(req.body);

            // Basic validation
            if (!data.contains("vehicle_id") ||
                !data.contains("physics")    ||
                !data.contains("gps")        ||
                !data.contains("system_status")) {
                return json_err(res, 400, "Missing required fields");
            }

            data["received_at"] = timestamp_now();

            {
                std::unique_lock lock(state.mtx);
                state.telemetry = data;
                state.history.push_back(data);
                if (state.history.size() > State::HISTORY_CAP)
                    state.history.pop_front();
            }

            ++state.total_frames;

            double spd = data["physics"].value("speed_kmh", 0.0);
            bool   wrn = data["system_status"].value("warning_light", false);

            // Compact live status line
            std::cout << "\r" << col::DIM << "[" << timestamp_now() << "] "
                      << col::RST << col::CYAN << std::setw(10) << std::left << "TELEMETRY"
                      << col::RST << " "
                      << col::GRN << std::fixed << std::setprecision(1) << spd << " km/h"
                      << col::RST << "  "
                      << col::DIM << "alt=" << data["gps"].value("altitude", 0.0) << "m"
                      << "  bat=" << data["system_status"].value("battery_level", 0) << "%"
                      << col::RST
                      << (wrn ? std::string("  ") + col::RED + "⚠ WARNING" + col::RST : "")
                      << "   " << std::flush;

            json_ok(res, {{"result", "saved"}, {"frame", state.total_frames.load()}});
        } catch (const json::exception& e) {
            log("PARSE ERR", e.what(), col::RED);
            json_err(res, 400, std::string("JSON parse error: ") + e.what());
        }
    });

    // ── GET /api/latest ───────────────────────────────────────────────────────
    svr.Get("/api/latest", [](const httplib::Request&, httplib::Response& res) {
        json snap;
        {
            std::shared_lock lock(state.mtx);
            snap = state.telemetry;
        }
        json_ok(res, snap);
    });

    // ── POST /api/mission ─────────────────────────────────────────────────────
    svr.Post("/api/mission", [](const httplib::Request& req, httplib::Response& res) {
        try {
            auto m = json::parse(req.body);

            if (!m.contains("origin") || !m.contains("destination") || !m.contains("vehicle_type"))
                return json_err(res, 400, "Missing origin, destination or vehicle_type");

            {
                std::unique_lock lock(state.mtx);
                state.mission               = m;
                state.mission["status"]     = "PENDING";
                state.mission["started_at"] = timestamp_now();
                // Reset telemetry for new mission
                state.history.clear();
                state.telemetry["vehicle_id"] = "WAITING...";
            }

            ++state.total_missions;

            std::cout << "\n";
            log("MISSION", "New mission #" + std::to_string(state.total_missions.load())
                         + "  " + m.value("origin","?")
                         + " → " + m.value("destination","?")
                         + "  [" + m.value("vehicle_type","?") + "]", col::GRN);

            json_ok(res, {{"result", "mission_accepted"}, {"id", state.total_missions.load()}});
        } catch (const json::exception& e) {
            json_err(res, 400, std::string("JSON parse error: ") + e.what());
        }
    });

    // ── GET /api/mission ──────────────────────────────────────────────────────
    svr.Get("/api/mission", [](const httplib::Request&, httplib::Response& res) {
        json m;
        {
            std::shared_lock lock(state.mtx);
            m = state.mission;
        }
        json_ok(res, m);
    });

    // ── GET /api/history ──────────────────────────────────────────────────────
    // Returns last N telemetry frames (query param: ?n=50, default 100)
    svr.Get("/api/history", [](const httplib::Request& req, httplib::Response& res) {
        size_t n = 100;
        if (req.has_param("n")) {
            try { n = std::stoul(req.get_param_value("n")); }
            catch (...) {}
        }
        n = std::min(n, State::HISTORY_CAP);

        json arr = json::array();
        {
            std::shared_lock lock(state.mtx);
            auto start = state.history.size() > n
                       ? state.history.end() - static_cast<long>(n)
                       : state.history.begin();
            for (auto it = start; it != state.history.end(); ++it)
                arr.push_back(*it);
        }
        json_ok(res, arr);
    });

    // ── GET /api/status ───────────────────────────────────────────────────────
    svr.Get("/api/status", [](const httplib::Request&, httplib::Response& res) {
        std::string mission_status, vehicle_type;
        uint64_t frames, missions;
        {
            std::shared_lock lock(state.mtx);
            mission_status = state.mission.value("status",       "IDLE");
            vehicle_type   = state.mission.value("vehicle_type", "UNKNOWN");
            frames         = state.total_frames.load();
            missions       = state.total_missions.load();
        }
        json_ok(res, {
            {"server",         "Universal Telemetry Backend"},
            {"version",        "2.0"},
            {"mission_status", mission_status},
            {"vehicle_type",   vehicle_type},
            {"total_frames",   frames},
            {"total_missions", missions},
            {"uptime_ok",      true}
        });
    });

    // ── GET /api/reset ────────────────────────────────────────────────────────
    svr.Post("/api/reset", [](const httplib::Request&, httplib::Response& res) {
        {
            std::unique_lock lock(state.mtx);
            state.mission   = {{"status","IDLE"},{"origin",""},{"destination",""},{"vehicle_type","UNKNOWN"}};
            state.telemetry = {{"vehicle_id","WAITING..."},{"physics",{{"speed_kmh",0.0}}},
                               {"gps",{{"latitude",0.0},{"longitude",0.0},{"altitude",0.0}}},
                               {"system_status",{{"engine_temp",0.0},{"battery_level",100},{"warning_light",false}}}};
            state.history.clear();
        }
        log("RESET", "State cleared", col::YEL);
        json_ok(res, {{"result", "reset_ok"}});
    });

    // ── Start ─────────────────────────────────────────────────────────────────
    log("STARTUP", "Listening on http://0.0.0.0:8080", col::GRN);
    log("STARTUP", "Endpoints: /api/telemetry  /api/latest  /api/mission  /api/history  /api/status  /api/reset", col::DIM);

    svr.listen("0.0.0.0", 8080);

    std::cout << col::YEL << "\n[EXIT] Server stopped cleanly.\n" << col::RST;
    return 0;
}
