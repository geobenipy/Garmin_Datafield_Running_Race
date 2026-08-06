import Toybox.Lang;
import Toybox.UserProfile;

// ---------------------------------------------------------------------------
// RaceConfig  –  load and cache all user-configurable settings
// ---------------------------------------------------------------------------
// FIX: UserProfile.getHeartRateZones() requires UserProfile.SportHrZone enum,
//      NOT Activity.Sport.  The correct constant is HR_ZONE_SPORT_RUNNING.
//
// The three race targets (pace, distance, tolerance) go through RaceSetup, the
// module the on-watch settings menu also writes through, and are re-read on
// every heavy refresh — see pollTargets().  Everything else here is loaded once.
// ---------------------------------------------------------------------------

class RaceConfig {

    const HEAVY_UPDATE_SEC      = 10;
    const SAMPLE_WINDOW_SEC     = 600;
    const ROLLING_WINDOW_SEC    = 300;
    const SMOOTH_WINDOW_SEC     = 12;
    const LAP_SNAP_METERS       = 150.0;
    const DRIFT_PACE_STABLE_SEC = 5.0;
    const DRIFT_HR_DELTA_BPM    = 5;
    const BANNER_SHORT_SEC      = 12;
    const BANNER_LONG_SEC       = 25;

    // Bounds for HR zone thresholds read from app properties.  sanitizeThresholds
    // only enforces that they increase, not that they are plausible bpm — a junk
    // value would otherwise set the whole HR arc's scale.
    const MIN_HR_BPM = 40;
    const MAX_HR_BPM = 240;

    var targetPaceSec       = 300.0;
    var targetTimeSec       = 12659;   // derived: targetPaceSec x raceDistanceKm
    var paceToleranceSec    = 10.0;
    var raceDistanceKm      = 42.195;

    // The three race targets as last read from storage, so pollTargets() can
    // tell a real change from a re-read.  Two things depend on that: the heavy
    // tier can poll every 10 s without re-running the expensive UserProfile
    // lookup, and pinning a value on a config instance (RaceSim, the layout
    // preview) survives a poll instead of being silently reverted.
    var lastPaceSetting     = -1;
    var lastDistSetting     = -1;
    var lastToleranceSetting = -1;

    var heavyUpdateSec      = 10;
    var sampleWindowSec     = 600;
    var rollingWindowSec    = 300;
    var smoothWindowSec     = 12;
    var lapSnapMeters       = 150.0;
    var driftPaceStableSec  = 5.0;
    var driftHrDeltaBpm     = 5;
    var bannerShortSec      = 12;
    var bannerLongSec       = 25;

    var nutritionStartDelaySec = 900;
    var nutritionAlerts = [8000, 18000, 30000, 38000] as Array<Number>;

    var hrZones            = [114, 133, 152, 171, 190] as Array<Number>;

    function initialize() {
        load();
    }

    function load() as Void {
        // -1 can never match a clamped setting, so this forces pollTargets to
        // apply rather than to short-circuit on the values already held.
        lastPaceSetting      = -1;
        lastDistSetting      = -1;
        lastToleranceSetting = -1;
        pollTargets();

        nutritionStartDelaySec = clampInt(readInt("nutritionStartDelaySec", 900), 0, 7200);

        nutritionAlerts = [
            normalizeFuel(readInt("nutritionAlarm1", 8000)),
            normalizeFuel(readInt("nutritionAlarm2", 18000)),
            normalizeFuel(readInt("nutritionAlarm3", 30000)),
            normalizeFuel(readInt("nutritionAlarm4", 38000))
        ] as Array<Number>;

        loadHrZones();
    }

    // -----------------------------------------------------------------------
    // The three race targets.  Cheap on purpose — three property reads, no
    // UserProfile call — because RaceEngine calls it on every heavy refresh so
    // that a target changed on the wrist mid-race takes effect within 10 s.
    // Returns true only when a stored value actually moved.
    //
    // targetTimeSec is derived here rather than stored: pace and distance are
    // both editable from the watch now, and a separately stored goal time would
    // start contradicting them the first time either one changed.
    // -----------------------------------------------------------------------
    function pollTargets() as Boolean {
        var pace      = RaceSetup.paceSec();
        var meters    = RaceSetup.distanceM();
        var tolerance = RaceSetup.toleranceSec();

        if (pace   == lastPaceSetting &&
            meters == lastDistSetting &&
            tolerance == lastToleranceSetting) {
            return false;
        }

        lastPaceSetting      = pace;
        lastDistSetting      = meters;
        lastToleranceSetting = tolerance;

        targetPaceSec    = pace.toFloat();
        raceDistanceKm   = meters.toFloat() / 1000.0;
        paceToleranceSec = tolerance.toFloat();
        targetTimeSec    = RaceSetup.timeSecFor(pace, meters);
        return true;
    }

    // -----------------------------------------------------------------------
    // HR zones  –  prefer device UserProfile, fall back to app settings
    // FIX: use UserProfile.HR_ZONE_SPORT_RUNNING (SportHrZone enum),
    //      NOT Activity.SPORT_RUNNING (Sport enum).
    // -----------------------------------------------------------------------
    function loadHrZones() as Void {
        var loaded = false;

        try {
            // Correct parameter type: UserProfile.SportHrZone
            var zones = UserProfile.getHeartRateZones(
                UserProfile.HR_ZONE_SPORT_RUNNING) as Array or Null;

            if (zones != null && zones.size() >= 5) {
                var z = new Array<Number>[5];
                for (var i = 0; i < 5; i += 1) {
                    // HeartRateZone objects expose .highBpm
                    var zone = zones[i];
                    if (zone != null && (zone has :highBpm) && zone.highBpm != null) {
                        z[i] = zone.highBpm as Number;
                    } else {
                        z[i] = (hrZones as Array<Number>)[i];
                    }
                }
                hrZones = z;
                sanitizeThresholds(hrZones);
                loaded = true;
            }
        } catch (e) {
            // UserProfile not available on this device – use manual settings
        }

        if (!loaded) {
            hrZones = [
                clampInt(readInt("hrZone1", 114), MIN_HR_BPM, MAX_HR_BPM),
                clampInt(readInt("hrZone2", 133), MIN_HR_BPM, MAX_HR_BPM),
                clampInt(readInt("hrZone3", 152), MIN_HR_BPM, MAX_HR_BPM),
                clampInt(readInt("hrZone4", 171), MIN_HR_BPM, MAX_HR_BPM),
                clampInt(readInt("hrZone5", 190), MIN_HR_BPM, MAX_HR_BPM)
            ] as Array<Number>;
            sanitizeThresholds(hrZones);
        }
    }

    // Both delegate to RaceSetup, which is also what the on-watch settings menu
    // reads and writes through — one guarded property read and one clamp per
    // value, no matter which side of the app is asking.
    function readInt(key as String, fallback as Number) as Number {
        return RaceSetup.readNumber(key, fallback);
    }

    function clampInt(value as Number, low as Number, high as Number) as Number {
        return RaceSetup.clampInt(value, low, high);
    }

    function normalizeFuel(raw as Number) as Number {
        if (raw > 0 && raw < 1000) { return raw * 1000; }
        return raw;
    }

    function sanitizeThresholds(values as Array<Number>) as Void {
        for (var i = 1; i < values.size(); i += 1) {
            if ((values as Array<Number>)[i] <= (values as Array<Number>)[i - 1]) {
                (values as Array<Number>)[i] = (values as Array<Number>)[i - 1] + 1;
            }
        }
    }
}
