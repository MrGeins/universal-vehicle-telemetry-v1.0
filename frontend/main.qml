// ─────────────────────────────────────────────────────────────────────────────
//  Universal Telemetry Frontend v1.0
// ─────────────────────────────────────────────────────────────────────────────
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtCharts
import QtPositioning
import QtLocation

ApplicationWindow {
    id: rootWindow
    visible: true
    minimumWidth: 900; minimumHeight: 600
    width: 1200; height: 800
    title: "Universal Telemetry Dashboard"
    color: "#080c14"

    // ── Palette ────────────────────────────────────────────────────────────────
    readonly property color clrBg:       "#080c14"
    readonly property color clrSurface:  "#0d1421"
    readonly property color clrCard:     "#111928"
    readonly property color clrBorder:   "#1e2d45"
    readonly property color clrAccent:   "#00d4ff"
    readonly property color clrGreen:    "#00e676"
    readonly property color clrRed:      "#ff3d5a"
    readonly property color clrAmber:    "#ffab00"
    readonly property color clrTextPrim: "#e8f0fe"
    readonly property color clrTextSec:  "#5c7a9e"

    // ── Telemetry state ────────────────────────────────────────────────────────
    property double  currentSpeed:     0
    property double  currentTemp:      0
    property double  currentBattery:   100
    property double  currentAltitude:  0
    property double  currentHeading:   0
    property bool    isWarning:        false
    property string  vehicleId:        "IDLE"
    property var     currentCoords:    QtPositioning.coordinate(45.4642, 9.1900)
    property bool    telemetryActive:  false
    property int     dataPoints:       0
    property double  totalDistanceKm:  0
    property var     lastCoords:       null
    // battery starts full – avoids red "0%" card at idle

    // ── Mission / UI state ────────────────────────────────────────────────────
    property string vehicleType:      "CAR"
    property string activeVehicleType:"CAR"   // drives UI labels; follows ComboBox when idle
    property string missionStatus:    "IDLE"  // polled from /api/mission
    property string errorMessage:     ""
    property bool   errorVisible:     false

    // isLoading: true between START click and first telemetry frame (or error)
    readonly property bool isLoading:
        (missionStatus === "PENDING" || missionStatus === "RUNNING") &&
        !telemetryActive && !errorVisible

    // Button should appear as STOP whenever we're not fully idle
    readonly property bool showStop:
        telemetryActive || isLoading || errorVisible

    // ── Per-vehicle UI metadata ────────────────────────────────────────────────
    property var vehicleMeta: ({
        "PEDESTRIAN":{ icon:"🚶", label:"Pedone",  tempLabel:"BODY TEMP",   batLabel:"STAMINA",  speedWarn:999, tempWarn:39,  chartMax:15   },
        "BICYCLE":   { icon:"🚲", label:"Bici",    tempLabel:"BODY TEMP",   batLabel:"STAMINA",  speedWarn:999, tempWarn:40,  chartMax:50   },
        "MOTO":      { icon:"🏍️",label:"Moto",    tempLabel:"ENGINE TEMP", batLabel:"BATTERY",  speedWarn:140, tempWarn:125, chartMax:200  },
        "CAR":       { icon:"🚗", label:"Auto",    tempLabel:"ENGINE TEMP", batLabel:"BATTERY",  speedWarn:120, tempWarn:108, chartMax:160  },
        "TRUCK":     { icon:"🚚", label:"Camion",  tempLabel:"ENGINE TEMP", batLabel:"BATTERY",  speedWarn:90,  tempWarn:115, chartMax:110  },
        "BUS":       { icon:"🚌", label:"Bus",     tempLabel:"ENGINE TEMP", batLabel:"BATTERY",  speedWarn:70,  tempWarn:110, chartMax:80   },
        "TRAM":      { icon:"🚋", label:"Tram",    tempLabel:"ENGINE TEMP", batLabel:"BATTERY",  speedWarn:60,  tempWarn:100, chartMax:70   },
        "TRAIN":     { icon:"🚆", label:"Treno",   tempLabel:"ENGINE TEMP", batLabel:"BATTERY",  speedWarn:299, tempWarn:120, chartMax:350  },
        "PLANE":     { icon:"✈️",label:"Aereo",   tempLabel:"ENGINE TEMP", batLabel:"BATTERY",  speedWarn:800, tempWarn:150, chartMax:1000 }
    })

    function meta(key) {
        var m = vehicleMeta[activeVehicleType]; if (!m) m = vehicleMeta["CAR"]
        return m[key]
    }

    // ── Haversine ──────────────────────────────────────────────────────────────
    function haversineKm(c1, c2) {
        if (!c1 || !c2) return 0
        var R=6371, p1=c1.latitude*Math.PI/180, p2=c2.latitude*Math.PI/180
        var dp=(c2.latitude-c1.latitude)*Math.PI/180
        var dl=(c2.longitude-c1.longitude)*Math.PI/180
        var a=Math.sin(dp/2)*Math.sin(dp/2)+Math.cos(p1)*Math.cos(p2)*Math.sin(dl/2)*Math.sin(dl/2)
        return R*2*Math.atan2(Math.sqrt(a),Math.sqrt(1-a))
    }

    // ── Full dashboard reset ───────────────────────────────────────────────────
    function resetDashboard() {
        currentSpeed=0; currentTemp=0; currentBattery=100
        currentAltitude=0; currentHeading=0; isWarning=false
        vehicleId="IDLE"; telemetryActive=false
        dataPoints=0; totalDistanceKm=0; lastCoords=null
        errorVisible=false; errorMessage=""
        missionStatus="IDLE"
        routeLine.path=[]
        lineSeries.removePoints(0, lineSeries.count)
        var now=new Date().getTime()
        chartView.axisX().min=new Date(now-12000)
        chartView.axisX().max=new Date(now)
        activeVehicleType=comboVehicle.currentValue
        axisY.max=vehicleMeta[comboVehicle.currentValue]
                 ? vehicleMeta[comboVehicle.currentValue]["chartMax"] : 160
    }

    // ── Telemetry polling (100 ms) ─────────────────────────────────────────────
    Timer { interval:100; running:true; repeat:true; onTriggered: fetchTelemetry() }

    // ── Mission status polling (1 s) – detects ERROR, COMPLETED ──────────────
    Timer { interval:1000; running:true; repeat:true; onTriggered: fetchMissionStatus() }

    function fetchTelemetry() {
        var xhr=new XMLHttpRequest()
        xhr.onreadystatechange=function(){
            if(xhr.readyState===XMLHttpRequest.DONE && xhr.status===200)
                updateUI(JSON.parse(xhr.responseText))
        }
        xhr.open("GET","http://localhost:8080/api/latest",true); xhr.send()
    }

    function fetchMissionStatus() {
        var xhr=new XMLHttpRequest()
        xhr.onreadystatechange=function(){
            if(xhr.readyState!==XMLHttpRequest.DONE || xhr.status!==200) return
            var m=JSON.parse(xhr.responseText)
            var backendStatus = m.status || "IDLE"

            // Guard: if we already reset locally (missionStatus="IDLE"),
            // ignore any stale ERROR the backend might still be returning
            // while the reset XHR is still in flight.
            if(missionStatus === "IDLE" && backendStatus === "ERROR") return

            missionStatus = backendStatus
            if(backendStatus === "ERROR"){
                errorMessage = m.error_message || "Unknown simulator error"
                errorVisible = true
                telemetryActive = false
            }
        }
        xhr.open("GET","http://localhost:8080/api/mission",true); xhr.send()
    }

    function updateUI(data) {
        if(!data||!data.vehicle_id) return
        if(data.vehicle_id==="WAITING..."||data.vehicle_id==="IDLE") return
        if(!data.gps||data.gps.latitude===undefined) return
        if(data.system_status&&data.system_status.mission_status==="COMPLETED"){
            telemetryActive=false; return
        }

        vehicleType=data.vehicle_type||"CAR"
        activeVehicleType=vehicleType
        currentSpeed=data.physics.speed_kmh
        currentTemp=data.system_status.engine_temp
        currentBattery=data.system_status.battery_level
        currentAltitude=data.gps.altitude
        currentHeading=(data.physics&&data.physics.heading)||0
        isWarning=data.system_status.warning_light
        vehicleId=data.vehicle_id
        telemetryActive=true; dataPoints++

        var newCoords=QtPositioning.coordinate(data.gps.latitude,data.gps.longitude)
        if(lastCoords!==null){
            var delta=haversineKm(lastCoords,newCoords)
            if(delta<50) totalDistanceKm+=delta
        }
        lastCoords=newCoords; currentCoords=newCoords
        mapView.center=currentCoords
        routeLine.addCoordinate(currentCoords)
        if(dataPoints===1) mapView.zoomLevel=14

        axisY.max=meta("chartMax")
        var ts=new Date().getTime()
        lineSeries.append(ts,currentSpeed)
        if(lineSeries.count>120) lineSeries.remove(0)
        chartView.axisX().min=new Date(ts-12000)
        chartView.axisX().max=new Date(ts)
    }

    // ── Warning pulse ──────────────────────────────────────────────────────────
    SequentialAnimation {
        id: warnAnim; loops:Animation.Infinite; running:isWarning
        NumberAnimation { target:warnDot; property:"opacity"; to:0.1; duration:500 }
        NumberAnimation { target:warnDot; property:"opacity"; to:1.0; duration:500 }
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  ROOT LAYOUT
    // ══════════════════════════════════════════════════════════════════════════
    ColumnLayout {
        anchors.fill:parent; spacing:0

        // ── Header ────────────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth:true; height:52; color:clrSurface
            Rectangle { anchors.bottom:parent.bottom; width:parent.width; height:1; color:clrBorder }

            RowLayout {
                anchors { fill:parent; leftMargin:20; rightMargin:20 } spacing:12

                Row {
                    spacing:10
                    Rectangle { width:8; height:32; radius:2; color:clrAccent; anchors.verticalCenter:parent.verticalCenter }
                    Column {
                        anchors.verticalCenter:parent.verticalCenter; spacing:1
                        Text { text:"TELEMETRY";           color:clrAccent;  font{pixelSize:13;letterSpacing:4;weight:Font.Bold} }
                        Text { text:"UNIVERSAL DASHBOARD"; color:clrTextSec; font{pixelSize:8;letterSpacing:2} }
                    }
                }
                Item { Layout.fillWidth:true }

                Row {
                    spacing:8; visible:telemetryActive
                    Rectangle {
                        id:liveDot; width:8; height:8; radius:4; color:clrGreen
                        anchors.verticalCenter:parent.verticalCenter
                        SequentialAnimation on opacity {
                            loops:Animation.Infinite
                            NumberAnimation{to:0.2;duration:700} NumberAnimation{to:1.0;duration:700}
                        }
                    }
                    Text { text:"LIVE"; color:clrGreen; font{pixelSize:11;letterSpacing:3;weight:Font.Bold} anchors.verticalCenter:parent.verticalCenter }
                }
                Rectangle { width:1; height:28; color:clrBorder; visible:telemetryActive }

                // Vehicle badge – icon + label react to ComboBox selection immediately
                Rectangle {
                    height:28; width:hdrRow.implicitWidth+24
                    color:Qt.rgba(0,0.83,1,0.08); border{color:clrAccent;width:1} radius:4
                    Row {
                        id:hdrRow; anchors.centerIn:parent; spacing:6
                        Text { text:meta("icon"); font.pixelSize:14; anchors.verticalCenter:parent.verticalCenter }
                        Text {
                            id:lblVehicle
                            text:telemetryActive ? vehicleId : meta("label").toUpperCase()
                            color:clrAccent; font{pixelSize:12;letterSpacing:2;weight:Font.Bold}
                            anchors.verticalCenter:parent.verticalCenter
                        }
                    }
                }
                Text { text:dataPoints+" pts"; color:clrTextSec; font{pixelSize:11;letterSpacing:1} anchors.verticalCenter:parent.verticalCenter; visible:telemetryActive }
            }
        }

        // ── Body row ──────────────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth:true; Layout.fillHeight:true; spacing:0

            // ── Sidebar ───────────────────────────────────────────────────────
            Rectangle {
                Layout.fillHeight:true; Layout.preferredWidth:320; color:clrSurface
                Rectangle { anchors{right:parent.right;top:parent.top;bottom:parent.bottom} width:1; color:clrBorder }

                ColumnLayout {
                    anchors { fill:parent; margins:16 } spacing:10

                    // ── Mission Control card ──────────────────────────────────
                    Rectangle {
                        Layout.fillWidth:true
                        height:ctrlCol.implicitHeight+24; color:clrCard
                        border{color:clrBorder;width:1} radius:8

                        Column {
                            id:ctrlCol; anchors{fill:parent;margins:12} spacing:10

                            Row {
                                spacing:6
                                Rectangle{width:3;height:12;radius:1.5;color:clrAccent;anchors.verticalCenter:parent.verticalCenter}
                                Text{text:"TELEMETRY CONTROL";color:clrTextSec;font{pixelSize:9;letterSpacing:2.5}anchors.verticalCenter:parent.verticalCenter}
                            }

                            RowLayout { width:parent.width; spacing:8
                                TextField {
                                    id:inputOrigin; Layout.fillWidth:true
                                    placeholderText:"Partenza"; font.pixelSize:12
                                    color:clrTextPrim; placeholderTextColor:clrTextSec; leftPadding:10
                                    enabled:!showStop
                                    background:Rectangle{
                                        color:"#0a1525";radius:5
                                        border{color:inputOrigin.activeFocus?clrAccent:clrBorder;width:1}
                                        opacity:inputOrigin.enabled?1.0:0.4
                                    }
                                }
                                TextField {
                                    id:inputDest; Layout.fillWidth:true
                                    placeholderText:"Destinazione"; font.pixelSize:12
                                    color:clrTextPrim; placeholderTextColor:clrTextSec; leftPadding:10
                                    enabled:!showStop
                                    background:Rectangle{
                                        color:"#0a1525";radius:5
                                        border{color:inputDest.activeFocus?clrAccent:clrBorder;width:1}
                                        opacity:inputDest.enabled?1.0:0.4
                                    }
                                }
                            }

                            RowLayout { width:parent.width; spacing:8

                                ComboBox {
                                    id:comboVehicle; Layout.preferredWidth:115
                                    enabled:!showStop
                                    model:ListModel {
                                        ListElement{text:"🚶 Pedone";  value:"PEDESTRIAN"}
                                        ListElement{text:"🚲 Bici";    value:"BICYCLE"}
                                        ListElement{text:"🏍️ Moto";   value:"MOTO"}
                                        ListElement{text:"🚗 Auto";    value:"CAR"}
                                        ListElement{text:"🚚 Camion";  value:"TRUCK"}
                                        ListElement{text:"🚌 Bus";     value:"BUS"}
                                        ListElement{text:"🚋 Tram";    value:"TRAM"}
                                        ListElement{text:"🚆 Treno";   value:"TRAIN"}
                                        ListElement{text:"✈️ Aereo";  value:"PLANE"}
                                    }
                                    textRole:"text"; valueRole:"value"; font.pixelSize:12

                                    // ── Real-time UI update on selection ─────
                                    onCurrentValueChanged: {
                                        if(!showStop){
                                            activeVehicleType=currentValue
                                            axisY.max=vehicleMeta[currentValue]
                                                     ?vehicleMeta[currentValue]["chartMax"]:160
                                        }
                                    }
                                    contentItem:Text{
                                        leftPadding:10; text:comboVehicle.displayText
                                        color:clrTextPrim; font:comboVehicle.font
                                        verticalAlignment:Text.AlignVCenter
                                        opacity:comboVehicle.enabled?1.0:0.4
                                    }
                                    background:Rectangle{
                                        color:"#0a1525";radius:5
                                        border{color:comboVehicle.pressed?clrAccent:clrBorder;width:1}
                                        opacity:comboVehicle.enabled?1.0:0.4
                                    }
                                }

                                // ── START / STOP ─────────────────────────────
                                Button {
                                    Layout.fillWidth:true
                                    text:showStop ? "⏹  STOP" : "▶  START"
                                    font{pixelSize:11;weight:Font.Bold;letterSpacing:1}

                                    onClicked: {
                                        if(showStop){
                                            // Kill the error-detection timer immediately so
                                            // fetchMissionStatus() cannot re-show the banner
                                            // while the reset XHR is still in flight.
                                            missionStatus = "IDLE"
                                            errorVisible  = false

                                            var xhr=new XMLHttpRequest()
                                            xhr.open("POST","http://localhost:8080/api/reset",true)
                                            xhr.onreadystatechange=function(){
                                                if(xhr.readyState===XMLHttpRequest.DONE)
                                                    resetDashboard()
                                            }
                                            xhr.send()
                                        } else {
                                            if(inputOrigin.text.trim()===""||inputDest.text.trim()==="") return
                                            errorVisible=false; errorMessage=""
                                            var mxhr=new XMLHttpRequest()
                                            mxhr.open("POST","http://localhost:8080/api/mission",true)
                                            mxhr.setRequestHeader("Content-Type","application/json")
                                            mxhr.send(JSON.stringify({
                                                origin:      inputOrigin.text.trim(),
                                                destination: inputDest.text.trim(),
                                                vehicle_type:comboVehicle.currentValue
                                            }))
                                        }
                                    }

                                    background:Rectangle{
                                        radius:5
                                        gradient:Gradient{
                                            orientation:Gradient.Horizontal
                                            GradientStop{position:0;color:showStop?Qt.rgba(1,0.24,0.35,0.9):Qt.rgba(0,0.83,1,0.15)}
                                            GradientStop{position:1;color:showStop?Qt.rgba(1,0.24,0.35,0.6):Qt.rgba(0,0.83,1,0.08)}
                                        }
                                        border{color:showStop?clrRed:clrAccent;width:1}
                                        Behavior on border.color{ColorAnimation{duration:250}}
                                    }
                                    contentItem:Text{
                                        text:parent.text; font:parent.font
                                        color:showStop?clrRed:clrAccent
                                        horizontalAlignment:Text.AlignHCenter
                                        verticalAlignment:Text.AlignVCenter
                                        Behavior on color{ColorAnimation{duration:250}}
                                    }
                                }
                            }
                        }
                    }

                    // ── Velocity + Distance card ──────────────────────────────
                    Rectangle {
                        Layout.fillWidth:true; height:88; color:clrCard
                        border{color:clrBorder;width:1} radius:8

                        Rectangle {
                            anchors{left:parent.left;top:parent.top;bottom:parent.bottom}
                            width:3; radius:1.5
                            color:currentSpeed>meta("speedWarn")?clrAccent:clrGreen
                            Behavior on color{ColorAnimation{duration:400}}
                        }
                        Rectangle {
                            anchors.horizontalCenter:parent.horizontalCenter
                            anchors.verticalCenter:parent.verticalCenter
                            width:1; height:parent.height*0.55; color:clrBorder
                        }

                        Row {
                            anchors{fill:parent;leftMargin:18;rightMargin:14;topMargin:10;bottomMargin:10}
                            Column {
                                width:parent.width*0.55; spacing:2
                                anchors.verticalCenter:parent.verticalCenter
                                Text{text:"VELOCITY";color:clrTextSec;font{pixelSize:9;letterSpacing:2.5}}
                                Row {
                                    spacing:4
                                    Text {
                                        text:Math.round(currentSpeed).toString()
                                        color:currentSpeed>meta("speedWarn")?clrAccent:clrGreen
                                        font{pixelSize:36;weight:Font.Thin}
                                        Behavior on color{ColorAnimation{duration:300}}
                                    }
                                    Text{text:"km/h";color:clrTextSec;font.pixelSize:11;anchors.bottom:parent.bottom;bottomPadding:6}
                                }
                            }
                            Column {
                                width:parent.width*0.45; spacing:2
                                anchors.verticalCenter:parent.verticalCenter
                                Text{text:"DISTANCE";color:clrTextSec;font{pixelSize:9;letterSpacing:2.5}}
                                Row {
                                    spacing:4
                                    Text {
                                        text:totalDistanceKm<10  ? totalDistanceKm.toFixed(2)
                                            :totalDistanceKm<100 ? totalDistanceKm.toFixed(1)
                                            :Math.round(totalDistanceKm).toString()
                                        color:clrTextPrim; font{pixelSize:26;weight:Font.Light}
                                    }
                                    Text{text:"km";color:clrTextSec;font.pixelSize:11;anchors.bottom:parent.bottom;bottomPadding:4}
                                }
                            }
                        }
                    }

                    // ── Metric grid ───────────────────────────────────────────
                    GridLayout {
                        Layout.fillWidth:true; columns:2; rowSpacing:8; columnSpacing:8

                        MetricCard { Layout.fillWidth:true; label:meta("tempLabel"); value:currentTemp.toFixed(1)+" °C"; icon:"🌡"; warning:currentTemp>meta("tempWarn") }
                        MetricCard { Layout.fillWidth:true; label:"ALTITUDE"; value:Math.round(currentAltitude)+" m"; icon:"▲"; warning:false }

                        BatteryCard { Layout.columnSpan:2; Layout.fillWidth:true; label:meta("batLabel"); batteryLevel:currentBattery }

                        Rectangle {
                            Layout.columnSpan:2; Layout.fillWidth:true; height:40
                            color:clrCard; radius:8; border{color:isWarning?clrRed:clrBorder;width:1}
                            Behavior on border.color{ColorAnimation{duration:300}}
                            RowLayout {
                                anchors{fill:parent;margins:10} spacing:8
                                Row {
                                    spacing:6
                                    Rectangle{width:3;height:12;radius:1.5;color:clrTextSec;anchors.verticalCenter:parent.verticalCenter}
                                    Text{text:"SYSTEM STATUS";color:clrTextSec;font{pixelSize:9;letterSpacing:2}anchors.verticalCenter:parent.verticalCenter}
                                }
                                Item{Layout.fillWidth:true}
                                Rectangle{id:warnDot;width:8;height:8;radius:4;color:isWarning?clrRed:clrGreen;anchors.verticalCenter:parent.verticalCenter;Behavior on color{ColorAnimation{duration:300}}}
                                Text{text:isWarning?"WARNING":"NOMINAL";color:isWarning?clrRed:clrGreen;font{pixelSize:13;weight:Font.Bold;letterSpacing:1}anchors.verticalCenter:parent.verticalCenter;Behavior on color{ColorAnimation{duration:300}}}
                            }
                        }
                    }

                    // ── Speed chart ───────────────────────────────────────────
                    Rectangle {
                        Layout.fillWidth:true; Layout.fillHeight:true
                        color:clrCard; border{color:clrBorder;width:1} radius:8; clip:true

                        Row {
                            anchors{top:parent.top;left:parent.left;topMargin:10;leftMargin:12} spacing:6
                            Rectangle{width:3;height:12;radius:1.5;color:clrGreen;anchors.verticalCenter:parent.verticalCenter}
                            Text{text:"SPEED HISTORY  ·  "+meta("label").toUpperCase();color:clrTextSec;font{pixelSize:9;letterSpacing:2.5}anchors.verticalCenter:parent.verticalCenter}
                        }
                        ChartView {
                            id:chartView; anchors{fill:parent;topMargin:28}
                            theme:ChartView.ChartThemeDark; backgroundColor:"transparent"
                            plotAreaColor:"transparent"; legend.visible:false; antialiasing:true
                            margins{top:4;bottom:4;left:4;right:4}
                            DateTimeAxis{id:axisX;format:"mm:ss";gridLineColor:clrBorder;labelsColor:clrTextSec;labelsFont{pixelSize:9}lineVisible:false;tickCount:5}
                            ValueAxis{id:axisY;min:0;max:160;gridLineColor:clrBorder;labelsColor:clrTextSec;labelsFont{pixelSize:9}lineVisible:false;tickCount:5}
                            AreaSeries{axisX:axisX;axisY:axisY;borderColor:clrGreen;borderWidth:2;color:Qt.rgba(0,0.90,0.46,0.15);upperSeries:LineSeries{id:lineSeries}}
                        }
                    }
                }
            }

            // ── Map ───────────────────────────────────────────────────────────
            Item {
                Layout.fillWidth:true; Layout.fillHeight:true

                Plugin{id:mapPlugin;name:"osm";PluginParameter{name:"osm.mapping.providersrepository.disabled";value:"true"}}

                Map {
                    id:mapView; anchors.fill:parent; plugin:mapPlugin
                    center:currentCoords; zoomLevel:5; copyrightsVisible:false

                    WheelHandler {
                        acceptedDevices:PointerDevice.Mouse|PointerDevice.TouchPad
                        onWheel:(wheel)=>{ mapView.zoomLevel=Math.max(3,Math.min(20,mapView.zoomLevel+wheel.angleDelta.y/120.0)) }
                    }
                    MapPolyline{id:routeLine;line.width:3;line.color:Qt.rgba(0,0.83,1,0.85)}
                    MapQuickItem {
                        coordinate:currentCoords; anchorPoint.x:14; anchorPoint.y:14
                        sourceItem:Item{
                            width:28;height:28
                            Rectangle{
                                anchors.centerIn:parent;width:28;height:28;radius:14
                                color:"transparent";border{color:clrAccent;width:1.5}
                                SequentialAnimation on scale{loops:Animation.Infinite;NumberAnimation{to:1.9;duration:900;easing.type:Easing.OutQuad}NumberAnimation{to:1.0;duration:100}}
                                SequentialAnimation on opacity{loops:Animation.Infinite;NumberAnimation{to:0.0;duration:900}NumberAnimation{to:1.0;duration:100}}
                            }
                            Rectangle{anchors.centerIn:parent;width:13;height:13;radius:6.5;color:clrAccent;border{color:"white";width:2}}
                        }
                    }
                }

                Rectangle{anchors{bottom:parent.bottom;left:parent.left;margins:12}height:28;width:coordTxt.implicitWidth+20;color:Qt.rgba(0.05,0.08,0.13,0.85);border{color:clrBorder;width:1}radius:5
                    Text{id:coordTxt;anchors.centerIn:parent;text:currentCoords.latitude.toFixed(5)+"  "+currentCoords.longitude.toFixed(5);color:clrTextSec;font{pixelSize:10;family:"monospace";letterSpacing:1}}
                }
                Rectangle{anchors{top:parent.top;left:parent.left;margins:12}height:28;width:hdgTxt.implicitWidth+20;color:Qt.rgba(0.05,0.08,0.13,0.85);border{color:clrBorder;width:1}radius:5;visible:telemetryActive
                    Text{id:hdgTxt;anchors.centerIn:parent;text:"HDG  "+Math.round(currentHeading)+"°";color:clrTextSec;font{pixelSize:10;family:"monospace";letterSpacing:1}}
                }
                Column{anchors{right:parent.right;top:parent.top;margins:12}spacing:1
                    ZoomButton{text:"+";onClicked:mapView.zoomLevel=Math.min(mapView.zoomLevel+1,19)}
                    ZoomButton{text:"−";onClicked:mapView.zoomLevel=Math.max(mapView.zoomLevel-1,3)}
                }
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  LOADING OVERLAY  (z:99, covers body only – below the header)
    // ══════════════════════════════════════════════════════════════════════════
    Rectangle {
        id:loadingOverlay
        z:99
        anchors { top:parent.top; left:parent.left; right:parent.right; bottom:parent.bottom }
        anchors.topMargin:52   // skip the header
        color:Qt.rgba(0.03,0.05,0.10,0.82)
        visible:isLoading

        Column {
            anchors.centerIn:parent; spacing:20

            // Canvas spinner – 270° arc rotating
            Canvas {
                id:spinnerCanvas; width:56; height:56
                anchors.horizontalCenter:parent.horizontalCenter
                property real angle:0
                NumberAnimation on angle {
                    from:0;to:360;duration:900;loops:Animation.Infinite;running:isLoading
                }
                onAngleChanged: requestPaint()
                onPaint: {
                    var ctx=getContext("2d"); ctx.reset()
                    var cx=width/2, cy=height/2, r=22
                    ctx.beginPath(); ctx.arc(cx,cy,r,0,2*Math.PI)
                    ctx.strokeStyle="#1e2d45"; ctx.lineWidth=4; ctx.stroke()
                    var s=(angle-90)*Math.PI/180
                    ctx.beginPath(); ctx.arc(cx,cy,r,s,s+1.5*Math.PI)
                    ctx.strokeStyle="#00d4ff"; ctx.lineWidth=4; ctx.lineCap="round"; ctx.stroke()
                }
            }

            Column {
                anchors.horizontalCenter:parent.horizontalCenter; spacing:6
                Text {
                    anchors.horizontalCenter:parent.horizontalCenter
                    text:missionStatus==="RUNNING" ? "Starting transmission…" : "Computing route…"
                    color:clrTextPrim; font{pixelSize:15;letterSpacing:2}
                }
                Text {
                    anchors.horizontalCenter:parent.horizontalCenter
                    text:inputOrigin.text.trim()+" → "+inputDest.text.trim()
                    color:clrTextSec; font{pixelSize:11;letterSpacing:1}
                }
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  ERROR BANNER  (z:100, slides down from top when errorVisible)
    // ══════════════════════════════════════════════════════════════════════════
    Rectangle {
        id:errorBanner
        z:100
        anchors { left:parent.left; right:parent.right }
        // slides from y = 52 (header bottom) by animating y
        y: errorVisible ? 52 : 52 - height
        height:52
        color:Qt.rgba(0.85,0.10,0.22,0.97)
        Behavior on y { NumberAnimation { duration:350; easing.type:Easing.OutQuart } }
        clip:true

        RowLayout {
            anchors { fill:parent; leftMargin:18; rightMargin:18 } spacing:12

            // Warning icon
            Text { text:"⚠"; font.pixelSize:18; color:"white"; anchors.verticalCenter:parent.verticalCenter }

            Column {
                Layout.fillWidth:true; spacing:1; anchors.verticalCenter:parent.verticalCenter
                Text { text:"SIMULATOR ERROR"; color:Qt.rgba(1,1,1,0.6); font{pixelSize:9;letterSpacing:2.5;weight:Font.Bold} }
                Text {
                    width:parent.width
                    text:errorMessage; color:"white"; font{pixelSize:12}
                    elide:Text.ElideRight
                }
            }

            // Dismiss button
            Rectangle {
                width:28;height:28;radius:4
                color:dismissMa.pressed?Qt.rgba(1,1,1,0.25):Qt.rgba(1,1,1,0.12)
                border{color:Qt.rgba(1,1,1,0.3);width:1}
                Text{anchors.centerIn:parent;text:"✕";color:"white";font{pixelSize:14}}
                MouseArea {
                    id:dismissMa; anchors.fill:parent
                    onClicked: {
                        // Immediately neutralise error state so the 1-s timer
                        // cannot re-show the banner before the reset XHR completes.
                        missionStatus = "IDLE"
                        errorVisible  = false
                        errorMessage  = ""
                        var xhr = new XMLHttpRequest()
                        xhr.open("POST","http://localhost:8080/api/reset",true)
                        xhr.onreadystatechange = function() {
                            if (xhr.readyState === XMLHttpRequest.DONE)
                                resetDashboard()
                        }
                        xhr.send()
                    }
                }
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  INLINE COMPONENTS
    // ══════════════════════════════════════════════════════════════════════════
    component MetricCard: Rectangle {
        property string label:"";property string value:"";property string icon:"";property bool warning:false
        height:60;color:clrCard;radius:8;border{color:warning?clrRed:clrBorder;width:1}
        Behavior on border.color{ColorAnimation{duration:300}}
        Column{anchors{fill:parent;margins:10}spacing:3
            Row{spacing:5;Text{text:icon;font.pixelSize:9;anchors.verticalCenter:parent.verticalCenter}Text{text:label;color:clrTextSec;font{pixelSize:9;letterSpacing:2}anchors.verticalCenter:parent.verticalCenter}}
            Text{text:value;font{pixelSize:17;weight:Font.Light}color:warning?clrRed:clrTextPrim;Behavior on color{ColorAnimation{duration:300}}}
        }
    }

    component BatteryCard: Rectangle {
        property double batteryLevel:0; property string label:"BATTERY"
        height:58;color:clrCard;radius:8;border{color:batteryLevel<20?clrRed:clrBorder;width:1}
        Behavior on border.color{ColorAnimation{duration:300}}
        Column{anchors{fill:parent;margins:10}spacing:6
            Row{spacing:5
                Rectangle{width:3;height:10;radius:1.5;color:batteryLevel<20?clrRed:clrGreen;anchors.verticalCenter:parent.verticalCenter;Behavior on color{ColorAnimation{}}}
                Text{text:label;color:clrTextSec;font{pixelSize:9;letterSpacing:2.5}anchors.verticalCenter:parent.verticalCenter}
                Item{width:4}
                Text{text:batteryLevel.toFixed(0)+"%";color:batteryLevel<20?clrRed:clrGreen;font{pixelSize:13;weight:Font.Bold}anchors.verticalCenter:parent.verticalCenter;Behavior on color{ColorAnimation{}}}
            }
            Rectangle{width:parent.width-1;height:6;radius:3;color:Qt.rgba(1,1,1,0.05)
                Rectangle{width:parent.width*Math.max(0,Math.min(1,batteryLevel/100));height:parent.height;radius:parent.radius;color:batteryLevel<20?clrRed:batteryLevel<50?clrAmber:clrGreen;Behavior on width{NumberAnimation{duration:400;easing.type:Easing.OutCubic}}Behavior on color{ColorAnimation{duration:400}}}
            }
        }
    }

    component ZoomButton: Rectangle {
        property string text:""; signal clicked()
        width:32;height:32;radius:4
        color:zoomMa.pressed?Qt.rgba(0,0.83,1,0.2):Qt.rgba(0.05,0.08,0.13,0.85)
        border{color:clrBorder;width:1}
        Text{anchors.centerIn:parent;text:parent.text;color:clrAccent;font{pixelSize:18;weight:Font.Light}}
        MouseArea{id:zoomMa;anchors.fill:parent;onClicked:parent.clicked()}
    }
}
