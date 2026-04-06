import Toybox.Activity;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.Position;
import Toybox.Sensor;
import Toybox.WatchUi;

// =============================================================================
// Running_RaceView  –  Garmin Fenix 8 43mm  (416 × 416 px design canvas)
// =============================================================================
// Layout (design-px, scaled at runtime):
//  y= 50  Feld 10  Power                cx=208  FONT_LARGE  zone colour
//  y= 86  Feld 11  Cadence  x=120  |  Feld 9  TargetPace cx=208 ORANGE  |  Feld 12  Reserve  x=296
//  y=140  Feld  2  [panel cx=94 w=108]  |  Feld  8  Delta cx=208  |  Feld  3  [panel cx=322 w=108]
//  y=208  [CENTER PANEL w=150 h=68]  Feld 6 x=72  Feld 1  Feld 7 x=344
//  y=272  Feld  4  [panel cx=134 w=126 h=48]  |  Feld  5  [panel cx=282 w=126 h=48]
//  y=318  Feld 14  AvgHR x=92  |  Feld 16  VR cx=208 FONT_TINY  |  Feld 15  RollHR x=324
//  y=362  Feld 13  Current HR  cx=208  FONT_LARGE
// =============================================================================

class Running_RaceView extends WatchUi.DataField {

    const DESIGN_SIZE = 416.0;
    const PI          = 3.14159265;

    const COLOR_BG           = 0x060606;
    const COLOR_RING         = 0xB83B4F;
    const COLOR_WHITE        = 0xF4F4F4;
    const COLOR_MUTED        = 0x8E949B;
    const COLOR_BLUE         = 0x63C6F5;
    const COLOR_GREEN        = 0x49C56D;
    const COLOR_RED          = 0xD24B3D;
    const COLOR_ORANGE       = 0xE59B3E;
    const COLOR_PANEL_CENTER = 0x5E78C8;
    const COLOR_PANEL_TIME   = 0x9AAAE4;
    const COLOR_PANEL_DIST   = 0x4CA3D7;
    const COLOR_PANEL_BLACK  = 0x111111;
    const COLOR_TRACK        = 0x333333;

    var config;
    var paceLogic;
    var hrLogic;
    var reserveLogic;
    var alertLogic;

    var currentPower     = 0;
    var hasPower         = false;
    var currentCadence   = 0;
    var verticalRatio    = 0.0;
    var hasVerticalRatio = false;
    var gpsBars          = 0;
    var chestStatus      = 0;

    function initialize() {
        DataField.initialize();
        config       = new RaceConfig();
        paceLogic    = new RacePaceLogic(config);
        hrLogic      = new RaceHeartRateLogic(config);
        reserveLogic = new RaceReserveLogic(config);
        alertLogic   = new RaceAlertLogic(config);
    }

    // -------------------------------------------------------------------------
    function compute(info as Activity.Info) as Void {
        var elapsedSec = paceLogic.elapsedSec;
        var distKm     = paceLogic.distanceKm;
        if (info.elapsedTime     != null) { elapsedSec = (info.elapsedTime / 1000).toNumber(); }
        if (info.elapsedDistance != null) { distKm     = info.elapsedDistance / 1000.0; }

        var isNewSecond = paceLogic.update(elapsedSec, distKm,
                                           info.currentSpeed, info.averageSpeed);
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
            refreshSensorStatus(info);
            alertLogic.checkFiveKmFeedback(paceLogic, hrLogic, reserveLogic.reservePercent);
        }
    }

    function updatePerformanceMetrics(info as Activity.Info) as Void {
        hasPower = false;
        if (info.currentPower  != null && info.currentPower  > 0) { currentPower  = info.currentPower  as Number; hasPower = true; }
        if (info.currentCadence!= null && info.currentCadence> 0) { currentCadence= info.currentCadence as Number; }
        hasVerticalRatio = false;
        if (info has :verticalRatio) {
            var vr = info.verticalRatio;
            if (vr != null && vr > 0.0) { verticalRatio = vr as Float; hasVerticalRatio = true; }
        }
    }

    function refreshSensorStatus(info as Activity.Info) as Void {
        gpsBars = 0;
        if (info has :gpsAccuracy) {
            var acc = info.gpsAccuracy;
            if      (acc == Position.QUALITY_GOOD)   { gpsBars = 4; }
            else if (acc == Position.QUALITY_USABLE) { gpsBars = 3; }
            else if (acc == Position.QUALITY_POOR)   { gpsBars = 1; }
        }
        chestStatus = 0;
        try {
            if (Sensor has :getRegisteredSensors) {
                var it = Sensor.getRegisteredSensors(Sensor.SENSOR_HEARTRATE);
                if (it != null) {
                    var s = it.next();
                    while (s != null) {
                        if (s.enabled) {
                            if (s.technology == Sensor.SENSOR_TECHNOLOGY_ANT) { chestStatus = 2; return; }
                            if (chestStatus < 1) { chestStatus = 1; }
                        }
                        s = it.next();
                    }
                }
            }
        } catch (e) { chestStatus = 0; }
        if (hasVerticalRatio && chestStatus < 2) { chestStatus = 2; }
    }

    function onTimerLap() as Void {
        paceLogic.handleLapTrigger();
        hrLogic.resetDrift(paceLogic.lastLapResetSec);
        alertLogic.showBanner("Lap synced", COLOR_BLUE, paceLogic.elapsedSec + 8);
    }

    // =========================================================================
    // onUpdate  – draw all 16 Felder
    // =========================================================================
    function onUpdate(dc as Dc) as Void {
        var w      = dc.getWidth();
        var h      = dc.getHeight();
        var size   = (w < h ? w : h).toFloat();
        var scale  = size / DESIGN_SIZE;
        var cx     = w / 2;
        var cy     = h / 2;

        // ── background ────────────────────────────────────────────────────
        dc.setColor(COLOR_BG, COLOR_BG);
        dc.clear();
        dc.fillCircle(cx, cy, S(202, scale));

        // ── zone arcs ─────────────────────────────────────────────────────
        var arcR = S(182, scale);
        var arcT = S(9,   scale);
        drawZoneArc(dc, cx, cy, arcR, arcT, 215.0, 325.0,
                    config.powerZones as Array<Number>, currentPower);
        drawZoneArc(dc, cx, cy, arcR, arcT, 145.0, 35.0,
                    config.hrZones    as Array<Number>, hrLogic.currentHr);
        drawOuterRing(dc, cx, cy, S(202, scale));

        // ── sensor icons ──────────────────────────────────────────────────
        drawChestIcon(dc, S(54,  scale), S(104, scale), S(4, scale));
        drawGpsIcon  (dc, S(358, scale), S(104, scale), S(5, scale));

        // ── Feld 10  Running Power ────────────────────────────────────────
        var pwrTxt = formatPower(currentPower, hasPower);
        lbl(dc, cx, S(50, scale), pwrTxt,
            pickEmphasisFont(dc, pwrTxt, S(120, scale)),
            colorForPower(currentPower, hasPower));

        // ── Feld 11 | Feld 9 | Feld 12 ───────────────────────────────────
        lbl(dc, S(120, scale), S(86, scale),
            formatCadence(currentCadence), Graphics.FONT_SMALL,
            colorForCadence(currentCadence));

        // Feld 9: the pace the runner SHOULD run this km (strategy target)
        lbl(dc, cx, S(86, scale),
            formatPace(config.targetPaceSec), Graphics.FONT_SMALL,
            COLOR_ORANGE);

        lbl(dc, S(296, scale), S(86, scale),
            formatReserve(reserveLogic.reservePercent), Graphics.FONT_SMALL,
            colorForReserve(reserveLogic.reservePercent));

        // ── Feld 2 | Feld 8 | Feld 3 ─────────────────────────────────────
        // All three share y=140. Panels width=108 each.
        // Left panel right edge: 94+54=148. Right panel left edge: 322-54=268.
        // Center gap 148-268 = 120 px – plenty for delta text.
        var distTxt = formatDistance(paceLogic.distanceKm);
        var remTxt  = formatDistance(paceLogic.remainingKm);
        drawPanel(dc, S(94,  scale), S(140, scale), S(108, scale), S(44, scale), S(9, scale), COLOR_PANEL_DIST);
        lbl(dc, S(94,  scale), S(140, scale), distTxt,
            pickCompactFont(dc, distTxt, S(96, scale)), COLOR_WHITE);

        drawPanel(dc, S(322, scale), S(140, scale), S(108, scale), S(44, scale), S(9, scale), COLOR_PANEL_DIST);
        lbl(dc, S(322, scale), S(140, scale), remTxt,
            pickCompactFont(dc, remTxt, S(96, scale)), COLOR_WHITE);

        var deltaTxt = formatSignedPaceDelta(paceLogic.deltaToTargetSec());
        lbl(dc, cx, S(140, scale), deltaTxt,
            Graphics.FONT_MEDIUM,
            colorForDelta(paceLogic.deltaToTargetSec()));

        // ── Feld 1 | Feld 6 | Feld 7 ─────────────────────────────────────
        // Panel drawn FIRST; Feld 6 & 7 drawn after at same cy so they
        // appear over the panel's rounded corners where they slightly overlap.
        var p1cy = S(208, scale);
        var p1w  = S(150, scale);
        var p1h  = S(68,  scale);
        drawPanel(dc, cx, p1cy, p1w, p1h, S(13, scale), COLOR_PANEL_CENTER);

        // Feld 6 avg pace  –  left of center panel  (x=72 is 62px from panel edge)
        lbl(dc, S(72,  scale), p1cy,
            formatPace(paceLogic.averagePaceSec), Graphics.FONT_SMALL,
            colorForPace(paceLogic.averagePaceSec));

        // Feld 7 5-min rolling pace  –  right of center panel
        lbl(dc, S(344, scale), p1cy,
            formatPace(paceLogic.rolling5MinPaceSec), Graphics.FONT_SMALL,
            colorForPace(paceLogic.rolling5MinPaceSec));

        // Feld 1 current smoothed pace on the center panel
        drawPacePanel(dc, cx, p1cy, p1w, p1h, scale);

        // ── Feld 4 | Feld 5 ──────────────────────────────────────────────
        var elapsed = formatTimeHms(paceLogic.elapsedSec);
        var finish  = formatTimeHms(paceLogic.projectedFinishSec);
        drawPanel(dc, S(134, scale), S(272, scale), S(126, scale), S(48, scale), S(10, scale), COLOR_PANEL_TIME);
        lbl(dc, S(134, scale), S(272, scale), elapsed,
            pickTimeFont(dc, elapsed, S(114, scale)), COLOR_WHITE);

        drawPanel(dc, S(282, scale), S(272, scale), S(126, scale), S(48, scale), S(10, scale), COLOR_PANEL_TIME);
        lbl(dc, S(282, scale), S(272, scale), finish,
            pickTimeFont(dc, finish, S(114, scale)), colorForProjectedFinish());

        // ── Feld 14 | Feld 16 | Feld 15 ──────────────────────────────────
        lbl(dc, S(92,  scale), S(318, scale),
            formatHeartRateNumber(hrLogic.averageHr), Graphics.FONT_SMALL,
            colorForHrValue(hrLogic.averageHr));

        lbl(dc, cx, S(318, scale),
            formatVerticalRatio(), Graphics.FONT_TINY,
            colorForVerticalRatio());

        lbl(dc, S(324, scale), S(318, scale),
            formatHeartRateNumber(hrLogic.rolling5MinHr), Graphics.FONT_SMALL,
            colorForHrValue(hrLogic.rolling5MinHr));

        // ── Feld 13  Current HR ───────────────────────────────────────────
        var hrTxt = formatHeartRateNumber(hrLogic.currentHr);
        lbl(dc, cx, S(362, scale), hrTxt,
            pickEmphasisFont(dc, hrTxt, S(110, scale)),
            colorForHrValue(hrLogic.currentHr.toFloat()));
    }

    // =========================================================================
    // Feld 1 – pace drawn on the center panel
    // =========================================================================
    function drawPacePanel(dc as Dc, cx as Number, cy as Number,
                           panelW as Number, panelH as Number,
                           scale as Float) as Void {

        var paceTxt  = formatPace(paceLogic.smoothedPaceSec);
        var paceFont = pickCenterFont(dc, paceTxt, panelW - S(16, scale));

        var hdrTxt   = "";
        var hdrColor = COLOR_WHITE;
        if (alertLogic.hasActiveBanner(paceLogic.elapsedSec)) {
            hdrTxt   = alertLogic.bannerText;
            hdrColor = alertLogic.bannerColor as Number;
        } else if (hrLogic.driftActive) {
            hdrTxt   = "DRIFT +" + hrLogic.driftDeltaBpm.format("%d");
            hdrColor = COLOR_ORANGE;
        }

        if (!hdrTxt.equals("")) {
            lbl(dc, cx, cy - (panelH / 2) + S(11, scale),
                hdrTxt, Graphics.FONT_XTINY, hdrColor);
            lbl(dc, cx, cy + S(8, scale),
                paceTxt, paceFont, colorForPace(paceLogic.smoothedPaceSec));
        } else {
            lbl(dc, cx, cy,
                paceTxt, paceFont, colorForPace(paceLogic.smoothedPaceSec));
        }
    }

    // =========================================================================
    // Sensor icons
    // =========================================================================
    function drawChestIcon(dc as Dc, x as Number, y as Number,
                           dotR as Number) as Void {
        var color = chestStatus == 2 ? COLOR_WHITE
                  : chestStatus == 1 ? COLOR_BLUE
                  : COLOR_MUTED;
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(x - 9, y + 2, x,      y + 2);
        dc.drawLine(x,     y + 2, x + 10, y + 9);
        dc.drawLine(x,     y + 2, x + 1,  y - 9);
        dc.fillCircle(x - 12, y + 2, dotR);
        dc.fillCircle(x + 1,  y - 9, dotR);
        dc.fillCircle(x + 10, y + 9, dotR + 2);
    }

    function drawGpsIcon(dc as Dc, x as Number, y as Number,
                         barW as Number) as Void {
        for (var i = 0; i < 4; i += 1) {
            var barH = (i + 1) * 6;
            dc.setColor(gpsBars > i ? COLOR_WHITE : COLOR_TRACK,
                        gpsBars > i ? COLOR_WHITE : COLOR_TRACK);
            dc.fillRectangle(x + (i * (barW + 1)), y + 8 - barH, barW, barH);
        }
    }

    // =========================================================================
    // Arc / ring
    // =========================================================================
    function drawOuterRing(dc as Dc, cx as Number, cy as Number,
                           r as Number) as Void {
        dc.setColor(COLOR_RING, Graphics.COLOR_TRANSPARENT);
        dc.drawCircle(cx, cy, r);
        dc.drawCircle(cx, cy, r - 1);
    }

    function drawZoneArc(dc as Dc, cx as Number, cy as Number,
                         r as Number, thickness as Number,
                         startDeg as Float, endDeg as Float,
                         thresholds as Array<Number>,
                         currentValue as Number) as Void {
        if (thresholds == null || thresholds.size() <= 0) { return; }
        var maxVal = (thresholds[thresholds.size() - 1] as Number).toFloat();
        if (maxVal <= 0.0) { return; }

        drawNativeArc(dc, cx, cy, r, thickness, startDeg, endDeg, 0.0, COLOR_TRACK);
        var prev = 0.0;
        for (var i = 0; i < thresholds.size(); i += 1) {
            var thr  = (thresholds[i] as Number).toFloat();
            var sAng = startDeg + ((prev / maxVal) * (endDeg - startDeg));
            var eAng = startDeg + ((thr  / maxVal) * (endDeg - startDeg));
            drawNativeArc(dc, cx, cy, r, thickness, sAng, eAng, 2.6,
                          colorForZoneIndex(i + 1));
            prev = thr;
        }
        dc.setPenWidth(1);
        if (currentValue > 0) {
            var capped = currentValue.toFloat();
            if (capped > maxVal) { capped = maxVal; }
            var mDeg = startDeg + ((capped / maxVal) * (endDeg - startDeg));
            drawArcMarker(dc, cx, cy, r, thickness - 1, mDeg);
        }
    }

    function drawNativeArc(dc as Dc, cx as Number, cy as Number,
                           r as Number, thickness as Number,
                           startDeg as Float, endDeg as Float,
                           gapDeg as Float, color as Number) as Void {
        var sweep = endDeg - startDeg;
        if (absoluteFloat(sweep) <= 0.2) { return; }
        var dS = startDeg;
        var dE = endDeg;
        if (gapDeg > 0.0 && absoluteFloat(sweep) > gapDeg) {
            var ins = gapDeg / 2.0;
            if (sweep > 0.0) { dS += ins; dE -= ins; }
            else             { dS -= ins; dE += ins; }
        }
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(thickness);
        dc.drawArc(cx, cy, r,
                   sweep >= 0.0 ? Graphics.ARC_CLOCKWISE : Graphics.ARC_COUNTER_CLOCKWISE,
                   toGarminDegrees(dS), toGarminDegrees(dE));
    }

    function drawArcMarker(dc as Dc, cx as Number, cy as Number,
                           r as Number, thickness as Number,
                           angleDeg as Float) as Void {
        var rad = toRadians(angleDeg);
        var mx  = roundNumber(cx + (Math.cos(rad) * r));
        var my  = roundNumber(cy + (Math.sin(rad) * r));
        dc.setColor(COLOR_BG,    COLOR_BG);    dc.fillCircle(mx, my, thickness + 2);
        dc.setColor(COLOR_WHITE, COLOR_WHITE); dc.fillCircle(mx, my, thickness);
    }

    function drawPanel(dc as Dc, cx as Number, cy as Number,
                       w as Number, h as Number,
                       cornerR as Number, color as Number) as Void {
        dc.setColor(color, color);
        dc.fillRoundedRectangle(cx - (w / 2), cy - (h / 2), w, h, cornerR);
    }

    // =========================================================================
    // Core text primitive
    // KEY FIX: TEXT_JUSTIFY_VCENTER eliminates all textH calculation hacks.
    // Garmin handles vertical centering internally – no more dotted-cross bug.
    // =========================================================================
    function lbl(dc as Dc, cx as Number, cy as Number,
                 text as String, font, color as Number) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, cy, font, text,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // =========================================================================
    // Font pickers
    // =========================================================================
    // GUARD: FONT_NUMBER_* support only "0-9 : . , %" – no dash "-".
    // "--:--" passed to FONT_NUMBER renders as garbage (crossed-dot glyphs).
    // Only use number fonts when the string is a real mm:ss pace value.
    function pickCenterFont(dc as Dc, text as String, maxW as Number) {
        var isRealPace = !text.equals("--:--");
        if (isRealPace) {
            if (textWidth(dc, text, Graphics.FONT_NUMBER_MEDIUM) <= maxW) { return Graphics.FONT_NUMBER_MEDIUM; }
            if (textWidth(dc, text, Graphics.FONT_NUMBER_MILD)   <= maxW) { return Graphics.FONT_NUMBER_MILD;   }
        }
        if (textWidth(dc, text, Graphics.FONT_LARGE)  <= maxW) { return Graphics.FONT_LARGE;  }
        if (textWidth(dc, text, Graphics.FONT_MEDIUM) <= maxW) { return Graphics.FONT_MEDIUM; }
        return Graphics.FONT_SMALL;
    }

    function pickEmphasisFont(dc as Dc, text as String, maxW as Number) {
        if (textWidth(dc, text, Graphics.FONT_LARGE)  <= maxW) { return Graphics.FONT_LARGE;  }
        if (textWidth(dc, text, Graphics.FONT_MEDIUM) <= maxW) { return Graphics.FONT_MEDIUM; }
        return Graphics.FONT_SMALL;
    }

    function pickCompactFont(dc as Dc, text as String, maxW as Number) {
        if (textWidth(dc, text, Graphics.FONT_MEDIUM) <= maxW) { return Graphics.FONT_MEDIUM; }
        return Graphics.FONT_SMALL;
    }

    function pickTimeFont(dc as Dc, text as String, maxW as Number) {
        if (textWidth(dc, text, Graphics.FONT_MEDIUM) <= maxW) { return Graphics.FONT_MEDIUM; }
        return Graphics.FONT_SMALL;
    }

    function textWidth(dc as Dc, text as String, font) as Number {
        var dims = dc.getTextDimensions(text, font);
        return (dims != null && dims.size() > 0) ? dims[0] as Number : 0;
    }

    // =========================================================================
    // Colour selectors
    // =========================================================================
    function colorForPace(paceSeconds as Float) as Number {
        if (paceSeconds <= 0.0) { return COLOR_WHITE; }
        return absoluteFloat(paceSeconds - config.targetPaceSec)
               <= config.paceToleranceSec ? COLOR_GREEN : COLOR_RED;
    }

    function colorForDelta(deltaSeconds as Float) as Number {
        if (absoluteFloat(deltaSeconds) <= 1.5) { return COLOR_BLUE;  }
        return deltaSeconds < 0.0 ? COLOR_GREEN : COLOR_RED;
    }

    function colorForProjectedFinish() as Number {
        if (paceLogic.projectedFinishSec <= 0 || config.targetTimeSec <= 0) { return COLOR_WHITE; }
        return paceLogic.projectedFinishSec <= config.targetTimeSec ? COLOR_GREEN : COLOR_RED;
    }

    function colorForPower(value as Number, available as Boolean) as Number {
        if (!available || value <= 0) { return COLOR_MUTED; }
        return colorForZoneIndex(zoneIndexForValue(value, config.powerZones as Array<Number>));
    }

    function colorForCadence(value as Number) as Number {
        var cz = config.cadenceZones as Array<Number>;
        if (value <= 0)                 { return COLOR_MUTED;  }
        if (value < (cz[0] as Number))  { return COLOR_ORANGE; }
        if (value < (cz[1] as Number))  { return COLOR_BLUE;   }
        if (value <= (cz[2] as Number)) { return COLOR_GREEN;  }
        if (value <= (cz[3] as Number)) { return COLOR_BLUE;   }
        return COLOR_RED;
    }

    function colorForReserve(value as Number) as Number {
        if (value >= 85) { return COLOR_BLUE;   }
        if (value >= 65) { return COLOR_GREEN;  }
        if (value >= 40) { return COLOR_ORANGE; }
        return COLOR_RED;
    }

    function colorForHrValue(value as Float) as Number {
        if (value <= 0.0) { return COLOR_WHITE; }
        return colorForZoneIndex(zoneIndexForValue(value.toNumber(),
                                                   config.hrZones as Array<Number>));
    }

    function colorForVerticalRatio() as Number {
        if (!hasVerticalRatio) { return COLOR_MUTED; }
        var vz = config.verticalRatioZones as Array<Float>;
        if (verticalRatio <= (vz[0] as Float)) { return COLOR_GREEN;  }
        if (verticalRatio <= (vz[1] as Float)) { return COLOR_BLUE;   }
        if (verticalRatio <= (vz[2] as Float)) { return COLOR_ORANGE; }
        return COLOR_RED;
    }

    function zoneIndexForValue(value as Number, thresholds as Array<Number>) as Number {
        if (value <= 0 || thresholds == null || thresholds.size() <= 0) { return 0; }
        for (var i = 0; i < thresholds.size(); i += 1) {
            if (value <= (thresholds[i] as Number)) { return i + 1; }
        }
        return thresholds.size();
    }

    function colorForZoneIndex(index as Number) as Number {
        if (index <= 1) { return COLOR_MUTED;  }
        if (index == 2) { return COLOR_BLUE;   }
        if (index == 3) { return COLOR_GREEN;  }
        if (index == 4) { return COLOR_ORANGE; }
        return COLOR_RED;
    }

    // =========================================================================
    // Formatters
    // =========================================================================
    function formatDistance(valueKm as Float) as String {
        if (valueKm < 0.0) { valueKm = 0.0; }
        return valueKm.format("%.1f");
    }

    function formatPace(paceSeconds as Float) as String {
        if (paceSeconds <= 0.0 || paceSeconds > 1200.0) { return "--:--"; }
        var r = roundNumber(paceSeconds);
        return (r / 60).format("%d") + ":" + (r % 60).format("%02d");
    }

    function formatSignedPaceDelta(deltaSeconds as Float) as String {
        var prefix = "+";
        if (deltaSeconds < 0.0) { prefix = "-"; deltaSeconds = -deltaSeconds; }
        var r = roundNumber(deltaSeconds);
        return prefix + (r / 60).format("%d") + ":" + (r % 60).format("%02d");
    }

    function formatTimeHms(totalSeconds as Number) as String {
        if (totalSeconds < 0) { totalSeconds = 0; }
        var hh = totalSeconds / 3600;
        var mm = (totalSeconds % 3600) / 60;
        var ss = totalSeconds % 60;
        return hh.format("%d") + ":" + mm.format("%02d") + ":" + ss.format("%02d");
    }

    function formatPower(value as Number, available as Boolean) as String {
        return (!available || value <= 0) ? "--" : value.format("%d");
    }
    function formatCadence(value as Number) as String   { return value > 0 ? value.format("%d") : "--"; }
    function formatReserve(value as Number) as String   { return value.format("%d") + "%"; }
    function formatVerticalRatio() as String {
        if (!hasVerticalRatio) { return "--.--%"; }
        return verticalRatio.format("%.1f") + "%";
    }
    function formatHeartRateNumber(value) as String {
        if (value == null || value <= 0) { return "--"; }
        return roundNumber(value).format("%d");
    }

    // =========================================================================
    // Math helpers
    // =========================================================================
    function S(value as Number, scale as Float) as Number {
        return roundNumber(value.toFloat() * scale);
    }
    function scaled(value as Number, scale as Float) as Number { return S(value, scale); }
    function toRadians(degrees as Float) as Float { return degrees * PI / 180.0; }
    function toGarminDegrees(degrees as Float) as Float {
        var g = 360.0 - degrees;
        while (g <    0.0) { g += 360.0; }
        while (g >= 360.0) { g -= 360.0; }
        return g;
    }
    function roundNumber(value) as Number {
        if (value < 0) { return (value - 0.5).toNumber(); }
        return (value + 0.5).toNumber();
    }
    function absoluteFloat(value as Float) as Float { return value < 0.0 ? -value : value; }
}
