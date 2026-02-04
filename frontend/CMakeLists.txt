cmake_minimum_required(VERSION 3.24)

project(TelemetryDashboard LANGUAGES CXX)

find_package(Qt6 REQUIRED COMPONENTS Quick Charts Network QuickControls2)

qt_add_executable(dashboard_app main.cpp)

qt_add_qml_module(dashboard_app
    URI TelemetryUI
    VERSION 1.0
    QML_FILES main.qml
)

target_link_libraries(dashboard_app PRIVATE
    Qt6::Quick
    Qt6::Charts
    Qt6::Network
    Qt6::QuickControls2
)
