import Toybox.Application;
import Toybox.Lang;

// ---------------------------------------------------------------------------
// RaceSetup  –  the race target values, and the only place that reads or
//               writes them
// ---------------------------------------------------------------------------
// Target pace and race distance are editable from three places now: the phone
// (Connect IQ settings), the watch (RaceSettingsMenu, pushed by the system from
// the activity menu), and — for the distance — a loaded course, which overrides
// both while navigating.  A module rather than a class because the settings UI
// has no RaceConfig instance to ask; RaceConfig reads through here too, so
// there is exactly one clamp and one property key per value.
//
// Target time is NOT stored.  It is pace x distance, derived wherever it is
// needed, so a pace change on the wrist moves the goal time with it and the two
// can never disagree.  Editing the time on the watch simply back-computes the
// pace — same two numbers, seen from the other end.
// ---------------------------------------------------------------------------

module RaceSetup {

    // Bounds.  A corrupt or mistyped setting must never be able to poison every
    // pace comparison and projection for a whole race, so nothing gets past
    // these — not from the phone, not from the on-watch menu.
    const MIN_PACE_SEC = 120;      // 2:00 /km
    const MAX_PACE_SEC = 900;      // 15:00 /km
    const MIN_DIST_M   = 500;
    const MAX_DIST_M   = 200000;   // 200 km, past any road race
    const MIN_TOL_SEC  = 1;
    const MAX_TOL_SEC  = 120;
    const MIN_TIME_SEC = 60;
    const MAX_TIME_SEC = 86400;    // 24 h – also the finish formatter's ceiling

    // Step sizes for the on-watch adjuster.  The distance step is deliberately
    // small: the presets cover the jumps, this is for a course that measures
    // 42.4 km rather than for getting from a marathon to a 10 km.
    const PACE_STEP_SEC = 5;
    const DIST_STEP_M   = 100;
    const TIME_STEP_SEC = 60;
    const TOL_STEP_SEC  = 5;

    // Which value an adjuster view is editing.
    const FIELD_DISTANCE  = 0;
    const FIELD_PACE      = 1;
    const FIELD_TIME      = 2;
    const FIELD_TOLERANCE = 3;

    const KEY_PACE = "targetPaceSecPerKm";
    const KEY_DIST = "raceDistanceM";
    const KEY_TOL  = "paceToleranceSec";

    const DEFAULT_PACE_SEC = 300;
    const DEFAULT_DIST_M   = 42195;
    const DEFAULT_TOL_SEC  = 10;

    // Raised whenever a target changes — from the settings menu here, or from
    // AppBase.onSettingsChanged() when the phone syncs.  RaceEngine clears it at
    // its next heavy refresh and reloads, so a change lands within 10 s without
    // anything having to re-read properties on every tick.
    var dirty = false;

    // -----------------------------------------------------------------------
    // Stored values
    // -----------------------------------------------------------------------
    function paceSec() as Number {
        return clampPaceSec(readNumber(KEY_PACE, DEFAULT_PACE_SEC));
    }

    function distanceM() as Number {
        return clampDistanceM(readNumber(KEY_DIST, DEFAULT_DIST_M));
    }

    function toleranceSec() as Number {
        return clampToleranceSec(readNumber(KEY_TOL, DEFAULT_TOL_SEC));
    }

    function targetTimeSec() as Number {
        return timeSecFor(paceSec(), distanceM());
    }

    function setPaceSec(value as Number) as Void {
        writeNumber(KEY_PACE, clampPaceSec(value));
    }

    function setDistanceM(value as Number) as Void {
        writeNumber(KEY_DIST, clampDistanceM(value));
    }

    function setToleranceSec(value as Number) as Void {
        writeNumber(KEY_TOL, clampToleranceSec(value));
    }

    // -----------------------------------------------------------------------
    // Derivation.  Both directions of the same relationship, both guarded
    // against a zero distance reaching the divide.
    // -----------------------------------------------------------------------
    function timeSecFor(pace as Number, meters as Number) as Number {
        if (meters <= 0) { return MIN_TIME_SEC; }
        return clampTimeSec(roundNumber(pace.toFloat() * meters.toFloat() / 1000.0));
    }

    function paceSecFor(timeSec as Number, meters as Number) as Number {
        if (meters <= 0) { return DEFAULT_PACE_SEC; }
        return clampPaceSec(roundNumber(timeSec.toFloat() * 1000.0 / meters.toFloat()));
    }

    // -----------------------------------------------------------------------
    // The adjuster's view of a value: title, current setting, one step, save.
    // Keeping all four fields behind one small interface is what lets a single
    // RaceAdjustView edit any of them.
    // -----------------------------------------------------------------------
    function fieldTitle(field as Number) as String {
        if (field == FIELD_DISTANCE)  { return "Distanz";   }
        if (field == FIELD_PACE)      { return "Ziel-Pace"; }
        if (field == FIELD_TIME)      { return "Zielzeit";  }
        return "Toleranz";
    }

    function fieldUnit(field as Number) as String {
        if (field == FIELD_DISTANCE)  { return "km";     }
        if (field == FIELD_PACE)      { return "min/km"; }
        if (field == FIELD_TIME)      { return "h:mm:ss"; }
        return "s/km";
    }

    function fieldValue(field as Number) as Number {
        if (field == FIELD_DISTANCE)  { return distanceM();    }
        if (field == FIELD_PACE)      { return paceSec();      }
        if (field == FIELD_TIME)      { return targetTimeSec(); }
        return toleranceSec();
    }

    function fieldText(field as Number, value as Number) as String {
        if (field == FIELD_DISTANCE)  { return formatDistance(value); }
        if (field == FIELD_PACE)      { return formatPace(value);     }
        if (field == FIELD_TIME)      { return formatTime(value);     }
        return "+/- " + value.format("%d");
    }

    // direction is +1 or -1.  Returns the new, already clamped value, so the
    // caller can never hold an out-of-range number even for a frame.
    function fieldStep(field as Number, value as Number,
                       direction as Number) as Number {
        if (field == FIELD_DISTANCE) {
            return clampDistanceM(value + (direction * DIST_STEP_M));
        }
        if (field == FIELD_PACE) {
            return clampPaceSec(value + (direction * PACE_STEP_SEC));
        }
        if (field == FIELD_TIME) {
            // Step to the next or previous whole minute rather than by one.
            // The starting value is derived — 5:00 /km over 42.195 km is
            // 3:30:59, not 3:31:00 — and a plain +60 would carry those 59
            // seconds along for the rest of the edit.
            var minutes = value / TIME_STEP_SEC;                 // floor, value > 0
            if (direction > 0) {
                minutes += 1;
            } else if (value % TIME_STEP_SEC == 0) {
                minutes -= 1;
            }
            return clampTimeSec(minutes * TIME_STEP_SEC);
        }
        return clampToleranceSec(value + (direction * TOL_STEP_SEC));
    }

    function applyField(field as Number, value as Number) as Void {
        if (field == FIELD_DISTANCE) {
            setDistanceM(value);
        } else if (field == FIELD_PACE) {
            setPaceSec(value);
        } else if (field == FIELD_TIME) {
            // Time is derived, so there is nothing to store: turn it back into
            // the pace that produces it over the distance currently set.
            setPaceSec(paceSecFor(value, distanceM()));
        } else {
            setToleranceSec(value);
        }
    }

    // -----------------------------------------------------------------------
    // Formatters for the settings UI.  The data field has its own — these are
    // for whole settings values, not for live readouts.
    // -----------------------------------------------------------------------
    function formatPace(pace as Number) as String {
        return (pace / 60).format("%d") + ":" + (pace % 60).format("%02d");
    }

    function formatDistance(meters as Number) as String {
        if (meters % 1000 == 0) { return (meters / 1000).format("%d") + " km"; }
        return (meters.toFloat() / 1000.0).format("%.2f") + " km";
    }

    function formatTime(seconds as Number) as String {
        var hh = seconds / 3600;
        var mm = (seconds % 3600) / 60;
        var ss = seconds % 60;
        return hh.format("%d") + ":" + mm.format("%02d") + ":" + ss.format("%02d");
    }

    // -----------------------------------------------------------------------
    // Property access.  A settings sync can leave a key missing or holding a
    // non-Number, and getValue() itself throws on some firmware for an unknown
    // key — either must fall back to the default rather than take the field
    // down.  RaceConfig.readInt() delegates here so there is one such guard.
    // -----------------------------------------------------------------------
    function readNumber(key as String, fallback as Number) as Number {
        try {
            var value = Application.Properties.getValue(key);
            if (value instanceof Lang.Number) { return value; }
            if (value instanceof Lang.Float)  { return value.toNumber(); }
        } catch (e) {
            // fall through to the default
        }
        return fallback;
    }

    function writeNumber(key as String, value as Number) as Void {
        try {
            Application.Properties.setValue(key, value);
            dirty = true;
        } catch (e) {
            // A storage failure must not take the settings menu down; the old
            // value simply stays in force.
        }
    }

    // -----------------------------------------------------------------------
    // Clamps
    // -----------------------------------------------------------------------
    function clampPaceSec(value as Number) as Number {
        return clampInt(value, MIN_PACE_SEC, MAX_PACE_SEC);
    }

    function clampDistanceM(value as Number) as Number {
        return clampInt(value, MIN_DIST_M, MAX_DIST_M);
    }

    function clampToleranceSec(value as Number) as Number {
        return clampInt(value, MIN_TOL_SEC, MAX_TOL_SEC);
    }

    function clampTimeSec(value as Number) as Number {
        return clampInt(value, MIN_TIME_SEC, MAX_TIME_SEC);
    }

    function clampInt(value as Number, low as Number, high as Number) as Number {
        if (value < low)  { return low;  }
        if (value > high) { return high; }
        return value;
    }

    function roundNumber(value as Float) as Number {
        if (value < 0.0) { return (value - 0.5).toNumber(); }
        return (value + 0.5).toNumber();
    }
}
