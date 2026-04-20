// ─────────────────────────────────────────────────────────────────────────────
//  Universal Telemetry Backend v1.0
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

namespace col {
    constexpr auto RST  = "\033[0m";
    constexpr auto CYAN = "\033[36m";
    constexpr auto GRN  = "\033[32m";
    constexpr auto YEL  = "\033[33m";
    constexpr auto RED  = "\033[31m";
    constexpr auto DIM  = "\033[2m";
    constexpr auto BOLD = "\033[1m";
}

static std::string timestamp_now() {
    auto now = std::chrono::system_clock::now();
    auto t   = std::chrono::system_clock::to_time_t(now);
    auto ms  = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()) % 1000;
    std::ostringstream ss;
    ss << std::put_time(std::localtime(&t), "%H:%M:%S")
       << '.' << std::setfill('0') << std::setw(3) << ms.count();
    return ss.str();
}

static void log_msg(const std::string& tag, const std::string& msg, const char* colour = col::DIM) {
    std::cout << col::DIM << "[" << timestamp_now() << "] "
              << col::RST << colour << std::setw(12) << std::left << tag
              << col::RST << " " << msg << "\n";
}

static void set_cors(httplib::Response& res) {
    res.set_header("Access-Control-Allow-Origin",  "*");
    res.set_header("Access-Control-Allow-Headers", "Content-Type");
    res.set_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
}
static void json_ok(httplib::Response& res, const json& body) {
    set_cors(res); res.set_content(body.dump(), "application/json");
}
static void json_err(httplib::Response& res, int code, const std::string& msg) {
    set_cors(res); res.status = code;
    res.set_content(json{{"error", msg}}.dump(), "application/json");
}

// ── Shared state ──────────────────────────────────────────────────────────────
struct State {
    json telemetry = {
        {"vehicle_id",    "WAITING..."},
        {"physics",       {{"speed_kmh",0.0},{"heading",0.0},{"acceleration",0.0}}},
        {"gps",           {{"latitude",0.0},{"longitude",0.0},{"altitude",0.0}}},
        {"system_status", {{"engine_temp",0.0},{"battery_level",100},{"warning_light",false}}},
        {"received_at",   ""}
    };
    json mission = {
        {"status","IDLE"},{"origin",""},{"destination",""},
        {"vehicle_type","UNKNOWN"},{"error_message",""},{"started_at",""}
    };
    static constexpr size_t HISTORY_CAP = 500;
    std::deque<json> history;
    std::atomic<uint64_t> total_frames{0};
    std::atomic<uint64_t> total_missions{0};
    mutable std::shared_mutex mtx;
} state;

static httplib::Server* g_svr = nullptr;
static void on_signal(int) {
    std::cout << "\n" << col::YEL << "[SHUTDOWN] Stopping…" << col::RST << "\n";
    if (g_svr) g_svr->stop();
}

int main() {
    std::signal(SIGINT,  on_signal);
    std::signal(SIGTERM, on_signal);

    httplib::Server svr;
    g_svr = &svr;

    std::cout << col::BOLD << col::CYAN
              << "╔════════════════════════════════════════╗\n"
              << "║       Universal Telemetry Backend      ║\n"
              << "╚════════════════════════════════════════╝\n" << col::RST;

    svr.set_pre_routing_handler([](const httplib::Request&, httplib::Response& res) {
        set_cors(res); return httplib::Server::HandlerResponse::Unhandled;
    });
    svr.Options(".*", [](const httplib::Request&, httplib::Response& res) {
        set_cors(res); res.status = 204;
    });

    // ── POST /api/telemetry ───────────────────────────────────────────────────
    // Reject when mission is not PENDING/RUNNING – prevents stale simulators
    // from re-animating the dashboard after a STOP or following an error.
    svr.Post("/api/telemetry", [](const httplib::Request& req, httplib::Response& res) {
        {
            std::shared_lock lock(state.mtx);
            auto st = state.mission.value("status","IDLE");
            if (st == "IDLE" || st == "ERROR" || st == "COMPLETED")
                return json_err(res, 409, "No active mission");
        }
        try {
            auto data = json::parse(req.body);
            if (!data.contains("vehicle_id") || !data.contains("physics") ||
                !data.contains("gps")        || !data.contains("system_status"))
                return json_err(res, 400, "Missing required fields");

            data["received_at"] = timestamp_now();
            {
                std::unique_lock lock(state.mtx);
                state.telemetry = data;
                state.history.push_back(data);
                if (state.history.size() > State::HISTORY_CAP) state.history.pop_front();
            }
            ++state.total_frames;

            double spd = data["physics"].value("speed_kmh",0.0);
            bool   wrn = data["system_status"].value("warning_light",false);
            std::cout << "\r" << col::DIM << "[" << timestamp_now() << "] " << col::RST
                      << col::CYAN << std::setw(12) << std::left << "TELEMETRY" << col::RST
                      << " " << col::GRN << std::fixed << std::setprecision(1) << spd << " km/h"
                      << col::RST << "  " << col::DIM
                      << "alt=" << data["gps"].value("altitude",0.0) << "m"
                      << "  bat=" << data["system_status"].value("battery_level",0) << "%"
                      << col::RST
                      << (wrn ? std::string("  ")+col::RED+"⚠ WARN"+col::RST : "")
                      << "   " << std::flush;

            json_ok(res, {{"result","saved"},{"frame",state.total_frames.load()}});
        } catch (const json::exception& e) {
            log_msg("PARSE ERR", e.what(), col::RED);
            json_err(res, 400, std::string("JSON error: ") + e.what());
        }
    });

    // ── GET /api/latest ───────────────────────────────────────────────────────
    svr.Get("/api/latest", [](const httplib::Request&, httplib::Response& res) {
        json snap; { std::shared_lock lock(state.mtx); snap = state.telemetry; }
        json_ok(res, snap);
    });

    // ── POST /api/mission ─────────────────────────────────────────────────────
    // PENDING  – new mission from QML
    // RUNNING  – simulator has started transmitting
    // ERROR    – simulator failed (carries error_message)
    // COMPLETED– simulator finished successfully
    svr.Post("/api/mission", [](const httplib::Request& req, httplib::Response& res) {
        try {
            auto m = json::parse(req.body);
            auto new_status = m.value("status","PENDING");
            bool is_new       = (new_status == "PENDING");
            bool is_error     = (new_status == "ERROR");
            bool is_completed = (new_status == "COMPLETED");

            if (is_new && (!m.contains("origin")||!m.contains("destination")||!m.contains("vehicle_type")))
                return json_err(res, 400, "Missing origin, destination or vehicle_type");

            {
                std::unique_lock lock(state.mtx);
                if (is_new) {
                    state.mission               = m;
                    state.mission["status"]     = "PENDING";
                    state.mission["error_message"] = "";
                    state.mission["started_at"] = timestamp_now();
                    state.history.clear();
                    state.telemetry["vehicle_id"] = "WAITING...";
                    ++state.total_missions;
                } else {
                    state.mission["status"] = new_status;
                    state.mission["error_message"] = is_error
                        ? m.value("error_message","Unknown error") : "";
                }
            }

            std::cout << "\n";
            if (is_new)
                log_msg("MISSION","New #"+std::to_string(state.total_missions.load())
                    +"  "+m.value("origin","?")+" → "+m.value("destination","?")
                    +"  ["+m.value("vehicle_type","?")+"]", col::GRN);
            else if (is_error)
                log_msg("SIM ERROR", m.value("error_message","?"), col::RED);
            else if (is_completed)
                log_msg("COMPLETED","Mission finished successfully.", col::GRN);

            json_ok(res, {{"result","ok"},{"status",new_status}});
        } catch (const json::exception& e) {
            json_err(res, 400, std::string("JSON error: ") + e.what());
        }
    });

    // ── GET /api/mission ──────────────────────────────────────────────────────
    svr.Get("/api/mission", [](const httplib::Request&, httplib::Response& res) {
        json m;
        {
            std::shared_lock lock(state.mtx);
            m = state.mission;
            if (!m.contains("error_message")) m["error_message"] = "";
        }
        json_ok(res, m);
    });

    // ── GET /api/history ──────────────────────────────────────────────────────
    svr.Get("/api/history", [](const httplib::Request& req, httplib::Response& res) {
        size_t n = 100;
        if (req.has_param("n")) { try { n = std::stoul(req.get_param_value("n")); } catch(...){} }
        n = std::min(n, State::HISTORY_CAP);
        json arr = json::array();
        {
            std::shared_lock lock(state.mtx);
            auto it = state.history.size() > n
                    ? state.history.end() - static_cast<long>(n) : state.history.begin();
            for (; it != state.history.end(); ++it) arr.push_back(*it);
        }
        json_ok(res, arr);
    });

    // ── GET /api/status ───────────────────────────────────────────────────────
    svr.Get("/api/status", [](const httplib::Request&, httplib::Response& res) {
        std::string ms,vt,err; uint64_t fr,mi;
        {
            std::shared_lock lock(state.mtx);
            ms = state.mission.value("status","IDLE");
            vt = state.mission.value("vehicle_type","UNKNOWN");
            err= state.mission.value("error_message","");
            fr = state.total_frames.load(); mi = state.total_missions.load();
        }
        json_ok(res, {{"server","Universal Telemetry Backend"},{"version","3.0"},
            {"mission_status",ms},{"vehicle_type",vt},{"error_message",err},
            {"total_frames",fr},{"total_missions",mi}});
    });

    // ── POST /api/reset ───────────────────────────────────────────────────────
    svr.Post("/api/reset", [](const httplib::Request&, httplib::Response& res) {
        {
            std::unique_lock lock(state.mtx);
            state.mission = {{"status","IDLE"},{"origin",""},{"destination",""},
                {"vehicle_type","UNKNOWN"},{"error_message",""},{"started_at",""}};
            state.telemetry = {{"vehicle_id","IDLE"},
                {"physics",{{"speed_kmh",0.0},{"heading",0.0},{"acceleration",0.0}}},
                {"gps",{{"latitude",0.0},{"longitude",0.0},{"altitude",0.0}}},
                {"system_status",{{"engine_temp",0.0},{"battery_level",100},{"warning_light",false}}}};
            state.history.clear();
        }
        std::cout << "\n";
        log_msg("RESET","State cleared – mission aborted.", col::YEL);
        json_ok(res, {{"result","reset_ok"}});
    });

    log_msg("STARTUP","Listening on http://0.0.0.0:8080", col::GRN);
    log_msg("STARTUP","Endpoints: telemetry | latest | mission | history | status | reset", col::DIM);
    svr.listen("0.0.0.0", 8080);
    std::cout << col::YEL << "\n[EXIT] Server stopped cleanly.\n" << col::RST;
    return 0;
}
