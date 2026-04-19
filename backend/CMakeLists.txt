cmake_minimum_required(VERSION 3.16)

project(TelemetryBackend)

include(FetchContent)

# --- JSON library ---
FetchContent_Declare(
    json
    URL https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz
)
FetchContent_MakeAvailable(json)

# --- HTTP Server library (cpp-httplib) ---
FetchContent_Declare(
    httplib
    URL https://github.com/yhirose/cpp-httplib/archive/refs/tags/v0.14.3.tar.gz
)
FetchContent_MakeAvailable(httplib)

# --- Runnable ---
add_executable(telemetry_server main.cpp)

# --- Link the library ---
if(WIN32)
    # On Windows -> ws2_32
    target_link_libraries(telemetry_server PRIVATE nlohmann_json::nlohmann_json httplib::httplib ws2_32)
else()
    # On Linux -> pthread
    target_link_libraries(telemetry_server PRIVATE nlohmann_json::nlohmann_json httplib::httplib pthread)
endif()