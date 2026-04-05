import Toybox.Activity;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.Position;
import Toybox.Sensor;
import Toybox.WatchUi;

// ---------------------------------------------------------------------------
// Running_RaceView  –  main DataField view  (Garmin Fenix 8, 416 × 416 px)
// ---------------------------------------------------------------------------

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

    var currentPower   = 0;
    var hasPower       = false;
    var currentCadence = 0;

    var verticalRatio    = 0.0;
    var hasVerticalRatio = false;

    var gpsBars     = 0;
    var chestStatus = 0;

    function initialize() {
        DataField.initialize();
        config       = new RaceConfig();
        paceLogic    = new RacePaceLogic(config);
        hrLogic      = new RaceHeartRateLogic(config);
        reserveLogic = new RaceReserveLogic(config);
        alertLogic   = new RaceAlertLogic(config);
    }

    // -----------------------------------------------------------------------
    // compute()
    // -----------------------------------------------------------------------
    function compute(info as Activity.Info) as Void {
        var elapsedSec = paceLogic.elapsedSec;
        var distKm     = paceLogic.distanceKm;

        if (info.elapsedTime != null) {
            elapsedSec = (info.elapsedTime / 1000).toNumber();
        }
        if (info.elapsedDistance != null) {
            distKm = info.elapsedDistance / 1000.0;
        }

        var isNewSecond = paceLogic.update(elapsedSec, distKm,
                                           info.currentSpeed,
                                           info.averageSpeed);
        hrLogic.update(info, isNewSecond);
        updatePerformanceMetrics(info);

        if (isNewSecond) {
            alertLogic.clearExpiredBanner(paceLogic.elapsedSec);
            alertLogic.checkNutrition(paceLogic);
        }

        if (paceLogic.isHeavyRefreshDue()) {
            paceLogic.refreshHeavy();
            hrLogic.refreshHeavy(paceLogic);
            reserveLogic.refreshHeavy(paceLogic, hrLogic,
                                      currentPower, hasPower);
            refreshSensorStatus(info);
            alertLogic.checkFiveKmFeedback(paceLogic, hrLogic,
                                           reserveLogic.reservePercent);
        }
    }

    function updatePerformanceMetrics(info as Activity.Info) as Void {
        hasPower = false;
        if (info.currentPower != null && info.currentPower > 0) {
            currentPower = info.currentPower as Number;
            hasPower     = true;
        }

        if (info.currentCadence != null && info.currentCadence > 0) {
            currentCadence = info.currentCadence as Number;
        }

        hasVerticalRatio = false;
        if (info has :verticalRatio) {
            var vr = info.verticalRatio;
            if (vr != null && vr > 0.0) {
                verticalRatio    = vr as Float;
                hasVerticalRatio = true;
            }
        }
    }

    function refreshSensorStatus(info as Activity.Info) as Void {
        refreshGpsStatus(info);
        refreshChestStatus();
    }

    function refreshGpsStatus(info as Activity.Info) as Void {
        gpsBars = 0;
        if (info has :gpsAccuracy) {
            var acc = info.gpsAccuracy;
            if (acc != null) {
                if      (acc == Position.QUALITY_GOOD)   { gpsBars = 4; }
                else if (acc == Position.QUALITY_USABLE) { gpsBars = 3; }
                else if (acc == Position.QUALITY_POOR)   { gpsBars = 1; }
            }
        }
    }

    function refreshChestStatus() as Void {
        chestStatus = 0;
        try {
            if (Sensor has :getRegisteredSensors) {
                var iterator = Sensor.getRegisteredSensors(Sensor.SENSOR_HEARTRATE);
                if (iterator != null) {
                    var sInfo = iterator.next();
                    while (sInfo != null) {
                        if (sInfo.enabled) {
                            if (sInfo.technology == Sensor.SENSOR_TECHNOLOGY_ANT) {
                                chestStatus = 2;
                                return;
                            }
                            if (chestStatus < 1) { chestStatus = 1; }
                        }
                        sInfo = iterator.next();
                    }
                }
            }
        } catch (e) {
            chestStatus = 0;
        }
        if (hasVerticalRatio && chestStatus < 2) { chestStatus = 2; }
    }

    // Correct DataField lap callback name
    function onTimerLap() as Void {
        paceLogic.handleLapTrigger();
        hrLogic.resetDrift(paceLogic.lastLapResetSec);
        alertLogic.showBanner("Lap synced", COLOR_BLUE,
                               paceLogic.elapsedSec + 8);
    }

    // -----------------------------------------------------------------------
    // onUpdate  –  draw all 16 fields
    // -----------------------------------------------------------------------
    function onUpdate(dc as Dc) as Void {
        var w      = dc.getWidth();
        var h      = dc.getHeight();
        var size   = w < h ? w : h;
        var scale  = size.toFloat() / DESIGN_SIZE;
        var cx     = w / 2;
        var cy     = h / 2;
        var radius = scaled(202, scale);

        // ── background ──────────────────────────────────────────────────────
        dc.setColor(COLOR_BG, COLOR_BG);
        dc.clear();
        dc.fillCircle(cx, cy, radius);

        // ── zone arcs (drawn first, everything else overlays them) ──────────
        var arcR = scaled(182, scale);
        var arcT = scaled(9,   scale);
        drawZoneArc(dc, cx, cy, arcR, arcT, 215.0, 325.0,
                    config.powerZones as Array<Number>, currentPower);
        drawZoneArc(dc, cx, cy, arcR, arcT, 145.0, 35.0,
                    config.hrZones    as Array<Number>, hrLogic.currentHr);
        drawOuterRing(dc, cx, cy, radius);

        // ── sensor icons ─────────────────────────────────────────────────────
        drawChestIcon(dc, scaled(54,  scale), scaled(104, scale), scaled(4, scale));
        drawGpsIcon  (dc, scaled(352, scale), scaled(104, scale), scaled(5, scale));

        // ════════════════════════════════════════════════════════════════════
        // ROW 1  –  Feld 10: Running Power (top center)
        // y=56   FONT_LARGE
        // ════════════════════════════════════════════════════════════════════
        var pwrText = formatPower(currentPower, hasPower);
        drawCenteredMetric(dc, cx, scaled(56, scale),
            pwrText,
            pickEmphasisFont(dc, pwrText, scaled(108, scale)),
            colorForPower(currentPower, hasPower));

        // ════════════════════════════════════════════════════════════════════
        // ROW 2  –  Feld 11: Cadence (left)  ·  Feld 12: Reserve (right)
        // y=86   FONT_SMALL
        // ════════════════════════════════════════════════════════════════════
        drawCenteredMetric(dc, scaled(128, scale), scaled(86, scale),
            formatCadence(currentCadence), Graphics.FONT_SMALL,
            colorForCadence(currentCadence));

        drawCenteredMetric(dc, scaled(288, scale), scaled(86, scale),
            formatReserve(reserveLogic.reservePercent), Graphics.FONT_SMALL,
            colorForReserve(reserveLogic.reservePercent));

        // ════════════════════════════════════════════════════════════════════
        // ROW 3  –  Feld 9: Strategy/target pace for this segment
        // y=112   FONT_SMALL   Orange = "this is your target"
        // ════════════════════════════════════════════════════════════════════
        // Shows the configured target pace (e.g. "5:00") as a constant
        // orange reference – the pace the runner should hold this km.
        drawCenteredMetric(dc, cx, scaled(112, scale),
            formatPace(config.targetPaceSec), Graphics.FONT_SMALL,
            COLOR_ORANGE);

        // ════════════════════════════════════════════════════════════════════
        // ROW 4  –  Feld 2: Distance (left panel)
        //           Feld 8: Delta (CENTER, between the panels)
        //           Feld 3: Remaining (right panel)
        //
        // KEY LAYOUT RULE: All three elements share the same y = 164.
        // The distance panels are offset left/right to leave a clear center
        // gap where the delta value sits.
        //   Left panel:   cx=94,  x from 40 to 148
        //   Center gap:   148 → 268  (120 px – wide enough for any delta text)
        //   Right panel:  cx=322, x from 268 to 376
        // ════════════════════════════════════════════════════════════════════
        // Feld 2 – Distance covered
        drawRoundedPanel(dc, scaled(94, scale), scaled(164, scale),
                         scaled(108, scale), scaled(44, scale),
                         scaled(9, scale), COLOR_PANEL_DIST);
        drawCenteredMetric(dc, scaled(94, scale), scaled(164, scale),
            formatDistance(paceLogic.distanceKm),
            pickEmphasisFont(dc, formatDistance(paceLogic.distanceKm),
                             scaled(96, scale)),
            COLOR_WHITE);

        // Feld 3 – Remaining distance
        drawRoundedPanel(dc, scaled(322, scale), scaled(164, scale),
                         scaled(108, scale), scaled(44, scale),
                         scaled(9, scale), COLOR_PANEL_DIST);
        drawCenteredMetric(dc, scaled(322, scale), scaled(164, scale),
            formatDistance(paceLogic.remainingKm),
            pickEmphasisFont(dc, formatDistance(paceLogic.remainingKm),
                             scaled(96, scale)),
            COLOR_WHITE);

        // Feld 8 – Signed delta (center gap between panels)
        var deltaText = formatSignedPaceDelta(paceLogic.deltaToTargetSec());
        drawCenteredMetric(dc, cx, scaled(164, scale),
            deltaText,
            pickCompactFont(dc, deltaText, scaled(108, scale)),
            colorForDelta(paceLogic.deltaToTargetSec()));

        // ════════════════════════════════════════════════════════════════════
        // ROW 5  –  Feld 6: Avg pace (left)
        //           Feld 1: Current smoothed pace (center panel, DOMINANT)
        //           Feld 7: Rolling pace (right)
        //
        // The center panel is drawn first.  Feld 6 and Feld 7 are at the
        // same cy as the panel but outside its x-bounds (panel: x 134–282,
        // flanks at x=76 and x=340), so no background conflict.
        // ════════════════════════════════════════════════════════════════════
        var p1W  = scaled(148, scale);
        var p1H  = scaled(68,  scale);
        var p1CY = scaled(230, scale);

        // Draw center panel background first
        drawRoundedPanel(dc, cx, p1CY, p1W, p1H, scaled(13, scale), COLOR_PANEL_CENTER);

        // Feld 6 – Average pace (left flank)
        drawCenteredMetric(dc, scaled(76, scale), p1CY,
            formatPace(paceLogic.averagePaceSec), Graphics.FONT_SMALL,
            colorForPace(paceLogic.averagePaceSec));

        // Feld 7 – 5-min rolling pace (right flank)
        drawCenteredMetric(dc, scaled(340, scale), p1CY,
            formatPace(paceLogic.rolling5MinPaceSec), Graphics.FONT_SMALL,
            colorForPace(paceLogic.rolling5MinPaceSec));

        // Feld 1 – Current pace (on top of panel)
        drawFieldOne(dc, cx, p1CY, p1W, p1H, scale);

        // ════════════════════════════════════════════════════════════════════
        // ROW 6  –  Feld 4: Elapsed (left panel)  ·  Feld 5: Finish (right)
        // y=292   h=48
        // ════════════════════════════════════════════════════════════════════
        drawRoundedPanel(dc, scaled(128, scale), scaled(292, scale),
                         scaled(124, scale), scaled(48, scale),
                         scaled(10, scale), COLOR_PANEL_TIME);
        drawCenteredMetric(dc, scaled(128, scale), scaled(292, scale),
            formatTimeHms(paceLogic.elapsedSec),
            pickTimeFont(dc, formatTimeHms(paceLogic.elapsedSec), scaled(112, scale)),
            COLOR_WHITE);

        drawRoundedPanel(dc, scaled(288, scale), scaled(292, scale),
                         scaled(124, scale), scaled(48, scale),
                         scaled(10, scale), COLOR_PANEL_TIME);
        drawCenteredMetric(dc, scaled(288, scale), scaled(292, scale),
            formatTimeHms(paceLogic.projectedFinishSec),
            pickTimeFont(dc, formatTimeHms(paceLogic.projectedFinishSec),
                         scaled(112, scale)),
            colorForProjectedFinish());

        // ════════════════════════════════════════════════════════════════════
        // ROW 7  –  Feld 14: Avg HR (left)
        //           Feld 16: Vert ratio (center, tiny)
        //           Feld 15: Rolling HR (right)
        // y=336   all three on the same line
        // ════════════════════════════════════════════════════════════════════
        drawCenteredMetric(dc, scaled(96,  scale), scaled(336, scale),
            formatHeartRateNumber(hrLogic.averageHr), Graphics.FONT_SMALL,
            colorForHrValue(hrLogic.averageHr));

        drawCenteredMetric(dc, cx, scaled(336, scale),
            formatVerticalRatio(), Graphics.FONT_XTINY,
            colorForVerticalRatio());

        drawCenteredMetric(dc, scaled(320, scale), scaled(336, scale),
            formatHeartRateNumber(hrLogic.rolling5MinHr), Graphics.FONT_SMALL,
            colorForHrValue(hrLogic.rolling5MinHr));

        // ════════════════════════════════════════════════════════════════════
        // ROW 8  –  Feld 13: Current HR  (bottom center, large)
        // y=386   second most important metric after pace
        // ════════════════════════════════════════════════════════════════════
        drawCenteredMetric(dc, cx, scaled(386, scale),
            formatHeartRateNumber(hrLogic.currentHr),
            pickEmphasisFont(dc, formatHeartRateNumber(hrLogic.currentHr),
                             scaled(110, scale)),
            colorForHrValue(hrLogic.currentHr.toFloat()));
    }

    // -----------------------------------------------------------------------
    // Feld 1 – Current smoothed pace inside the center panel.
    // Panel cy=230, h=68.  Without header: pace text perfectly centered.
    // With banner/drift header: header at panel top, pace nudged down.
    // -----------------------------------------------------------------------
    function drawFieldOne(dc as Dc,
                          cx as Number, cy as Number,
                          panelW as Number, panelH as Number,
                          scale as Float) as Void {

        var paceText = formatPace(paceLogic.smoothedPaceSec);
        var paceFont = pickCenterFont(dc, paceText, panelW - scaled(16, scale));

        var headerText  = "";
        var headerColor = COLOR_WHITE;
        if (alertLogic.hasActiveBanner(paceLogic.elapsedSec)) {
            headerText  = alertLogic.bannerText;
            headerColor = alertLogic.bannerColor as Number;
        } else if (hrLogic.driftActive) {
            headerText  = "DRIFT +" + hrLogic.driftDeltaBpm.format("%d");
            headerColor = COLOR_ORANGE;
        }

        if (!headerText.equals("")) {
            // Header at top of panel; shift pace center down slightly
            drawCenteredMetric(dc, cx,
                cy - (panelH / 2) + scaled(10, scale),
                headerText, Graphics.FONT_XTINY, headerColor);
            drawCenteredMetric(dc, cx, cy + scaled(8, scale),
                paceText, paceFont,
                colorForPace(paceLogic.smoothedPaceSec));
        } else {
            // No header: perfectly centered in panel
            drawCenteredMetric(dc, cx, cy,
                paceText, paceFont,
                colorForPace(paceLogic.smoothedPaceSec));
        }
    }

    // -----------------------------------------------------------------------
    // Sensor icons
    // -----------------------------------------------------------------------
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
            var color = gpsBars > i ? COLOR_WHITE : COLOR_TRACK;
            var barH  = (i + 1) * 6;
            dc.setColor(color, color);
            dc.fillRectangle(x + (i * (barW + 1)), y + 8 - barH, barW, barH);
        }
    }

    // -----------------------------------------------------------------------
    // Arc / ring renderers
    // -----------------------------------------------------------------------
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

        drawNativeArc(dc, cx, cy, r, thickness,
                      startDeg, endDeg, 0.0, COLOR_TRACK);

        var prev = 0.0;
        for (var i = 0; i < thresholds.size(); i += 1) {
            var thr  = (thresholds[i] as Number).toFloat();
            var sAng = startDeg + ((prev / maxVal) * (endDeg - startDeg));
            var eAng = startDeg + ((thr  / maxVal) * (endDeg - startDeg));
            drawNativeArc(dc, cx, cy, r, thickness,
                          sAng, eAng, 2.6, colorForZoneIndex(i + 1));
            prev = thr;
        }
        dc.setPenWidth(1);

        if (currentValue > 0) {
            var capped = currentValue.toFloat();
            if (capped > maxVal) { capped = maxVal; }
            var markerAngle = startDeg + ((capped / maxVal) * (endDeg - startDeg));
            drawArcMarker(dc, cx, cy, r, thickness - 1, markerAngle);
        }
    }

    function drawNativeArc(dc as Dc, cx as Number, cy as Number,
                           r as Number, thickness as Number,
                           startDeg as Float, endDeg as Float,
                           gapDeg as Float, color as Number) as Void {
        var sweep = endDeg - startDeg;
        if (absoluteFloat(sweep) <= 0.2) { return; }

        var dStart = startDeg;
        var dEnd   = endDeg;
        if (gapDeg > 0.0 && absoluteFloat(sweep) > gapDeg) {
            var inset = gapDeg / 2.0;
            if (sweep > 0.0) { dStart += inset; dEnd -= inset; }
            else             { dStart -= inset; dEnd += inset; }
        }

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(thickness);
        var dir = sweep >= 0.0 ? Graphics.ARC_CLOCKWISE
                               : Graphics.ARC_COUNTER_CLOCKWISE;
        dc.drawArc(cx, cy, r, dir,
                   toGarminDegrees(dStart), toGarminDegrees(dEnd));
    }

    function drawArcMarker(dc as Dc, cx as Number, cy as Number,
                           r as Number, thickness as Number,
                           angleDeg as Float) as Void {
        var rad = toRadians(angleDeg);
        var mx  = roundNumber(cx + (Math.cos(rad) * r));
        var my  = roundNumber(cy + (Math.sin(rad) * r));
        dc.setColor(COLOR_BG,    COLOR_BG);
        dc.fillCircle(mx, my, thickness + 2);
        dc.setColor(COLOR_WHITE, COLOR_WHITE);
        dc.fillCircle(mx, my, thickness);
    }

    function drawRoundedPanel(dc as Dc, cx as Number, cy as Number,
                              w as Number, h as Number,
                              cornerR as Number, color as Number) as Void {
        dc.setColor(color, color);
        dc.fillRoundedRectangle(cx - (w / 2), cy - (h / 2), w, h, cornerR);
    }

    function drawCenteredMetric(dc as Dc, cx as Number, cy as Number,
                                text as String, font, color as Number) as Void {
        var dims  = dc.getTextDimensions(text, font);
        var textH = (dims != null && dims.size() > 1)
                  ? dims[1] as Number
                  : dc.getFontHeight(font);
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, cy - (textH / 2), font, text,
                    Graphics.TEXT_JUSTIFY_CENTER);
    }

    // -----------------------------------------------------------------------
    // Font pickers
    // -----------------------------------------------------------------------

    // BUG FIX: FONT_NUMBER_MEDIUM / FONT_NUMBER_MILD only contain the
    // characters 0-9, colon and decimal point.  The dash "-" is absent,
    // so "--:--" renders as garbage (looks like "--+--" in the simulator).
    // Guard: only use number fonts for actual numeric pace strings.
    function pickCenterFont(dc as Dc, text as String, maxW as Number) {
        var isNumericPace = !text.equals("--:--");
        if (isNumericPace) {
            if (textWidth(dc, text, Graphics.FONT_NUMBER_MEDIUM) <= maxW) {
                return Graphics.FONT_NUMBER_MEDIUM; }
            if (textWidth(dc, text, Graphics.FONT_NUMBER_MILD)   <= maxW) {
                return Graphics.FONT_NUMBER_MILD; }
        }
        if (textWidth(dc, text, Graphics.FONT_LARGE)  <= maxW) {
            return Graphics.FONT_LARGE; }
        if (textWidth(dc, text, Graphics.FONT_MEDIUM) <= maxW) {
            return Graphics.FONT_MEDIUM; }
        return Graphics.FONT_SMALL;
    }

    function pickEmphasisFont(dc as Dc, text as String, maxW as Number) {
        if (textWidth(dc, text, Graphics.FONT_LARGE)  <= maxW) {
            return Graphics.FONT_LARGE; }
        if (textWidth(dc, text, Graphics.FONT_MEDIUM) <= maxW) {
            return Graphics.FONT_MEDIUM; }
        return Graphics.FONT_SMALL;
    }

    function pickCompactFont(dc as Dc, text as String, maxW as Number) {
        if (textWidth(dc, text, Graphics.FONT_MEDIUM) <= maxW) {
            return Graphics.FONT_MEDIUM; }
        return Graphics.FONT_SMALL;
    }

    function pickTimeFont(dc as Dc, text as String, maxW as Number) {
        if (textWidth(dc, text, Graphics.FONT_MEDIUM) <= maxW) {
            return Graphics.FONT_MEDIUM; }
        return Graphics.FONT_SMALL;
    }

    function textWidth(dc as Dc, text as String, font) as Number {
        var dims = dc.getTextDimensions(text, font);
        return (dims != null && dims.size() > 0) ? dims[0] as Number : 0;
    }

    // -----------------------------------------------------------------------
    // Colour selectors
    // -----------------------------------------------------------------------
    function colorForPace(paceSeconds as Float) as Number {
        if (paceSeconds <= 0.0) { return COLOR_WHITE; }
        return absoluteFloat(paceSeconds - config.targetPaceSec)
               <= config.paceToleranceSec ? COLOR_GREEN : COLOR_RED;
    }

    function colorForDelta(deltaSeconds as Float) as Number {
        if (absoluteFloat(deltaSeconds) <= 1.5) { return COLOR_BLUE; }
        return deltaSeconds < 0.0 ? COLOR_GREEN : COLOR_RED;
    }

    function colorForProjectedFinish() as Number {
        if (paceLogic.projectedFinishSec <= 0 ||
            config.targetTimeSec <= 0) { return COLOR_WHITE; }
        return paceLogic.projectedFinishSec <= config.targetTimeSec
             ? COLOR_GREEN : COLOR_RED;
    }

    function colorForPower(value as Number, available as Boolean) as Number {
        if (!available || value <= 0) { return COLOR_MUTED; }
        return colorForZoneIndex(
            zoneIndexForValue(value, config.powerZones as Array<Number>));
    }

    // FIX: explicit `as Number` casts on cadenceZones array access
    function colorForCadence(value as Number) as Number {
        var cz = config.cadenceZones as Array<Number>;
        if (value <= 0)                          { return COLOR_MUTED;  }
        if (value < (cz[0] as Number))           { return COLOR_ORANGE; }
        if (value < (cz[1] as Number))           { return COLOR_BLUE;   }
        if (value <= (cz[2] as Number))          { return COLOR_GREEN;  }
        if (value <= (cz[3] as Number))          { return COLOR_BLUE;   }
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
        return colorForZoneIndex(
            zoneIndexForValue(value.toNumber(),
                              config.hrZones as Array<Number>));
    }

    // FIX: explicit `as Float` casts on verticalRatioZones array access
    function colorForVerticalRatio() as Number {
        if (!hasVerticalRatio) { return COLOR_WHITE; }
        var vz = config.verticalRatioZones as Array<Float>;
        if (verticalRatio <= (vz[0] as Float)) { return COLOR_GREEN;  }
        if (verticalRatio <= (vz[1] as Float)) { return COLOR_BLUE;   }
        if (verticalRatio <= (vz[2] as Float)) { return COLOR_ORANGE; }
        return COLOR_RED;
    }

    // FIX: typed thresholds parameter + explicit `as Number` cast inside loop
    function zoneIndexForValue(value      as Number,
                               thresholds as Array<Number>) as Number {
        if (value <= 0 || thresholds == null ||
            thresholds.size() <= 0) { return 0; }
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

    // -----------------------------------------------------------------------
    // Formatters
    // -----------------------------------------------------------------------
    function formatDistance(valueKm as Float) as String {
        if (valueKm < 0.0) { valueKm = 0.0; }
        return valueKm.format("%.1f");
    }

    function formatPace(paceSeconds as Float) as String {
        if (paceSeconds <= 0.0 || paceSeconds > 1200.0) { return "--:--"; }
        var rounded = roundNumber(paceSeconds);
        return (rounded / 60).format("%d") + ":" +
               (rounded % 60).format("%02d");
    }

    function formatSignedPaceDelta(deltaSeconds as Float) as String {
        var prefix = "+";
        if (deltaSeconds < 0.0) { prefix = "-"; deltaSeconds = -deltaSeconds; }
        var rounded = roundNumber(deltaSeconds);
        return prefix + (rounded / 60).format("%d") + ":" +
               (rounded % 60).format("%02d");
    }

    function formatTimeHms(totalSeconds as Number) as String {
        if (totalSeconds < 0) { totalSeconds = 0; }
        var h = totalSeconds / 3600;
        var m = (totalSeconds % 3600) / 60;
        var s = totalSeconds % 60;
        return h.format("%d") + ":" + m.format("%02d") + ":" + s.format("%02d");
    }

    function formatPower(value as Number, available as Boolean) as String {
        return (!available || value <= 0) ? "--" : value.format("%d");
    }

    function formatCadence(value as Number) as String {
        return value > 0 ? value.format("%d") : "--";
    }

    function formatReserve(value as Number) as String {
        return value.format("%d") + "%";
    }

    function formatVerticalRatio() as String {
        if (!hasVerticalRatio) { return "--.-%"; }
        return verticalRatio.format("%.1f") + "%";
    }

    function formatHeartRateNumber(value) as String {
        if (value == null || value <= 0) { return "--"; }
        return roundNumber(value).format("%d");
    }

    // -----------------------------------------------------------------------
    // Math helpers
    // -----------------------------------------------------------------------
    function scaled(value as Number, scale as Float) as Number {
        return roundNumber(value.toFloat() * scale);
    }

    function toRadians(degrees as Float) as Float {
        return degrees * PI / 180.0;
    }

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

    function absoluteFloat(value as Float) as Float {
        return value < 0.0 ? -value : value;
    }
}
