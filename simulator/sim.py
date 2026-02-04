import requests
import time
import random
#import math

# Configuration
SERVER_URL = "http://localhost:8080/api/telemetry"
VEHICLE_ID = "FRECCIAROSSA-1000"
VEHICLE_TYPE = "TRAIN" # "PLANE" or "BUS"

# Initial state
speed = 0.0
latitude = 45.4642  # Milan
longitude = 9.1900
engine_temp = 50.0

print(f"--- {VEHICLE_ID} Simulator Started ---")
print("Press CTRL+C to stop")

try:
    while True:
        # Physics Simulation
        # If the speed is too low, it speed up. Otherwise, slow down a bit (fluctuation)
        if speed < 300:
            speed += random.uniform(0, 5) # Speed up
        else:
            speed -= random.uniform(0, 2) # Air Resistence

        # Temperature rise with speed
        engine_temp = 50 + (speed * 0.1) + random.uniform(-1, 1)

        # Move a little bit the GPS (to Est)
        longitude += 0.001

        # Create the JSON
        payload = {
            "vehicle_id": VEHICLE_ID,
            "vehicle_type": VEHICLE_TYPE,
            "timestamp": time.time(),
            "gps": {
                "latitude": latitude,
                "longitude": longitude,
                "altitude": 120.0
            },
            "physics": {
                "speed_kmh": round(speed, 2),
                "heading": 90,
                "acceleration": 0.2
            },
            "system_status": {
                "engine_temp": round(engine_temp, 1),
                "battery_level": 98,
                "warning_light": False
            }
        }

        # Sent to backend (C++)
        try:
            response = requests.post(SERVER_URL, json=payload)
            if response.status_code == 200:
                print(f"[TX] Sent: {speed:.1f} km/h | Temp: {engine_temp:.1f}°C")
            else:
                print(f"[ERR] Server Error: {response.status_code}")
        except Exception as e:
            print(f"[ERR] Server not reachable: {e}")

        # Wait 1 second (1 Hz)
        time.sleep(1)

except KeyboardInterrupt:
    print("\nSimulation stoppped.")
