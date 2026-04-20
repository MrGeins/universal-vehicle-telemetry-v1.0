cmake_minimum_required(VERSION 3.16)

project(TelemetryDashboard LANGUAGES CXX)

set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC ON)

find_package(Qt6 REQUIRED COMPONENTS Quick Charts Network QuickControls2 Location Positioning)

qt_add_executable(dashboard_app dashboard.cpp)

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
    Qt6::Location
    Qt6::Positioning
)
