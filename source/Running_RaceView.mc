import Toybox.Activity;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.WatchUi;

// =============================================================================
// Running_RaceView  –  Garmin Fenix 8 43mm  (416 × 416 px design canvas)
// =============================================================================
// Pace-first round-face layout (design-px, scaled at runtime).  Every value
// sits inside the ~r168 circle the HR zone arc (r182) leaves free, so nothing
// ever touches the colour bar.
//   R1  y= 56  phone + HR-strap glyphs        [race progress arc above them]
//   R2  y=126  Distance done/remaining (left) | Reserve % (right)
//   R3  y=208  HERO tile: current pace, huge · Ø-pace + lap pace underneath
//   R4  y=297  Elapsed (left)              |  Projected finish (right)
//   R5  y=352  current HR (big) + drift trend arrow beside it        [HR arc]
//
// R2 + R3 are deliberately one tight cluster (distance, stamina, current pace,
// lap and average pace): they are what you read as a group mid-race.  R4 and
// R5 sit further out because they answer different questions.
//
// Three rules keep this readable on a 43 mm round face:
//   · The four secondary values all share one small font.  They are context;
//     the hero pace and the HR are the only things meant to be read at speed.
//   · Nothing wider than ~140 px sits above y=110 or below y=310 — that is all
//     the room the circle leaves there once the hero tile has taken the middle.
//     The projected finish is h:mm for the same reason (and because a
//     projection that re-jitters every 10 s has no business showing seconds).
//   · The two arcs are obstacles, not just decoration: both sets of end caps
//     lie at y=104 (top) and y=312 (bottom), out at x=59 and x=357.  Text rows
//     have to clear those, which is what fixes R2 at 126 and R4 at 297.
//
// The hero pace carries the whole target comparison by colour:
//   green = within tolerance · orange = too fast · red = too slow.
// The HR arc is zoomed to HR_ARC_MIN_BPM..zone5, because nothing below that is
// ever seen while racing and the full 0..max scale wasted most of the bar.
//
// The view only draws.  RaceEngine owns the update path — see RaceEngine.mc.
// =============================================================================

class Running_RaceView extends WatchUi.DataField {

    const DESIGN_SIZE = 416.0;
    const PI          = 3.14159265;

    // The HR arc starts here instead of at 0 bpm: a racing heart rate never
    // goes below it, so the whole bar is spent on the range that matters.
    const HR_ARC_MIN_BPM = 100.0;

    // The room R2 really has, in design px.  Measured at the *top* of the
    // glyphs, not at their baseline: at y=126 the content circle allows x=61
    // on the centre line but only x=64 fourteen pixels higher, and it is the
    // corner of the text box that hits the arc first.
    const R2_LEFT    = 66;
    const R2_RIGHT   = 350;
    const R2_MIN_GAP = 14;

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

    var engine;

    // Aliases onto the engine's logic objects so the drawing code below reads
    // exactly as it did when the view owned them.
    var config;
    var paceLogic;
    var hrLogic;
    var reserveLogic;
    var alertLogic;

    function initialize() {
        DataField.initialize();
        engine       = new RaceEngine();
        config       = engine.config;
        paceLogic    = engine.paceLogic;
        hrLogic      = engine.hrLogic;
        reserveLogic = engine.reserveLogic;
        alertLogic   = engine.alertLogic;
    }

    // compute() runs several times per second on a tight time budget.  All of
    // the work — including its try/catch guard — lives in RaceEngine.
    function compute(info as Activity.Info) as Void {
        if (PREVIEW_MODE) { applyPreview(); return; }
        engine.onCompute(info);
    }

    function onTimerLap() as Void {
        engine.onTimerLap();
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
        // 0.2 km into the 14th km, 58 s ago -> L reads 4:50
        paceLogic.lapAnchorDistanceKm = 13.0;
        paceLogic.lapAnchorElapsedSec = 3842.0;

        hrLogic.currentHr     = 155;
        hrLogic.rolling5MinHr = 150.0;      // +5 vs current → rising trend arrow
        hrLogic.driftActive   = false;

        reserveLogic.reservePercent = 78;

        engine.chestStatus    = 2;
        engine.phoneConnected = true;
    }

    // =========================================================================
    // onUpdate  – draw the pace-first layout
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

        // ── Arcs (race progress on top, HR zones at the bottom) + ring ────
        // All graphics use Garmin built-in primitives only: drawArc for the
        // colour bars, fillRoundedRectangle for the hero tile and phone glyph,
        // fillCircle/fillPolygon for the heart glyph, drawText for values.
        drawProgressArc(dc, cx, cy, S(182, scale), S(9, scale), 215.0, 325.0,
                        paceLogic.raceProgress());
        drawZoneArc(dc, cx, cy, S(182, scale), S(9, scale), 145.0, 35.0,
                    config.hrZones as Array<Number>, hrLogic.currentHr,
                    HR_ARC_MIN_BPM);
        drawOuterRing(dc, cx, cy, S(202, scale));

        // ── R1  connection status ────────────────────────────────────────
        drawPhoneIcon(dc, S(182, scale), S(56, scale), scale, engine.phoneConnected);
        drawHeartIcon(dc, S(234, scale), S(56, scale), scale, engine.chestStatus >= 1);

        // ── R2  Distance (done/remaining) | Reserve % ─────────────────────
        drawDistanceRow(dc, S(126, scale), scale);

        // ── R3  HERO current pace ────────────────────────────────────────
        drawPacePanel(dc, cx, S(208, scale), S(280, scale), S(116, scale), scale);

        // ── R4  Elapsed | Finish ─────────────────────────────────────────
        lbl(dc, S(150, scale), S(297, scale), formatTimeHms(paceLogic.elapsedSec),
            Graphics.FONT_SMALL, COLOR_WHITE);
        lbl(dc, S(282, scale), S(297, scale),
            formatTimeHm(paceLogic.projectedFinishSec),
            Graphics.FONT_SMALL, colorForProjectedFinish());

        // ── R5  HR module: current HR (big) + drift trend arrow beside ───
        drawHrBlock(dc, cx, S(352, scale), scale);
        } catch (ex) {
            // A draw failure must never freeze the field; the background is
            // already cleared, so we simply skip the rest of this frame.
        }
    }

    // =========================================================================
    // R2: distance covered / distance left, and the reserve %
    // =========================================================================
    // done/remaining, not done/total: the total is already drawn as the progress
    // arc above this row, and past 30 km the only question worth a number is
    // how much is left.  A marathon reads 0.0/42.2 → 10.0/32.2 → 42.2/0.0.
    //
    // Both readouts are anchored to the ends of the chord the content circle
    // leaves free here rather than centred on fixed points, because both change
    // width during a race: the distance gains a digit at 10 km, the reserve
    // loses one as soon as it drops below 100 %.  Centred, the pair drifted into
    // each other; anchored, the outer edges stay put and the gap moves instead.
    // The font is a budget rather than a constant for the same reason — an ultra
    // distance ("100.0/100.0") does not fit beside a reserve at FONT_SMALL.
    function drawDistanceRow(dc as Dc, cy as Number, scale as Float) as Void {
        var distTxt = formatDistance(paceLogic.distanceKm) + "/" +
                      formatDistance(paceLogic.remainingKm);
        var resTxt  = formatReserve(reserveLogic.reservePercent);

        var left  = S(R2_LEFT,  scale);
        var right = S(R2_RIGHT, scale);
        var font  = Graphics.FONT_SMALL;
        if (textWidth(dc, distTxt, font) + textWidth(dc, resTxt, font) +
            S(R2_MIN_GAP, scale) > right - left) {
            font = Graphics.FONT_XTINY;
        }

        lbl(dc, left + (textWidth(dc, distTxt, font) / 2), cy, distTxt,
            font, COLOR_WHITE);
        lbl(dc, right - (textWidth(dc, resTxt, font) / 2), cy, resTxt,
            font, colorForReserve(reserveLogic.reservePercent));
    }

    // =========================================================================
    // The hero tile: current pace as large as the panel allows, with either the
    // whole-race average pace or an active banner on the line underneath.
    // =========================================================================
    function drawPacePanel(dc as Dc, cx as Number, cy as Number,
                           panelW as Number, panelH as Number,
                           scale as Float) as Void {

        drawPanel(dc, cx, cy, panelW, panelH, S(14, scale), COLOR_PANEL_CENTER);

        // heroH is a font-selection budget, not a drawing box, and it is larger
        // than the tile can visually hold on purpose: a Garmin number font's
        // line box is roughly twice its digit height (FONT_NUMBER_HOT measures
        // 112 px here but only inks ~52), and getTextDimensions can only report
        // the line box.  Sizing the tile to the line box left 37 px of dead air
        // above and below the digits.  The tile now wraps the *ink*, so if you
        // change heroH or the fonts, re-check with `.\run.ps1 -Preview`.
        var paceTxt = formatPace(paceLogic.smoothedPaceSec);
        var heroY   = cy - S(18, scale);
        var heroW   = panelW - S(24, scale);
        var heroH   = S(112, scale);
        lbl(dc, cx, heroY, paceTxt,
            pickHeroFont(dc, paceTxt, heroW, heroH),
            colorForPace(paceLogic.smoothedPaceSec));

        // Sub-line: Ø-pace for the whole race and L-pace for the kilometre you
        // are in — the two references the hero number is worth reading against.
        // A live banner or an active HR drift outranks both while it is up.
        var subY = cy + S(34, scale);
        if (alertLogic.hasActiveBanner(paceLogic.elapsedSec)) {
            lbl(dc, cx, subY, alertLogic.bannerText, Graphics.FONT_XTINY,
                alertLogic.bannerColor as Number);
        } else if (hrLogic.driftActive) {
            lbl(dc, cx, subY, "DRIFT +" + hrLogic.driftDeltaBpm.format("%d"),
                Graphics.FONT_XTINY, COLOR_ORANGE);
        } else {
            // Two labels rather than one string: each keeps its own colour, and
            // both slots stay put when one of them has no reading.
            var avgPace = paceLogic.averagePaceSec;
            var lapPace = paceLogic.lapPaceSec();
            lbl(dc, cx - S(46, scale), subY, "Ø " + formatPace(avgPace),
                Graphics.FONT_XTINY, colorForMeasuredPace(avgPace));
            lbl(dc, cx + S(46, scale), subY, "L " + formatPace(lapPace),
                Graphics.FONT_XTINY, colorForMeasuredPace(lapPace));
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

    // Current HR (big) with the drift trend on the same baseline beside it.
    // Side by side rather than stacked: this row sits low on the round face
    // where the circle has already closed in, so a second line underneath it
    // would either collide with the HR arc or have to shrink to nothing.
    // The pair is measured and then centred as one group.
    function drawHrBlock(dc as Dc, cx as Number, cy as Number,
                         scale as Float) as Void {
        var hrTxt = formatHeartRateNumber(hrLogic.currentHr);
        var font  = pickEmphasisFont(dc, hrTxt, S(110, scale));
        var numW  = textWidth(dc, hrTxt, font);

        var trendW = hrTrendWidth(dc, scale);
        var gap    = trendW > 0 ? S(12, scale) : 0;
        var left   = cx - ((numW + gap + trendW) / 2);

        lbl(dc, left + (numW / 2), cy, hrTxt, font,
            colorForHrValue(hrLogic.currentHr.toFloat()));
        if (trendW > 0) {
            drawHrTrend(dc, left + numW + gap + (trendW / 2), cy, trendW, scale);
        }
    }

    // HR drift trend: current HR relative to its own 5-min average, drawn as a
    // native triangle (up / down) or a dash (flat) plus the bpm delta — no font
    // glyph, so it can never render as garbage.  Colour escalates from calm
    // (flat) to orange (rising) to red once RaceHeartRateLogic detects real
    // HR-vs-pace decoupling, i.e. genuine over-pacing.
    function hasHrTrend() as Boolean {
        return hrLogic.currentHr > 0 && hrLogic.rolling5MinHr > 0.0;
    }

    function hrTrendDeltaBpm() as Number {
        return roundNumber(hrLogic.currentHr.toFloat() - hrLogic.rolling5MinHr);
    }

    // -1 falling · 0 flat · +1 rising
    function hrTrendDirection() as Number {
        var d = hrTrendDeltaBpm();
        if (d >=  3) { return  1; }
        if (d <= -3) { return -1; }
        return 0;
    }

    // 0 means "nothing to draw", which also switches off the gap in drawHrBlock.
    function hrTrendWidth(dc as Dc, scale as Float) as Number {
        if (!hasHrTrend()) { return 0; }
        var hw = S(6, scale);
        if (hrTrendDirection() == 0) { return 2 * hw; }
        var d = hrTrendDeltaBpm();
        return (2 * hw) + S(5, scale) +
               textWidth(dc, (d < 0 ? -d : d).format("%d"), Graphics.FONT_TINY);
    }

    function drawHrTrend(dc as Dc, cx as Number, cy as Number,
                         totalW as Number, scale as Float) as Void {
        var dir   = hrTrendDirection();
        var color = COLOR_MUTED;                   // flat = calm
        if (dir > 0) { color = hrLogic.driftActive ? COLOR_RED : COLOR_ORANGE; }
        if (dir < 0) { color = COLOR_GREEN; }

        var hw = S(6, scale);                      // triangle half-width
        var hh = S(9, scale);                      // triangle height

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        if (dir == 0) {
            // Flat: a short centred dash, no number.
            dc.fillRectangle(cx - hw, cy - S(1, scale), 2 * hw, S(3, scale));
            return;
        }

        var left = cx - (totalW / 2);
        var gx   = left + hw;                      // triangle centre x
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

        var d = hrTrendDeltaBpm();
        dc.drawText(left + (2 * hw) + S(5, scale), cy, Graphics.FONT_TINY,
                    (d < 0 ? -d : d).format("%d"),
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

    // Race progress, filling left to right across the top of the face.  This
    // is the counterweight to the HR arc at the bottom, and it is a bar rather
    // than another number on purpose: "how far through the race am I" is a
    // gestalt question, the exact kilometre is already on R2.  Blue keeps it
    // out of the green/orange/red status axis the pace owns.
    function drawProgressArc(dc as Dc, cx as Number, cy as Number,
                             r as Number, thickness as Number,
                             startDeg as Float, endDeg as Float,
                             progress as Float) as Void {
        drawNativeArc(dc, cx, cy, r, thickness, startDeg, endDeg, 0.0, COLOR_TRACK);
        if (progress <= 0.0) { return; }
        if (progress > 1.0)  { progress = 1.0; }
        drawNativeArc(dc, cx, cy, r, thickness, startDeg,
                      startDeg + (progress * (endDeg - startDeg)), 0.0, COLOR_BLUE);
        dc.setPenWidth(1);
    }

    // Zone bar over [minVal .. last threshold] rather than [0 .. last]: zooming
    // the scale to the range actually used while racing makes a 10 bpm move
    // visible instead of a hair's width.  Zones entirely below minVal are
    // folded into the first visible segment.
    function drawZoneArc(dc as Dc, cx as Number, cy as Number,
                         r as Number, thickness as Number,
                         startDeg as Float, endDeg as Float,
                         thresholds as Array<Number>,
                         currentValue as Number,
                         minVal as Float) as Void {
        if (thresholds == null || thresholds.size() <= 0) { return; }
        var maxVal = (thresholds[thresholds.size() - 1] as Number).toFloat();
        var span   = maxVal - minVal;
        if (span <= 0.0) { return; }

        drawNativeArc(dc, cx, cy, r, thickness, startDeg, endDeg, 0.0, COLOR_TRACK);
        var prev = minVal;
        for (var i = 0; i < thresholds.size(); i += 1) {
            var thr = (thresholds[i] as Number).toFloat();
            if (thr <= minVal) { continue; }     // zone sits below the zoom floor
            var sAng = startDeg + (((prev - minVal) / span) * (endDeg - startDeg));
            var eAng = startDeg + (((thr  - minVal) / span) * (endDeg - startDeg));
            drawNativeArc(dc, cx, cy, r, thickness, sAng, eAng, 2.6,
                          colorForZoneIndex(i + 1));
            prev = thr;
        }
        dc.setPenWidth(1);
        if (currentValue > 0) {
            var capped = currentValue.toFloat();
            if (capped < minVal) { capped = minVal; }
            if (capped > maxVal) { capped = maxVal; }
            var mDeg = startDeg + (((capped - minVal) / span) * (endDeg - startDeg));
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
    //
    // The hero pace is the whole point of the face, so this picks the largest
    // font that fits the tile in BOTH axes – height matters here, the number
    // fonts are tall enough to spill out of the panel on width alone.
    function pickHeroFont(dc as Dc, text as String,
                          maxW as Number, maxH as Number) {
        if (!text.equals("--:--")) {
            if (fits(dc, text, Graphics.FONT_NUMBER_THAI_HOT, maxW, maxH)) { return Graphics.FONT_NUMBER_THAI_HOT; }
            if (fits(dc, text, Graphics.FONT_NUMBER_HOT,      maxW, maxH)) { return Graphics.FONT_NUMBER_HOT;      }
            if (fits(dc, text, Graphics.FONT_NUMBER_MEDIUM,   maxW, maxH)) { return Graphics.FONT_NUMBER_MEDIUM;   }
            if (fits(dc, text, Graphics.FONT_NUMBER_MILD,     maxW, maxH)) { return Graphics.FONT_NUMBER_MILD;     }
        }
        if (fits(dc, text, Graphics.FONT_LARGE,  maxW, maxH)) { return Graphics.FONT_LARGE;  }
        if (fits(dc, text, Graphics.FONT_MEDIUM, maxW, maxH)) { return Graphics.FONT_MEDIUM; }
        return Graphics.FONT_SMALL;
    }

    function pickEmphasisFont(dc as Dc, text as String, maxW as Number) {
        if (textWidth(dc, text, Graphics.FONT_LARGE)  <= maxW) { return Graphics.FONT_LARGE;  }
        if (textWidth(dc, text, Graphics.FONT_MEDIUM) <= maxW) { return Graphics.FONT_MEDIUM; }
        return Graphics.FONT_SMALL;
    }

    function fits(dc as Dc, text as String, font,
                  maxW as Number, maxH as Number) as Boolean {
        var dims = dc.getTextDimensions(text, font);
        if (dims == null || dims.size() < 2) { return false; }
        return ((dims[0] as Number) <= maxW) && ((dims[1] as Number) <= maxH);
    }

    function textWidth(dc as Dc, text as String, font) as Number {
        var dims = dc.getTextDimensions(text, font);
        return (dims != null && dims.size() > 0) ? dims[0] as Number : 0;
    }

    // =========================================================================
    // Colour selectors
    // =========================================================================
    // Hero current pace — the only target comparison left on the face now that
    // the separate delta field is gone, so it carries all three states:
    //   green = inside tolerance · orange = too fast · red = too slow.
    function colorForPace(paceSeconds as Float) as Number {
        if (!(paceSeconds > 0.0) || paceSeconds > 1200.0) { return COLOR_MUTED; }
        var status = paceLogic.paceStatus(paceSeconds);
        if (status <  0) { return COLOR_ORANGE; }
        if (status >  0) { return COLOR_RED;    }
        return COLOR_GREEN;
    }

    // Neutral colour for a measured pace readout (the Ø line): white when we
    // have a value, muted when we don't.  Deviation colour is reserved for the
    // hero current pace so the eye has a single status axis.
    function colorForMeasuredPace(paceSeconds as Float) as Number {
        return (paceSeconds > 0.0 && paceSeconds <= 1200.0) ? COLOR_WHITE : COLOR_MUTED;
    }

    // Green when the projection is still inside the goal time.  The goal comes
    // from paceLogic, not from config, because it is target pace x the distance
    // actually being run — so on a loaded course it is the course's goal time.
    function colorForProjectedFinish() as Number {
        var target = paceLogic.effectiveTargetTimeSec();
        if (paceLogic.projectedFinishSec <= 0 || target <= 0) { return COLOR_WHITE; }
        return paceLogic.projectedFinishSec <= target ? COLOR_GREEN : COLOR_RED;
    }

    // Reserve is neutral until it runs low, then a single red warning.
    function colorForReserve(value as Number) as Number {
        return value < 40 ? COLOR_RED : COLOR_WHITE;
    }

    // HR numbers tinted by training zone (matches the HR arc segments):
    //   z1 muted · z2 blue · z3 green · z4 orange · z5 red.
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
        if (!(paceSeconds > 0.0) || paceSeconds > 1200.0) { return "--:--"; }
        var r = roundNumber(paceSeconds);
        return (r / 60).format("%d") + ":" + (r % 60).format("%02d");
    }

    function formatTimeHms(totalSeconds as Number) as String {
        if (totalSeconds < 0) { totalSeconds = 0; }
        var hh = totalSeconds / 3600;
        var mm = (totalSeconds % 3600) / 60;
        var ss = totalSeconds % 60;
        return hh.format("%d") + ":" + mm.format("%02d") + ":" + ss.format("%02d");
    }

    // h:mm, rounded to the nearest minute — used for the projected finish,
    // which is re-estimated every 10 s and has no meaningful second digit.
    function formatTimeHm(totalSeconds as Number) as String {
        if (totalSeconds < 0) { totalSeconds = 0; }
        var minutes = (totalSeconds + 30) / 60;
        return (minutes / 60).format("%d") + ":" + (minutes % 60).format("%02d");
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
