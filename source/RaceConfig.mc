import Toybox.Application;
import Toybox.Lang;
import Toybox.UserProfile;

// ---------------------------------------------------------------------------
// RaceConfig  –  load and cache all user-configurable settings
// ---------------------------------------------------------------------------
// FIX: UserProfile.getHeartRateZones() requires UserProfile.SportHrZone enum,
//      NOT Activity.Sport.  The correct constant is HR_ZONE_SPORT_RUNNING.
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
    var targetTimeSec       = 12600;
    var paceToleranceSec    = 10.0;
    var raceDistanceKm      = 42.195;

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
        // Clamped, because a corrupt or out-of-range setting must not be able to
        // poison every pace comparison and projection for the whole race.
        targetPaceSec    = clampInt(readInt("targetPaceSecPerKm", 300), 120, 900).toFloat();
        paceToleranceSec = clampInt(readInt("paceToleranceSec",   10),    1, 120).toFloat();
        nutritionStartDelaySec = clampInt(readInt("nutritionStartDelaySec", 900), 0, 7200);

        // 0 = 10 km, 1 = Half marathon, 2 = Marathon
        var distCode = readInt("targetDistanceCode", 2);
        if (distCode == 0) {
            raceDistanceKm = 10.0;
        } else if (distCode == 1) {
            raceDistanceKm = 21.0975;
        } else {
            raceDistanceKm = 42.195;
        }

        var defaultTime = roundNumber(targetPaceSec * raceDistanceKm);
        targetTimeSec   = clampInt(readInt("targetTime", defaultTime), 600, 86400);

        nutritionAlerts = [
            normalizeFuel(readInt("nutritionAlarm1", 8000)),
            normalizeFuel(readInt("nutritionAlarm2", 18000)),
            normalizeFuel(readInt("nutritionAlarm3", 30000)),
            normalizeFuel(readInt("nutritionAlarm4", 38000))
        ] as Array<Number>;

        loadHrZones();
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

    // A settings sync can leave a key missing or holding a non-Number, and
    // getValue() itself throws on some firmware for an unknown key.  Either
    // must fall back to the default rather than take the field down.
    function readInt(key as String, fallback as Number) as Number {
        try {
            var value = Application.Properties.getValue(key);
            if (value instanceof Lang.Number) { return value; }
            if (value instanceof Lang.Float)  { return value.toNumber(); }
        } catch (e) {
            // fall through to the default
        }
        return fallback;
    }

    function clampInt(value as Number, low as Number, high as Number) as Number {
        if (value < low)  { return low;  }
        if (value > high) { return high; }
        return value;
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

    function roundNumber(value as Float) as Number {
        if (value < 0.0) { return (value - 0.5).toNumber(); }
        return (value + 0.5).toNumber();
    }
}
