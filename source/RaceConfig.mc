import Toybox.Activity;
import Toybox.Application;
import Toybox.Lang;
import Toybox.UserProfile;

class RaceConfig {

    const RACE_DISTANCE_KM = 42.195;
    const HEAVY_UPDATE_SEC = 10;
    const SAMPLE_WINDOW_SEC = 600;
    const ROLLING_WINDOW_SEC = 300;
    const SMOOTH_WINDOW_SEC = 12;
    const LAP_SNAP_METERS = 150.0;
    const DRIFT_PACE_STABLE_SEC = 5.0;
    const DRIFT_HR_DELTA_BPM = 5;
    const BANNER_SHORT_SEC = 12;
    const BANNER_LONG_SEC = 25;

    var targetPaceSec = 300.0;
    var targetTimeSec = 12600;
    var paceToleranceSec = 10.0;
    var raceDistanceKm = 42.195;
    var heavyUpdateSec = 10;
    var sampleWindowSec = 600;
    var rollingWindowSec = 300;
    var smoothWindowSec = 12;
    var lapSnapMeters = 150.0;
    var driftPaceStableSec = 5.0;
    var driftHrDeltaBpm = 5;
    var bannerShortSec = 12;
    var bannerLongSec = 25;
    var nutritionStartDelaySec = 900;
    var nutritionAlerts = [8000, 18000, 30000, 38000] as Array<Number>;
    var hrZones = [114, 133, 152, 171, 190] as Array<Number>;
    var powerZones = [220, 250, 280, 310, 340] as Array<Number>;
    var cadenceZones = [160, 168, 180, 188] as Array<Number>;
    var verticalRatioZones = [7.5, 8.5, 9.5] as Array<Float>;

    function initialize() {
        load();
    }

    function load() as Void {
        targetPaceSec = readSetting("targetPaceSecPerKm", 300).toFloat();
        targetTimeSec = readSetting("targetTime", ((targetPaceSec * raceDistanceKm) + 0.5).toNumber());
        paceToleranceSec = readSetting("paceToleranceSec", 10).toFloat();
        nutritionStartDelaySec = readSetting("nutritionStartDelaySec", 900);

        nutritionAlerts = [
            normalizeFuelSetting(readSetting("nutritionAlarm1", 8000)),
            normalizeFuelSetting(readSetting("nutritionAlarm2", 18000)),
            normalizeFuelSetting(readSetting("nutritionAlarm3", 30000)),
            normalizeFuelSetting(readSetting("nutritionAlarm4", 38000))
        ] as Array<Number>;

        hrZones = [
            readSetting("hrZone1", 114),
            readSetting("hrZone2", 133),
            readSetting("hrZone3", 152),
            readSetting("hrZone4", 171),
            readSetting("hrZone5", 190)
        ] as Array<Number>;
        sanitizeThresholds(hrZones);
        loadPowerZones();
    }

    function readSetting(key as String, fallback as Number) as Number {
        var value = Application.Properties.getValue(key) as Number or Null;
        if (value != null) {
            return value;
        }
        return fallback;
    }

    function normalizeFuelSetting(rawValue as Number) as Number {
        if (rawValue > 0 && rawValue < 1000) {
            return rawValue * 1000;
        }
        return rawValue;
    }

    function sanitizeThresholds(values as Array<Number>) as Void {
        for (var i = 1; i < values.size(); i += 1) {
            if (values[i] <= values[i - 1]) {
                values[i] = values[i - 1] + 1;
            }
        }
    }

    function loadPowerZones() as Void {
        try {
            var profileZones = UserProfile.getPowerZones(Activity.SPORT_RUNNING) as Array<Number> or Null;
            if (profileZones != null && profileZones.size() > 1) {
                powerZones = profileZones;
                sanitizeThresholds(powerZones);
            }
        } catch (e) {
        }
    }
}
