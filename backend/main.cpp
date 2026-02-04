#include <httplib.h>
#include <mutex>
#include <nlohmann/json.hpp>
#include <iostream>

using json = nlohmann::json;

// Shared memory
// saving the last vehicle status
json last_telemetry_data = {
    {"vehicle_id", "WAITING..."},
    {"physics", {{"speed_kmh", 0.0}}},
    {"gps", {{"altitude", 0.0}}}
};

// mutually exclusive access to threads
std::mutex data_mutex;

int main() {
    httplib::Server svr;

    // CORS Configuration
    svr.set_pre_routing_handler([](const httplib::Request& req, httplib::Response& res) {
        res.set_header("Access-Control-Allow-Origin", "*");
        return httplib::Server::HandlerResponse::Unhandled;
    });

    std::cout << "--- Universal Telemetry Backend ---" << std::endl;

    // Endpoint POST (Telemetry received data)
    svr.Post("/api/telemetry", [](const httplib::Request& req, httplib::Response& res) {
        try {
            auto data = json::parse(req.body);
            
            {
                std::lock_guard<std::mutex> lock(data_mutex);
                last_telemetry_data = data;
            }

            std::cout << "\r[DATA] Updated: " << data["physics"]["speed_kmh"] << " km/h   " << std::flush;

            res.set_content("{\"result\": \"saved\"}", "application/json");
        } catch (...) {
            res.status = 400;
        }
    });

    // Endpoint GET (Status check)
    svr.Get("/api/latest", [](const httplib::Request&, httplib::Response& res) {
        json response;
        {
            std::lock_guard<std::mutex> lock(data_mutex);
            response = last_telemetry_data;
        }
        res.set_content(response.dump(), "application/json");
    });

    // Start on port 8080
    std::cout << "Server in listening on http://localhost:8080 ..." << std::endl;
    svr.listen("0.0.0.0", 8080);

    return 0;
}
