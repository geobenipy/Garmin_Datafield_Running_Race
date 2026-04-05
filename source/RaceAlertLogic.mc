import Toybox.Attention;
import Toybox.Lang;

// ---------------------------------------------------------------------------
// RaceAlertLogic  –  nutrition alerts, 5 km feedback, banner system
// ---------------------------------------------------------------------------
// FIX: Explicit `as Boolean` / `as Number` casts on array element access to
//      eliminate "Cannot determine if container access is using container type".
// ---------------------------------------------------------------------------

class RaceAlertLogic {

    var config;
    var alertDone      = [false, false, false, false] as Array<Boolean>;
    var nextFeedbackKm = 5.0;
    var bannerText     = "";
    var bannerColor    = 0xFFFFFF;
    var bannerUntilSec = 0;

    function initialize(configRef) {
        config = configRef;
    }

    // -----------------------------------------------------------------------
    // Nutrition alerts
    // -----------------------------------------------------------------------
    function checkNutrition(paceLogic as RacePaceLogic) as Void {
        if (paceLogic.elapsedSec < config.nutritionStartDelaySec) { return; }

        // Local typed aliases suppress the container-type warnings
        var alerts = config.nutritionAlerts as Array<Number>;
        var done   = alertDone as Array<Boolean>;

        for (var i = 0; i < alerts.size(); i += 1) {
            if (done[i] as Boolean) { continue; }

            var alertValue = alerts[i] as Number;
            if (alertValue == 0)    { continue; }

            if (isAlertTriggered(alertValue, paceLogic)) {
                (alertDone as Array<Boolean>)[i] = true;
                showBanner("FUEL " + describeAlert(alertValue),
                           0xF2A640,
                           paceLogic.elapsedSec + config.bannerShortSec);
                vibrate();
            }
        }
    }

    // -----------------------------------------------------------------------
    // 5 km performance feedback
    // -----------------------------------------------------------------------
    function checkFiveKmFeedback(paceLogic      as RacePaceLogic,
                                  hrLogic        as RaceHeartRateLogic,
                                  reservePercent) as Void {
        if (paceLogic.distanceKm < nextFeedbackKm) { return; }

        var message = buildFeedbackMessage(paceLogic, hrLogic, reservePercent);
        showBanner(message, feedbackColor(message),
                   paceLogic.elapsedSec + config.bannerLongSec);
        nextFeedbackKm += 5.0;
    }

    function buildFeedbackMessage(paceLogic      as RacePaceLogic,
                                   hrLogic        as RaceHeartRateLogic,
                                   reservePercent) as String {
        if (hrLogic.driftActive) { return "HR drift increasing"; }

        var paceDelta = paceLogic.rolling5MinPaceSec > 0.0
                      ? paceLogic.rolling5MinPaceSec - config.targetPaceSec
                      : 0.0;

        if (paceLogic.rolling5MinPaceSec > 0.0 &&
            absoluteFloat(paceDelta) <= 5.0) {
            return "On pace";
        }

        if (paceDelta < -5.0) { return "Slightly fast but stable"; }

        if (paceDelta > 8.0 &&
            (reservePercent == null || reservePercent >= 55) &&
            hrLogic.zoneIndex() <= 3) {
            return "You can push";
        }

        return "On pace";
    }

    function feedbackColor(message as String) as Number {
        if (message.equals("HR drift increasing"))      { return 0xF2A640; }
        if (message.equals("You can push"))             { return 0x4DCB77; }
        if (message.equals("Slightly fast but stable")) { return 0x61BDEB; }
        return 0x4DCB77;
    }

    function isAlertTriggered(alertValue as Number,
                               paceLogic  as RacePaceLogic) as Boolean {
        if (alertValue > 0) {
            return (paceLogic.distanceKm * 1000.0) >= alertValue.toFloat();
        }
        return paceLogic.elapsedSec >= -alertValue;
    }

    function describeAlert(alertValue as Number) as String {
        if (alertValue > 0) {
            return (alertValue.toFloat() / 1000.0).format("%.1f") + " km";
        }
        return ((-alertValue) / 60).format("%d") + " min";
    }

    // -----------------------------------------------------------------------
    // Banner system
    // -----------------------------------------------------------------------
    function showBanner(text     as String,
                        color    as Number,
                        untilSec as Number) as Void {
        bannerText     = text;
        bannerColor    = color;
        bannerUntilSec = untilSec;
    }

    function hasActiveBanner(currentSec as Number) as Boolean {
        return !bannerText.equals("") && currentSec <= bannerUntilSec;
    }

    function clearExpiredBanner(currentSec as Number) as Void {
        if (currentSec > bannerUntilSec) { bannerText = ""; }
    }

    function vibrate() as Void {
        try {
            Attention.vibrate([
                new Attention.VibeProfile(80,  160),
                new Attention.VibeProfile(0,   80),
                new Attention.VibeProfile(100, 240)
            ] as Array<Attention.VibeProfile>);
        } catch (e) {}
    }

    function absoluteFloat(value as Float) as Float {
        return value < 0.0 ? -value : value;
    }
}
