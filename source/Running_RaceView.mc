import Toybox.AntPlus;
import Toybox.Activity;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.Position;
import Toybox.Sensor;
import Toybox.WatchUi;

class Running_RaceView extends WatchUi.DataField {

    const DESIGN_SIZE = 416.0;
    const PI = 3.14159265;

    const COLOR_BG = 0x060606;
    const COLOR_RING = 0xB83B4F;
    const COLOR_WHITE = 0xF4F4F4;
    const COLOR_MUTED = 0x8E949B;
    const COLOR_BLUE = 0x63C6F5;
    const COLOR_GREEN = 0x49C56D;
    const COLOR_RED = 0xD24B3D;
    const COLOR_ORANGE = 0xE59B3E;
    const COLOR_PANEL_CENTER = 0x5E78C8;
    const COLOR_PANEL_TIME = 0x9AAAE4;
    const COLOR_PANEL_DISTANCE = 0x4CA3D7;
    const COLOR_PANEL_BLACK = 0x111111;
    const COLOR_TRACK = 0x333333;

    var config;
    var paceLogic;
    var hrLogic;
    var reserveLogic;
    var alertLogic;

    var currentPower = 0;
    var hasPower = false;
    var currentCadence = 0;
    var verticalRatio = 0.0;
    var hasVerticalRatio = false;
    var gpsBars = 0;
    var chestStatus = 0;

    var runningDynamicsSensor = null;

    function initialize() {
        DataField.initialize();

        config = new RaceConfig();
        paceLogic = new RacePaceLogic(config);
        hrLogic = new RaceHeartRateLogic(config);
        reserveLogic = new RaceReserveLogic(config);
        alertLogic = new RaceAlertLogic(config);
        initializeRunningDynamics();
    }

    function initializeRunningDynamics() as Void {
        try {
            runningDynamicsSensor = new AntPlus.RunningDynamics(null);
        } catch (e) {
            runningDynamicsSensor = null;
        }
    }

    function compute(info as Activity.Info) as Void {
        var elapsedSeconds = paceLogic.elapsedSec;
        var distanceKilometers = paceLogic.distanceKm;

        if (info.elapsedTime != null) {
            elapsedSeconds = (info.elapsedTime / 1000).toNumber();
        }
        if (info.elapsedDistance != null) {
            distanceKilometers = info.elapsedDistance / 1000.0;
        }

        var isNewSecond = paceLogic.update(elapsedSeconds, distanceKilometers, info.currentSpeed, info.averageSpeed);
        hrLogic.update(info, isNewSecond);
        updatePerformanceMetrics(info);

        if (isNewSecond) {
            alertLogic.clearExpiredBanner(paceLogic.elapsedSec);
            alertLogic.checkNutrition(paceLogic);
        }

        if (paceLogic.isHeavyRefreshDue()) {
            paceLogic.refreshHeavy();
            hrLogic.refreshHeavy(paceLogic);
            reserveLogic.refreshHeavy(paceLogic, hrLogic, currentPower, hasPower);
            refreshExternalSensors();
            alertLogic.checkFiveKmFeedback(paceLogic, hrLogic, reserveLogic.reservePercent);
        }
    }

    function updatePerformanceMetrics(info as Activity.Info) as Void {
        hasPower = false;
        if (info.currentPower != null && info.currentPower > 0) {
            currentPower = info.currentPower;
            hasPower = true;
        }

        if (info.currentCadence != null && info.currentCadence > 0) {
            currentCadence = info.currentCadence;
        }
    }

    function refreshExternalSensors() as Void {
        refreshRunningDynamics();
        refreshGpsStatus();
        refreshChestStatus();
    }

    function refreshRunningDynamics() as Void {
        hasVerticalRatio = false;
        if (runningDynamicsSensor == null) {
            return;
        }

        try {
            var dynamicsData = runningDynamicsSensor.getRunningDynamics();
            if (dynamicsData != null && dynamicsData.verticalRatio != null && dynamicsData.verticalRatio > 0.0) {
                verticalRatio = dynamicsData.verticalRatio;
                hasVerticalRatio = true;
            }
        } catch (e) {
            hasVerticalRatio = false;
        }
    }

    function refreshGpsStatus() as Void {
        gpsBars = 0;
        try {
            var positionInfo = Position.getInfo();
            if (positionInfo.accuracy == Position.QUALITY_GOOD) {
                gpsBars = 4;
            } else if (positionInfo.accuracy == Position.QUALITY_USABLE) {
                gpsBars = 3;
            } else if (positionInfo.accuracy == Position.QUALITY_POOR) {
                gpsBars = 1;
            } else {
                gpsBars = 0;
            }
        } catch (e) {
            gpsBars = 0;
        }
    }

    function refreshChestStatus() as Void {
        chestStatus = 0;

        try {
            if (Sensor has :getRegisteredSensors) {
                var iterator = Sensor.getRegisteredSensors(Sensor.SENSOR_HEARTRATE);
                if (iterator != null) {
                    var sensorInfo = iterator.next();
                    while (sensorInfo != null) {
                        if (sensorInfo.enabled) {
                            if (sensorInfo.technology == Sensor.SENSOR_TECHNOLOGY_ANT) {
                                chestStatus = 2;
                                return;
                            }
                            chestStatus = 1;
                        }
                        sensorInfo = iterator.next();
                    }
                }
            }
        } catch (e) {
            chestStatus = 0;
        }

        if (hasVerticalRatio && chestStatus < 2) {
            chestStatus = 2;
        }
    }

    function onTimerLap2(trigger as WatchUi.DataField.LapInfoType) as Boolean {
        paceLogic.handleLapTrigger();
        hrLogic.resetDrift(paceLogic.lastLapResetSec);

        if (trigger[:lapTrigger] == WatchUi.DataField.LAP_TRIGGER_MANUAL) {
            alertLogic.showBanner("Lap synced", COLOR_BLUE, paceLogic.elapsedSec + 8);
        }

        return true;
    }

    function onUpdate(dc as Dc) as Void {
        var width = dc.getWidth();
        var height = dc.getHeight();
        var size = width < height ? width : height;
        var scale = size.toFloat() / DESIGN_SIZE;
        var centerX = width / 2;
        var centerY = height / 2;
        var radius = scaled(202, scale);
        var arcRadius = scaled(182, scale);
        var arcThickness = scaled(7, scale);

        var powerText = formatPower(currentPower, hasPower);
        var cadenceText = formatCadence(currentCadence);
        var reserveText = formatReserve(reserveLogic.reservePercent);
        var lapPaceText = formatPace(paceLogic.lapPaceSec);
        var deltaText = formatSignedPaceDelta(paceLogic.deltaToTargetSec());
        var distanceText = formatDistance(paceLogic.distanceKm);
        var remainingText = formatDistance(paceLogic.remainingKm);
        var averagePaceText = formatPace(paceLogic.averagePaceSec);
        var rollingPaceText = formatPace(paceLogic.rolling5MinPaceSec);
        var elapsedText = formatTimeHms(paceLogic.elapsedSec);
        var finishText = formatTimeHms(paceLogic.projectedFinishSec);
        var ratioText = formatVerticalRatio();
        var avgHrText = formatHeartRateNumber(hrLogic.averageHr);
        var currentHrText = formatHeartRateNumber(hrLogic.currentHr);
        var rollingHrText = formatHeartRateNumber(hrLogic.rolling5MinHr);

        dc.setColor(COLOR_BG, COLOR_BG);
        dc.clear();
        dc.fillCircle(centerX, centerY, radius);

        drawZoneArc(dc, centerX, centerY, arcRadius, arcThickness, 215.0, 325.0, config.powerZones, currentPower);
        drawZoneArc(dc, centerX, centerY, arcRadius, arcThickness, 145.0, 35.0, config.hrZones, hrLogic.currentHr);
        drawOuterRing(dc, centerX, centerY, radius);
        drawSensorIcons(dc, scale);

        drawCenteredMetric(dc, centerX, scaled(60, scale), powerText, pickMetricFont(dc, powerText, scaled(112, scale)), colorForPower(currentPower, hasPower));
        drawCenteredMetric(dc, scaled(128, scale), scaled(94, scale), cadenceText, pickMetricFont(dc, cadenceText, scaled(74, scale)), colorForCadence(currentCadence));
        drawCenteredMetric(dc, scaled(288, scale), scaled(94, scale), reserveText, pickMetricFont(dc, reserveText, scaled(104, scale)), colorForReserve(reserveLogic.reservePercent));
        drawCenteredMetric(dc, centerX, scaled(122, scale), lapPaceText, pickMetricFont(dc, lapPaceText, scaled(96, scale)), colorForPace(paceLogic.lapPaceSec));
        drawCenteredMetric(dc, centerX, scaled(148, scale), deltaText, pickMetricFont(dc, deltaText, scaled(124, scale)), colorForDelta(paceLogic.deltaToTargetSec()));

        drawRoundedPanel(dc, scaled(90, scale), scaled(188, scale), scaled(98, scale), scaled(40, scale), scaled(8, scale), COLOR_PANEL_DISTANCE);
        drawRoundedPanel(dc, scaled(326, scale), scaled(188, scale), scaled(98, scale), scaled(40, scale), scaled(8, scale), COLOR_PANEL_DISTANCE);
        drawCenteredMetric(dc, scaled(90, scale), scaled(188, scale), distanceText, pickMetricFont(dc, distanceText, scaled(88, scale)), COLOR_WHITE);
        drawCenteredMetric(dc, scaled(326, scale), scaled(188, scale), remainingText, pickMetricFont(dc, remainingText, scaled(88, scale)), COLOR_WHITE);

        drawCenteredMetric(dc, scaled(64, scale), scaled(224, scale), averagePaceText, pickMetricFont(dc, averagePaceText, scaled(84, scale)), colorForPace(paceLogic.averagePaceSec));
        drawCenteredMetric(dc, scaled(352, scale), scaled(224, scale), rollingPaceText, pickMetricFont(dc, rollingPaceText, scaled(84, scale)), colorForPace(paceLogic.rolling5MinPaceSec));

        drawRoundedPanel(dc, centerX, scaled(246, scale), scaled(136, scale), scaled(66, scale), scaled(12, scale), COLOR_PANEL_CENTER);
        drawFieldOne(dc, centerX, scaled(246, scale), scaled(136, scale), scaled(66, scale), scale);

        drawRoundedPanel(dc, scaled(132, scale), scaled(304, scale), scaled(124, scale), scaled(46, scale), scaled(10, scale), COLOR_PANEL_TIME);
        drawRoundedPanel(dc, scaled(284, scale), scaled(304, scale), scaled(124, scale), scaled(46, scale), scaled(10, scale), COLOR_PANEL_TIME);
        drawCenteredMetric(dc, scaled(132, scale), scaled(304, scale), elapsedText, pickTimeFont(dc, elapsedText, scaled(112, scale)), COLOR_WHITE);
        drawCenteredMetric(dc, scaled(284, scale), scaled(304, scale), finishText, pickTimeFont(dc, finishText, scaled(112, scale)), colorForProjectedFinish());

        drawRoundedPanel(dc, scaled(94, scale), scaled(360, scale), scaled(74, scale), scaled(32, scale), scaled(4, scale), COLOR_PANEL_BLACK);
        drawRoundedPanel(dc, scaled(322, scale), scaled(360, scale), scaled(74, scale), scaled(32, scale), scaled(4, scale), COLOR_PANEL_BLACK);
        drawCenteredMetric(dc, scaled(94, scale), scaled(360, scale), avgHrText, pickMetricFont(dc, avgHrText, scaled(60, scale)), colorForHrValue(hrLogic.averageHr));
        drawCenteredMetric(dc, centerX, scaled(388, scale), currentHrText, pickMainHrFont(dc, currentHrText, scaled(118, scale)), colorForHrValue(hrLogic.currentHr.toFloat()));
        drawCenteredMetric(dc, scaled(322, scale), scaled(360, scale), rollingHrText, pickMetricFont(dc, rollingHrText, scaled(60, scale)), colorForHrValue(hrLogic.rolling5MinHr));
        drawCenteredMetric(dc, centerX, scaled(336, scale), ratioText, Graphics.FONT_MEDIUM, colorForVerticalRatio());
    }

    function drawFieldOne(dc as Dc, centerX as Number, centerY as Number, panelWidth as Number, panelHeight as Number, scale as Float) as Void {
        var headerText = "";
        var headerColor = COLOR_WHITE;

        if (alertLogic.hasActiveBanner(paceLogic.elapsedSec)) {
            headerText = alertLogic.bannerText;
            headerColor = alertLogic.bannerColor;
        } else if (hrLogic.driftActive) {
            headerText = "DRIFT +" + hrLogic.driftDeltaBpm.format("%d");
            headerColor = COLOR_ORANGE;
        }

        if (headerText != "") {
            drawCenteredMetric(dc, centerX, centerY - (panelHeight / 2) + scaled(12, scale), headerText, Graphics.FONT_XTINY, headerColor);
        }

        var paceText = formatPace(paceLogic.smoothedPaceSec);
        var font = pickCenterFont(dc, paceText, panelWidth - scaled(18, scale));
        drawCenteredMetric(dc, centerX, centerY + scaled(6, scale), paceText, font, colorForPace(paceLogic.smoothedPaceSec));
    }

    function drawSensorIcons(dc as Dc, scale as Float) as Void {
        drawChestIcon(dc, scaled(54, scale), scaled(108, scale), scaled(4, scale));
        drawGpsIcon(dc, scaled(362, scale), scaled(108, scale), scaled(5, scale));
    }

    function drawChestIcon(dc as Dc, x as Number, y as Number, dotRadius as Number) as Void {
        var color = COLOR_MUTED;
        if (chestStatus == 2) {
            color = COLOR_WHITE;
        } else if (chestStatus == 1) {
            color = COLOR_BLUE;
        }

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(x - 9, y + 2, x, y + 2);
        dc.drawLine(x, y + 2, x + 10, y + 9);
        dc.drawLine(x, y + 2, x + 1, y - 9);
        dc.fillCircle(x - 12, y + 2, dotRadius);
        dc.fillCircle(x + 1, y - 9, dotRadius);
        dc.fillCircle(x + 10, y + 9, dotRadius + 2);
    }

    function drawGpsIcon(dc as Dc, x as Number, y as Number, barWidth as Number) as Void {
        for (var i = 0; i < 4; i += 1) {
            var enabled = gpsBars > i;
            var color = enabled ? COLOR_WHITE : COLOR_TRACK;
            dc.setColor(color, color);
            var barHeight = (i + 1) * 6;
            dc.fillRectangle(x + (i * (barWidth + 1)), y + 8 - barHeight, barWidth, barHeight);
        }
    }

    function drawOuterRing(dc as Dc, centerX as Number, centerY as Number, radius as Number) as Void {
        dc.setColor(COLOR_RING, Graphics.COLOR_TRANSPARENT);
        dc.drawCircle(centerX, centerY, radius);
        dc.drawCircle(centerX, centerY, radius - 1);
    }

    function drawZoneArc(dc as Dc, centerX as Number, centerY as Number, radius as Number, thickness as Number, startDeg as Float, endDeg as Float, thresholds as Array<Number>, currentValue as Number) as Void {
        if (thresholds == null || thresholds.size() <= 0) {
            return;
        }

        var maxValue = thresholds[thresholds.size() - 1].toFloat();
        if (maxValue <= 0.0) {
            return;
        }

        drawNativeArc(dc, centerX, centerY, radius, thickness, startDeg, endDeg, 0.0, COLOR_TRACK);

        var previous = 0.0;
        for (var i = 0; i < thresholds.size(); i += 1) {
            var threshold = thresholds[i].toFloat();
            var segmentStart = startDeg + ((previous / maxValue) * (endDeg - startDeg));
            var segmentEnd = startDeg + ((threshold / maxValue) * (endDeg - startDeg));
            drawNativeArc(dc, centerX, centerY, radius, thickness, segmentStart, segmentEnd, 2.6, colorForZoneIndex(i + 1));
            previous = threshold;
        }

        dc.setPenWidth(1);

        if (currentValue > 0) {
            var cappedValue = currentValue.toFloat();
            if (cappedValue > maxValue) {
                cappedValue = maxValue;
            }
            var markerAngle = startDeg + ((cappedValue / maxValue) * (endDeg - startDeg));
            drawArcMarker(dc, centerX, centerY, radius, thickness - 1, markerAngle);
        }
    }

    function drawNativeArc(dc as Dc, centerX as Number, centerY as Number, radius as Number, thickness as Number, startDeg as Float, endDeg as Float, gapDegrees as Float, color as Number) as Void {
        var sweep = endDeg - startDeg;
        if (absoluteFloat(sweep) <= 0.2) {
            return;
        }

        var drawStart = startDeg;
        var drawEnd = endDeg;
        if (gapDegrees > 0.0 && absoluteFloat(sweep) > gapDegrees) {
            var inset = gapDegrees / 2.0;
            if (sweep > 0.0) {
                drawStart += inset;
                drawEnd -= inset;
            } else {
                drawStart -= inset;
                drawEnd += inset;
            }
        }

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(thickness);
        var drawDirection = Graphics.ARC_COUNTER_CLOCKWISE;
        if (sweep >= 0.0) {
            drawDirection = Graphics.ARC_CLOCKWISE;
        }
        dc.drawArc(centerX, centerY, radius, drawDirection, toGarminDegrees(drawStart), toGarminDegrees(drawEnd));
    }

    function drawArcMarker(dc as Dc, centerX as Number, centerY as Number, radius as Number, thickness as Number, angleDeg as Float) as Void {
        var radians = toRadians(angleDeg);
        var x = centerX + (Math.cos(radians) * radius);
        var y = centerY + (Math.sin(radians) * radius);

        dc.setColor(COLOR_BG, COLOR_BG);
        dc.fillCircle(roundNumber(x), roundNumber(y), thickness + 2);
        dc.setColor(COLOR_WHITE, COLOR_WHITE);
        dc.fillCircle(roundNumber(x), roundNumber(y), thickness);
    }

    function drawRoundedPanel(dc as Dc, centerX as Number, centerY as Number, width as Number, height as Number, radius as Number, color as Number) as Void {
        dc.setColor(color, color);
        dc.fillRoundedRectangle(centerX - (width / 2), centerY - (height / 2), width, height, radius);
    }

    function drawCenteredMetric(dc as Dc, centerX as Number, centerY as Number, text as String, font, color as Number) as Void {
        var dims = dc.getTextDimensions(text, font) as Array<Number> or Null;
        var textHeight = 0;
        if (dims != null && dims.size() > 1) {
            textHeight = dims[1];
        } else {
            textHeight = dc.getFontHeight(font);
        }

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, centerY - (textHeight / 2), font, text, Graphics.TEXT_JUSTIFY_CENTER);
    }

    function pickCenterFont(dc as Dc, text as String, maxWidth as Number) {
        if (textWidth(dc, text, Graphics.FONT_NUMBER_HOT) <= maxWidth) {
            return Graphics.FONT_NUMBER_HOT;
        }
        if (textWidth(dc, text, Graphics.FONT_NUMBER_MEDIUM) <= maxWidth) {
            return Graphics.FONT_NUMBER_MEDIUM;
        }
        return Graphics.FONT_NUMBER_MILD;
    }

    function pickMetricFont(dc as Dc, text as String, maxWidth as Number) {
        if (textWidth(dc, text, Graphics.FONT_LARGE) <= maxWidth) {
            return Graphics.FONT_LARGE;
        }
        if (textWidth(dc, text, Graphics.FONT_MEDIUM) <= maxWidth) {
            return Graphics.FONT_MEDIUM;
        }
        return Graphics.FONT_SMALL;
    }

    function pickMainHrFont(dc as Dc, text as String, maxWidth as Number) {
        if (text.length() <= 2 && textWidth(dc, text, Graphics.FONT_NUMBER_MILD) <= maxWidth) {
            return Graphics.FONT_NUMBER_MILD;
        }
        if (textWidth(dc, text, Graphics.FONT_LARGE) <= maxWidth) {
            return Graphics.FONT_LARGE;
        }
        if (textWidth(dc, text, Graphics.FONT_MEDIUM) <= maxWidth) {
            return Graphics.FONT_MEDIUM;
        }
        return Graphics.FONT_SMALL;
    }

    function pickTimeFont(dc as Dc, text as String, maxWidth as Number) {
        if (textWidth(dc, text, Graphics.FONT_LARGE) <= maxWidth) {
            return Graphics.FONT_LARGE;
        }
        if (textWidth(dc, text, Graphics.FONT_MEDIUM) <= maxWidth) {
            return Graphics.FONT_MEDIUM;
        }
        return Graphics.FONT_SMALL;
    }

    function textWidth(dc as Dc, text as String, font) as Number {
        var dims = dc.getTextDimensions(text, font) as Array<Number> or Null;
        if (dims == null || dims.size() == 0) {
            return 0;
        }
        return dims[0];
    }

    function scaled(value as Number, scale as Float) as Number {
        return roundNumber(value.toFloat() * scale);
    }

    function toRadians(degrees as Float) as Float {
        return degrees * PI / 180.0;
    }

    function toGarminDegrees(degrees as Float) as Float {
        var garmin = 360.0 - degrees;
        while (garmin < 0.0) {
            garmin += 360.0;
        }
        while (garmin >= 360.0) {
            garmin -= 360.0;
        }
        return garmin;
    }

    function roundNumber(value) as Number {
        if (value < 0) {
            return (value - 0.5).toNumber();
        }
        return (value + 0.5).toNumber();
    }

    function absoluteFloat(value as Float) as Float {
        if (value < 0.0) {
            return -value;
        }
        return value;
    }

    function formatDistance(valueKm as Float) as String {
        if (valueKm < 0.0) {
            valueKm = 0.0;
        }
        return valueKm.format("%.1f");
    }

    function formatPace(paceSeconds as Float) as String {
        if (paceSeconds <= 0.0 || paceSeconds > 1200.0) {
            return "--:--";
        }

        var rounded = roundNumber(paceSeconds);
        var minutes = rounded / 60;
        var seconds = rounded % 60;
        return minutes.format("%d") + ":" + seconds.format("%02d");
    }

    function formatSignedPaceDelta(deltaSeconds as Float) as String {
        var prefix = "+";
        if (deltaSeconds < 0.0) {
            prefix = "-";
            deltaSeconds = -deltaSeconds;
        }

        var rounded = roundNumber(deltaSeconds);
        var minutes = rounded / 60;
        var seconds = rounded % 60;
        return prefix + minutes.format("%d") + ":" + seconds.format("%02d");
    }

    function formatTimeHms(totalSeconds as Number) as String {
        if (totalSeconds < 0) {
            totalSeconds = 0;
        }

        var rounded = roundNumber(totalSeconds);
        var hours = rounded / 3600;
        var minutes = (rounded % 3600) / 60;
        var seconds = rounded % 60;

        return hours.format("%d") + ":" + minutes.format("%02d") + ":" + seconds.format("%02d");
    }

    function formatPower(value as Number, available as Boolean) as String {
        if (!available || value <= 0) {
            return "--";
        }
        return value.format("%d");
    }

    function formatCadence(value as Number) as String {
        if (value <= 0) {
            return "--";
        }
        return value.format("%d");
    }

    function formatReserve(value as Number) as String {
        return value.format("%d") + "%";
    }

    function formatVerticalRatio() as String {
        if (!hasVerticalRatio) {
            return "--.-%";
        }
        return verticalRatio.format("%.1f") + "%";
    }

    function formatHeartRateNumber(value) as String {
        if (value == null || value <= 0) {
            return "--";
        }
        return roundNumber(value).format("%d");
    }

    function colorForPace(paceSeconds as Float) as Number {
        if (paceSeconds <= 0.0) {
            return COLOR_WHITE;
        }

        var delta = absoluteFloat(paceSeconds - config.targetPaceSec);
        if (delta <= config.paceToleranceSec) {
            return COLOR_GREEN;
        }
        return COLOR_RED;
    }

    function colorForDelta(deltaSeconds as Float) as Number {
        if (absoluteFloat(deltaSeconds) <= 1.5) {
            return COLOR_BLUE;
        } else if (deltaSeconds < 0.0) {
            return COLOR_GREEN;
        }
        return COLOR_RED;
    }

    function colorForProjectedFinish() as Number {
        if (paceLogic.projectedFinishSec <= 0 || config.targetTimeSec <= 0) {
            return COLOR_WHITE;
        }
        if (paceLogic.projectedFinishSec <= config.targetTimeSec) {
            return COLOR_GREEN;
        }
        return COLOR_RED;
    }

    function colorForPower(value as Number, available as Boolean) as Number {
        if (!available || value <= 0) {
            return COLOR_MUTED;
        }
        return colorForZoneIndex(zoneIndexForValue(value, config.powerZones));
    }

    function colorForCadence(value as Number) as Number {
        if (value <= 0) {
            return COLOR_MUTED;
        } else if (value < config.cadenceZones[0]) {
            return COLOR_ORANGE;
        } else if (value < config.cadenceZones[1]) {
            return COLOR_BLUE;
        } else if (value <= config.cadenceZones[2]) {
            return COLOR_GREEN;
        } else if (value <= config.cadenceZones[3]) {
            return COLOR_BLUE;
        }
        return COLOR_RED;
    }

    function colorForReserve(value as Number) as Number {
        if (value >= 85) {
            return COLOR_BLUE;
        } else if (value >= 65) {
            return COLOR_GREEN;
        } else if (value >= 40) {
            return COLOR_ORANGE;
        }
        return COLOR_RED;
    }

    function colorForHrValue(value as Float) as Number {
        if (value <= 0.0) {
            return COLOR_WHITE;
        }
        return colorForZoneIndex(zoneIndexForValue(value.toNumber(), config.hrZones));
    }

    function colorForVerticalRatio() as Number {
        if (!hasVerticalRatio) {
            return COLOR_WHITE;
        } else if (verticalRatio <= config.verticalRatioZones[0]) {
            return COLOR_GREEN;
        } else if (verticalRatio <= config.verticalRatioZones[1]) {
            return COLOR_BLUE;
        } else if (verticalRatio <= config.verticalRatioZones[2]) {
            return COLOR_ORANGE;
        }
        return COLOR_RED;
    }

    function zoneIndexForValue(value as Number, thresholds as Array<Number>) as Number {
        if (value <= 0 || thresholds == null || thresholds.size() <= 0) {
            return 0;
        }

        for (var i = 0; i < thresholds.size(); i += 1) {
            if (value <= thresholds[i]) {
                return i + 1;
            }
        }
        return thresholds.size();
    }

    function colorForZoneIndex(index as Number) as Number {
        if (index <= 1) {
            return COLOR_MUTED;
        } else if (index == 2) {
            return COLOR_BLUE;
        } else if (index == 3) {
            return COLOR_GREEN;
        } else if (index == 4) {
            return COLOR_ORANGE;
        }
        return COLOR_RED;
    }
}
