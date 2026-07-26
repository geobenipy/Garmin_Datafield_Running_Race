import Toybox.Activity;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.Sensor;
import Toybox.System;
import Toybox.WatchUi;

// =============================================================================
// Running_RaceView  –  Garmin Fenix 8 43mm  (416 × 416 px design canvas)
// =============================================================================
// Lean 10-value round-face layout (design-px, scaled at runtime).  Every value
// sits inside the ~r168 circle the two zone arcs (r182) leave free, so nothing
// ever touches a colour bar.
//   R1  y= 66  TOP effort (centre, big)  ·  phone + HR-strap glyphs  [top arc]
//   R2  y=132  Distanz done/total (left)        |  Reserve %  (right)
//   R3  y=200  Ø-Pace | CURRENT PACE (hero tile) | Delta-to-target
//   R4  y=262  Elapsed (left)                    |  Projected finish (right)
//   R5  y=310  5-min HR (small)  over  y=352 current HR (big)      [bottom arc]
// The TOP number and the TOP zone arc both track whichever effort metric the
// hardware provides: running power when a meter is present, else cadence.
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
    const COLOR_TRACK        = 0x333333;   // empty (unfilled) part of a zone arc

    var config;
    var paceLogic;
    var hrLogic;
    var reserveLogic;
    var alertLogic;

    var currentPower     = 0;
    var hasPower         = false;
    var currentCadence   = 0;
    var hasCadence       = false;
    var hasVerticalRatio = false;   // implies a chest strap / RD pod is present
    var chestStatus      = 0;
    var phoneConnected   = false;

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
                refreshSensorStatus();
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
        hrLogic.rolling5MinHr = 150.0;      // +5 vs current → rising trend arrow
        hrLogic.driftActive   = false;

        reserveLogic.reservePercent = 78;

        currentPower     = 248;  hasPower   = true;
        currentCadence   = 178;  hasCadence = true;
        hasVerticalRatio = true;
        chestStatus      = 2;
        phoneConnected   = true;
    }

    function updatePerformanceMetrics(info as Activity.Info) as Void {
        hasPower = false;
        if (info.currentPower != null && info.currentPower > 0) { currentPower = info.currentPower as Number; hasPower = true; }
        hasCadence = false;
        if (info.currentCadence != null && info.currentCadence > 0) { currentCadence = info.currentCadence as Number; hasCadence = true; }
        hasVerticalRatio = false;
        if (info has :verticalRatio) {
            var vr = info.verticalRatio;
            if (vr != null && vr > 0.0) { hasVerticalRatio = true; }
        }
    }

    function refreshSensorStatus() as Void {
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

        phoneConnected = false;
        var ds = System.getDeviceSettings();
        if (ds != null && ds has :phoneConnected && ds.phoneConnected != null) {
            phoneConnected = ds.phoneConnected;
        }
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

        // Top effort metric adapts to the hardware: running power when a meter
        // is present, else cadence (form).  The top number and the top zone arc
        // both track it, so the best available effort signal owns the crown.
        var topText;
        var topColor;
        var topZones = config.powerZones as Array<Number>;
        var topValue = 0;
        if (hasPower) {
            topValue = currentPower;
            topText  = formatPower(currentPower, true);
            topColor = colorForPower(currentPower, true);
        } else if (hasCadence) {
            topValue = currentCadence;
            topZones = config.cadenceZones as Array<Number>;
            topText  = formatCadence(currentCadence, true);
            topColor = colorForCadence(currentCadence, true);
        } else {
            topText  = "--";
            topColor = COLOR_MUTED;
        }

        // ── zone arcs ─────────────────────────────────────────────────────
        var arcR = S(182, scale);
        var arcT = S(9,   scale);
        drawZoneArc(dc, cx, cy, arcR, arcT, 215.0, 325.0, topZones, topValue);
        drawZoneArc(dc, cx, cy, arcR, arcT, 145.0, 35.0,
                    config.hrZones    as Array<Number>, hrLogic.currentHr);
        drawOuterRing(dc, cx, cy, S(202, scale));

        // All graphics use Garmin built-in primitives only: drawArc for the
        // colour bars, fillRoundedRectangle for the hero tile and phone glyph,
        // fillCircle/fillPolygon for the heart glyph, drawText for values.

        // =====================================================================
        // Lean 10-field layout on the round face.  Every value lives inside the
        // ~r168 circle the two zone arcs (r182) leave free, so nothing ever
        // touches a colour bar.  Vertical spine of three anchors — Power (top),
        // current PACE (centre hero tile), current HR (bottom) — with the
        // secondary values as big plain text pushed toward the sides to fill
        // the face and cut the black space:
        //   R1  y= 66  Power (centre, big)                         [power arc]
        //   R2  y=132  Distanz "done/total" | Reserve %
        //   R3  y=200  Ø-Pace | CURRENT PACE (hero tile) | Delta
        //   R4  y=262  Elapsed | Finish
        //   R5  y=310/352  5-min HR (small) over Current HR (big)  [HR arc]
        // =====================================================================

        // ── R1  Top effort (power/cadence) + connection status ───────────
        lbl(dc, cx, S(66, scale), topText,
            pickEmphasisFont(dc, topText, S(150, scale)), topColor);

        drawPhoneIcon(dc, S(138, scale), S(64, scale), scale, phoneConnected);
        drawHeartIcon(dc, S(278, scale), S(64, scale), scale, chestStatus >= 1);

        // ── R2  Distanz (done/total) | Reserve % ─────────────────────────
        var distTxt = formatDistance(paceLogic.distanceKm) + "/" +
                      config.raceDistanceKm.toNumber().format("%d");
        lbl(dc, S(122, scale), S(132, scale), distTxt,
            Graphics.FONT_MEDIUM, COLOR_WHITE);
        lbl(dc, S(294, scale), S(132, scale),
            formatReserve(reserveLogic.reservePercent), Graphics.FONT_MEDIUM,
            colorForReserve(reserveLogic.reservePercent));

        // ── R3  Ø-Pace | CURRENT PACE (hero tile) | Delta ────────────────
        // Pace module: whole-race average (left) · current pace (hero) ·
        // instant delta to target (right).
        var p1cy = S(200, scale);
        var p1w  = S(146, scale);
        var p1h  = S(66,  scale);
        drawPanel(dc, cx, p1cy, p1w, p1h, S(12, scale), COLOR_PANEL_CENTER);

        lbl(dc, S(84, scale), p1cy,
            formatPace(paceLogic.averagePaceSec), Graphics.FONT_MEDIUM,
            colorForMeasuredPace(paceLogic.averagePaceSec));

        lbl(dc, S(332, scale), p1cy,
            formatSignedPaceDelta(paceLogic.deltaToTargetSec()), Graphics.FONT_MEDIUM,
            colorForDelta(paceLogic.deltaToTargetSec()));

        drawPacePanel(dc, cx, p1cy, p1w, p1h, scale);

        // ── R4  Elapsed | Finish ─────────────────────────────────────────
        var elapsed = formatTimeHms(paceLogic.elapsedSec);
        var finish  = formatTimeHms(paceLogic.projectedFinishSec);
        lbl(dc, S(112, scale), S(262, scale), elapsed,
            Graphics.FONT_MEDIUM, COLOR_WHITE);
        lbl(dc, S(304, scale), S(262, scale), finish,
            Graphics.FONT_MEDIUM, colorForProjectedFinish());

        // ── R5  HR module: current HR (big) + drift trend arrow above ────
        // The small line reads currentHr against its 5-min average: a native
        // triangle (no font glyph) + the bpm delta.  Rising = you are drifting
        // up / possibly over-pacing (orange, red once real HR-vs-pace
        // decoupling is detected), flat = calm, falling = recovering.
        drawHrTrend(dc, cx, S(312, scale), scale);

        var hrTxt = formatHeartRateNumber(hrLogic.currentHr);
        lbl(dc, cx, S(352, scale), hrTxt,
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
    // Connection-status glyphs, built from Garmin built-in primitives.
    // Bright (white) when connected, dimmed to muted grey when not.
    function drawPhoneIcon(dc as Dc, cx as Number, cy as Number,
                           scale as Float, connected as Boolean) as Void {
        dc.setColor(connected ? COLOR_WHITE : COLOR_MUTED, Graphics.COLOR_TRANSPARENT);
        var bw = S(12, scale);
        var bh = S(19, scale);
        dc.setPenWidth(S(2, scale));
        dc.drawRoundedRectangle(cx - bw / 2, cy - bh / 2, bw, bh, S(3, scale));
        dc.setPenWidth(1);
        // speaker slit (top) and home dot (bottom) make it read as a phone
        dc.fillRectangle(cx - S(3, scale), cy - bh / 2 + S(3, scale), S(6, scale), S(2, scale));
        dc.fillCircle(cx, cy + bh / 2 - S(4, scale), S(1, scale));
    }

    function drawHeartIcon(dc as Dc, cx as Number, cy as Number,
                           scale as Float, connected as Boolean) as Void {
        dc.setColor(connected ? COLOR_WHITE : COLOR_MUTED, Graphics.COLOR_TRANSPARENT);
        var lobeR  = S(5, scale);
        var lobeDx = S(4, scale);
        var lobeDy = S(3, scale);
        dc.fillCircle(cx - lobeDx, cy - lobeDy, lobeR);
        dc.fillCircle(cx + lobeDx, cy - lobeDy, lobeR);
        dc.fillPolygon([
            [cx - S(9, scale), cy - lobeDy],
            [cx + S(9, scale), cy - lobeDy],
            [cx, cy + S(10, scale)]
        ]);
    }

    // HR drift trend: current HR relative to its own 5-min average, drawn as a
    // native triangle (up / down) or a dash (flat) plus the bpm delta — no font
    // glyph, so it can never render as garbage.  Colour escalates from calm
    // (flat) to orange (rising) to red once RaceHeartRateLogic detects real
    // HR-vs-pace decoupling, i.e. genuine over-pacing.
    function drawHrTrend(dc as Dc, cx as Number, cy as Number,
                         scale as Float) as Void {
        var cur  = hrLogic.currentHr;
        var base = hrLogic.rolling5MinHr;
        if (cur <= 0 || base <= 0.0) { return; }   // not enough data yet

        var d   = roundNumber(cur.toFloat() - base);
        var dir = 0;                               // -1 falling, 0 flat, +1 rising
        if (d >=  3) { dir =  1; }
        if (d <= -3) { dir = -1; }

        var color = COLOR_MUTED;                   // flat = calm
        if (dir > 0) { color = hrLogic.driftActive ? COLOR_RED : COLOR_ORANGE; }
        if (dir < 0) { color = COLOR_GREEN; }

        var hw  = S(6, scale);                     // triangle half-width
        var hh  = S(9, scale);                     // triangle height
        var gap = S(6, scale);

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        if (dir == 0) {
            // Flat: a short centred dash, no number.
            dc.fillRectangle(cx - hw, cy - S(1, scale), 2 * hw, S(3, scale));
            return;
        }

        var numTxt = (d < 0 ? -d : d).format("%d");
        var numW   = textWidth(dc, numTxt, Graphics.FONT_SMALL);
        var total  = (2 * hw) + gap + numW;
        var left   = cx - (total / 2);
        var gx     = left + hw;                    // triangle centre x

        if (dir > 0) {
            dc.fillPolygon([
                [gx,      cy - (hh / 2)],
                [gx - hw, cy + (hh / 2)],
                [gx + hw, cy + (hh / 2)]
            ]);
        } else {
            dc.fillPolygon([
                [gx,      cy + (hh / 2)],
                [gx - hw, cy - (hh / 2)],
                [gx + hw, cy - (hh / 2)]
            ]);
        }
        dc.drawText(left + (2 * hw) + gap, cy, Graphics.FONT_SMALL, numTxt,
                    Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
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

    // Cadence (used for the top slot when no power meter is present) is tinted
    // by its own zone thresholds, same scale as power/HR.
    function colorForCadence(value as Number, available as Boolean) as Number {
        if (!available || value <= 0) { return COLOR_MUTED; }
        return colorForZoneIndex(
            zoneIndexForValue(value, config.cadenceZones as Array<Number>));
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
    function formatCadence(value as Number, available as Boolean) as String {
        return (!available || value <= 0) ? "--" : value.format("%d");
    }
    function formatReserve(value as Number) as String   { return value.format("%d") + "%"; }
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
