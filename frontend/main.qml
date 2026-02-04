import QtQuick
import QtQuick.Controls
import QtCharts

ApplicationWindow {
    visible: true
    width: 800
    height: 600
    title: "Universal Telemetry Dashboard"
    color: "#1e1e1e" // Dark Mode

    // --- Network Logic ---
    Timer {
        interval: 100 // Updated every 100ms (10 FPS)
        running: true
        repeat: true
        onTriggered: fetchData()
    }

    function fetchData() {
        var xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                if (xhr.status === 200) {
                    var json = JSON.parse(xhr.responseText);
                    updateUI(json);
                }
            }
        }
        xhr.open("GET", "http://localhost:8080/api/latest", true);
        xhr.send();
    }

    // Animation properties
    property double currentSpeed: 0
    property double currentTemp: 0

    function updateUI(data) {
        // Update tests
        lblVehicle.text = data.vehicle_id
        lblStatus.text = "GPS: " + data.gps.latitude.toFixed(4) + ", " + data.gps.longitude.toFixed(4)

        // Update animations values
        currentSpeed = data.physics.speed_kmh
        currentTemp = data.system_status.engine_temp

        // Update Chart (Adds point and scrolls)
        var axisX = chartView.axisX();
        var series = lineSeries;

        // Simulation of the passage of time
        var timestamp = new Date().getTime();
        series.append(timestamp, currentSpeed);

        if (series.count > 100) series.remove(0); // Only the last 100 points

        // Aggiorna scala asse X e Y
        axisX.min = new Date(timestamp - 10000); // Last 10 seconds
        axisX.max = new Date(timestamp);
        chartView.axisY().max = (currentSpeed > 350 ? currentSpeed + 50 : 350);
    }

    // --- Graphical UI ---
    Column {
        anchors.fill: parent
        padding: 20
        spacing: 20

        // Header
        Text {
            id: lblVehicle
            text: "CONNECTING..."
            font.pixelSize: 32
            font.bold: true
            color: "#ffffff"
        }

        Text {
            id: lblStatus
            text: "Waiting for signal..."
            font.pixelSize: 16
            color: "#aaaaaa"
        }

        // Speed section (Bar)
        Row {
            spacing: 20
            Text {
                text: Math.round(currentSpeed) + " km/h"
                font.pixelSize: 48
                color: "#00ff00"
                width: 150
            }

            // Speed bar
            Rectangle {
                width: 400; height: 40
                color: "#333"
                radius: 10
                anchors.verticalCenter: parent.verticalCenter

                Rectangle {
                    width: (parent.width * (currentSpeed / 400)) // Max 400 km/h
                    height: parent.height
                    color: currentSpeed > 300 ? "red" : (currentSpeed > 200 ? "orange" : "#00ff00")
                    radius: 10
                    Behavior on width { NumberAnimation { duration: 200 } }
                    Behavior on color { ColorAnimation { duration: 200 } }
                }
            }
        }

        // Real time graphic
        ChartView {
            id: chartView
            width: parent.width - 40
            height: 300
            theme: ChartView.ChartThemeDark
            antialiasing: true
            legend.visible: false

            DateTimeAxis {
                id: axisX
                format: "mm:ss"
                tickCount: 5
            }

            ValueAxis {
                id: axisY
                min: 0
                max: 350
                titleText: "Speed (km/h)"
            }

            LineSeries {
                id: lineSeries
                name: "Speed"
                axisX: axisX
                axisY: axisY
                width: 3
                color: "#00ff00"
            }
        }
    }
}
