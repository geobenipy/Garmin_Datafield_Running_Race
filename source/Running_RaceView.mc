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
//  y=108  Feld 11  Cadence  x=92   |  Feld 9  TargetPace cx=208 MUTED  |  Feld 12  Reserve  x=324
//  y=140  Feld  2  [panel cx=94 w=108]  |  Feld  8  Delta cx=208  |  Feld  3  [panel cx=322 w=108]
//  y=208  [CENTER PANEL w=150 h=68]  Feld 6 x=92  Feld 1  Feld 7 x=324
//  y=272  Feld  4  [panel cx=134 w=126 h=48]  |  Feld  5  [panel cx=282 w=126 h=48]
//  y=318  Feld 14  AvgHR x=92  |  Feld 16  VR cx=208 FONT_TINY  |  Feld 15  RollHR x=324
//  y=362  Feld 13  Current HR  cx=208  FONT_LARGE
// =============================================================================

class Running_RaceView extends WatchUi.DataField {

    const DESIGN_SIZE = 416.0;
    const PI          = 3.14159265;

    // DEV ONLY – when true, compute() skips live sensors and renders a fixed,
    // representative mid-marathon state so the layout/colours can be reviewed in
    // the simulator without a live activity.  Kept false in source; `run.ps1
    // -Preview` flips it to true only for the duration of a screenshot build.
    const PREVIEW_MODE = false;

    const COLOR_BG           = 0x060606;
    const COLOR_RING         = 0xB83B4F;
    const COLOR_WHITE        = 0xF4F4F4;
    const COLOR_MUTED        = 0x8E949B;
    const COLOR_BLUE         = 0x63C6F5;
    const COLOR_GREEN        = 0x49C56D;
    const COLOR_RED          = 0xD24B3D;
    const COLOR_ORANGE       = 0xE59B3E;
    const COLOR_PANEL_CENTER = 0x243244;   // hero pace tile – slightly elevated
    const COLOR_PANEL_TIME    = 0x181D24;  // calm dark slate (times)
    const COLOR_PANEL_DIST    = 0x181D24;  // calm dark slate (dist / remaining)
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
    // compute() runs several times per second on a tight time budget. It is
    // wrapped whole in try/catch: a single unexpected sensor value must never
    // be allowed to throw out of here and freeze/kill the field mid-race.
    function compute(info as Activity.Info) as Void {
        if (PREVIEW_MODE) { applyPreview(); return; }
        try {
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
        } catch (ex) {
            // Swallow: keep the last good values on screen rather than crash.
        }
    }

    // DEV ONLY – populate a fixed, internally-consistent race state (~13 km into
    // a 5:00/km marathon, on pace) so the field can be reviewed without sensors.
    function applyPreview() as Void {
        paceLogic.elapsedSec         = 3900;       // 1:05:00
        paceLogic.distanceKm         = 13.2;
        paceLogic.remainingKm        = 29.0;
        paceLogic.smoothedPaceSec    = 296.0;      // 4:56  (hero, slightly ahead)
        paceLogic.averagePaceSec     = 299.0;      // 4:59
        paceLogic.rolling5MinPaceSec = 298.0;      // 4:58
        paceLogic.projectedFinishSec = 12500;      // 3:28:20 (under 3:30 target)

        hrLogic.currentHr     = 155;
        hrLogic.averageHr     = 150.0;
        hrLogic.rolling5MinHr = 153.0;
        hrLogic.driftActive   = false;

        reserveLogic.reservePercent = 78;

        currentPower     = 248;  hasPower = true;
        currentCadence   = 176;
        verticalRatio    = 7.8;  hasVerticalRatio = true;
        gpsBars          = 4;
        chestStatus      = 2;
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
    // onUpdate  – draw the 10 fields (lean layout)
    // =========================================================================
    function onUpdate(dc as Dc) as Void {
        var w      = dc.getWidth();
        var h      = dc.getHeight();
        var size   = (w < h ? w : h).toFloat();
        var scale  = size / DESIGN_SIZE;
        var cx     = w / 2;
        var cy     = h / 2;

        // ── background ────────────────────────────────────────────────────
        // Clear happens outside the try so the screen is always wiped even if
        // a later draw call throws; the rest is guarded so a bad value can
        // never leave the field frozen mid-race.
        dc.setColor(COLOR_BG, COLOR_BG);
        dc.clear();
        try {
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
        // Flank the Power number (R1); the whole upper data row is otherwise
        // free, so they never collide with a value.
        drawChestIcon(dc, S(116, scale), S(72, scale), S(4, scale));
        drawGpsIcon  (dc, S(288, scale), S(72, scale), S(5, scale));

        // =====================================================================
        // Lean 10-field layout (down from 16).  A vertical spine of the three
        // anchors — Power (top), current PACE (centre hero), current HR
        // (bottom) — with flanking pairs; the smaller field count buys bigger
        // type and more air.  Row y-centres / panel heights clear neighbours:
        //   R1  y= 64  Power (centre, big)                         [power arc]
        //   R2  y=116  Distanz "done/total" (panel) | Reserve %
        //   R3  y=200  Ø-Pace | CURRENT PACE (hero) | Delta
        //   R4  y=270  Elapsed (panel) | Finish (panel)
        //   R5  y=318  5-min HR trend (centre)
        //   R6  y=356  Current HR (centre, big)                    [HR arc]
        // =====================================================================

        // ── R1  Power ────────────────────────────────────────────────────
        var pwrTxt = formatPower(currentPower, hasPower);
        lbl(dc, cx, S(64, scale), pwrTxt,
            pickEmphasisFont(dc, pwrTxt, S(150, scale)),
            colorForPower(currentPower, hasPower));

        // ── R2  Distanz (done/total) | Reserve % ─────────────────────────
        // One panel replaces the old separate distance + remaining fields:
        // "13.2/42" reads "13.2 of 42 km" at a glance.
        var distTxt = formatDistance(paceLogic.distanceKm) + "/" +
                      config.raceDistanceKm.toNumber().format("%d");
        drawPanel(dc, S(116, scale), S(130, scale), S(132, scale), S(40, scale), S(10, scale), COLOR_PANEL_DIST);
        lbl(dc, S(116, scale), S(130, scale), distTxt,
            pickCompactFont(dc, distTxt, S(118, scale)), COLOR_WHITE);

        lbl(dc, S(300, scale), S(130, scale),
            formatReserve(reserveLogic.reservePercent), Graphics.FONT_SMALL,
            colorForReserve(reserveLogic.reservePercent));

        // ── R3  Ø-Pace | CURRENT PACE (hero) | Delta ─────────────────────
        // Pace module: whole-race average (left) · current pace (hero) ·
        // instant delta to target (right).
        var p1cy = S(204, scale);
        var p1w  = S(140, scale);
        var p1h  = S(64,  scale);
        drawPanel(dc, cx, p1cy, p1w, p1h, S(10, scale), COLOR_PANEL_CENTER);

        lbl(dc, S(90, scale), p1cy,
            formatPace(paceLogic.averagePaceSec), Graphics.FONT_SMALL,
            colorForMeasuredPace(paceLogic.averagePaceSec));

        lbl(dc, S(326, scale), p1cy,
            formatSignedPaceDelta(paceLogic.deltaToTargetSec()), Graphics.FONT_MEDIUM,
            colorForDelta(paceLogic.deltaToTargetSec()));

        drawPacePanel(dc, cx, p1cy, p1w, p1h, scale);

        // ── R4  Elapsed | Finish ─────────────────────────────────────────
        var elapsed = formatTimeHms(paceLogic.elapsedSec);
        var finish  = formatTimeHms(paceLogic.projectedFinishSec);
        drawPanel(dc, S(116, scale), S(276, scale), S(140, scale), S(42, scale), S(10, scale), COLOR_PANEL_TIME);
        lbl(dc, S(116, scale), S(276, scale), elapsed,
            pickTimeFont(dc, elapsed, S(120, scale)), COLOR_WHITE);

        drawPanel(dc, S(300, scale), S(276, scale), S(140, scale), S(42, scale), S(10, scale), COLOR_PANEL_TIME);
        lbl(dc, S(300, scale), S(276, scale), finish,
            pickTimeFont(dc, finish, S(120, scale)), colorForProjectedFinish());

        // ── R5  HR: 5-min trend (left) | Current HR (centre, big) ────────
        // Mirrors the pace module: the trend sits left of the big anchor
        // instead of stacked on top of it (which overlapped).
        lbl(dc, S(90, scale), S(348, scale),
            formatHeartRateNumber(hrLogic.rolling5MinHr), Graphics.FONT_SMALL,
            colorForHrValue(hrLogic.rolling5MinHr));

        var hrTxt = formatHeartRateNumber(hrLogic.currentHr);
        lbl(dc, cx, S(348, scale), hrTxt,
            pickEmphasisFont(dc, hrTxt, S(140, scale)),
            colorForHrValue(hrLogic.currentHr.toFloat()));
        } catch (ex) {
            // A draw failure must never freeze the field; the background is
            // already cleared, so we simply skip the rest of this frame.
        }
    }

    // =========================================================================
    // Feld 1 – pace drawn on the center panel
    // =========================================================================
    function drawPacePanel(dc as Dc, cx as Number, cy as Number,
                           panelW as Number, panelH as Number,
                           scale as Float) as Void {

        var paceTxt   = formatPace(paceLogic.smoothedPaceSec);
        var paceColor = colorForPace(paceLogic.smoothedPaceSec);

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
            // Header + pace must share the panel's height, so drop the pace to
            // a MEDIUM (non-number) font that fits under the header without
            // spilling past the rounded corners.
            lbl(dc, cx, cy - (panelH / 2) + S(12, scale),
                hdrTxt, Graphics.FONT_XTINY, hdrColor);
            lbl(dc, cx, cy + S(9, scale),
                paceTxt, Graphics.FONT_MEDIUM, paceColor);
        } else {
            lbl(dc, cx, cy,
                paceTxt, pickCenterFont(dc, paceTxt, panelW - S(16, scale)),
                paceColor);
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
    // Hero current pace: green when within tolerance of target, red otherwise.
    function colorForPace(paceSeconds as Float) as Number {
        if (paceSeconds <= 0.0) { return COLOR_WHITE; }
        return absoluteFloat(paceSeconds - config.targetPaceSec)
               <= config.paceToleranceSec ? COLOR_GREEN : COLOR_RED;
    }

    // Neutral colour for a measured pace readout (avg / rolling): white when we
    // have a value, muted when we don't.  Deviation colour is reserved for the
    // hero current-pace and the delta so the eye has a single status axis.
    function colorForMeasuredPace(paceSeconds as Float) as Number {
        return (paceSeconds > 0.0 && paceSeconds <= 1200.0) ? COLOR_WHITE : COLOR_MUTED;
    }

    function colorForDelta(deltaSeconds as Float) as Number {
        if (absoluteFloat(deltaSeconds) <= 1.5) { return COLOR_WHITE; }
        return deltaSeconds < 0.0 ? COLOR_GREEN : COLOR_RED;
    }

    function colorForProjectedFinish() as Number {
        if (paceLogic.projectedFinishSec <= 0 || config.targetTimeSec <= 0) { return COLOR_WHITE; }
        return paceLogic.projectedFinishSec <= config.targetTimeSec ? COLOR_GREEN : COLOR_RED;
    }

    // Effort metrics (power / HR) are tinted by training zone, so the number
    // matches its own arc segment and effort reads at a glance:
    //   z1 muted · z2 blue · z3 green · z4 orange · z5 red.
    function colorForPower(value as Number, available as Boolean) as Number {
        if (!available || value <= 0) { return COLOR_MUTED; }
        return colorForZoneIndex(
            zoneIndexForValue(value, config.powerZones as Array<Number>));
    }

    // Cadence carries a flat cyan accent (its zones are narrow and less telling
    // than a zone tint would suggest).
    function colorForCadence(value as Number) as Number {
        return value <= 0 ? COLOR_MUTED : COLOR_BLUE;
    }

    // Reserve is neutral until it runs low, then a single red warning.
    function colorForReserve(value as Number) as Number {
        return value < 40 ? COLOR_RED : COLOR_WHITE;
    }

    // HR numbers tinted by training zone (matches the HR arc segments).
    function colorForHrValue(value as Float) as Number {
        if (value <= 0.0) { return COLOR_MUTED; }
        return colorForZoneIndex(
            zoneIndexForValue(value.toNumber(), config.hrZones as Array<Number>));
    }

    function colorForVerticalRatio() as Number {
        return hasVerticalRatio ? COLOR_WHITE : COLOR_MUTED;
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
