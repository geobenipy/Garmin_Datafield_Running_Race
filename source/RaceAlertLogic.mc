import Toybox.Attention;
import Toybox.Lang;

class RaceAlertLogic {

    var config;
    var alertDone = [false, false, false, false] as Array<Boolean>;
    var nextFeedbackKm = 5.0;
    var bannerText = "";
    var bannerColor = 0xFFFFFF;
    var bannerUntilSec = 0;

    function initialize(configRef) {
        config = configRef;
    }

    function checkNutrition(paceLogic as RacePaceLogic) as Void {
        if (paceLogic.elapsedSec < config.nutritionStartDelaySec) {
            return;
        }

        for (var i = 0; i < config.nutritionAlerts.size(); i += 1) {
            if (alertDone[i]) {
                continue;
            }

            var alertValue = config.nutritionAlerts[i];
            if (alertValue == 0) {
                continue;
            }

            if (isAlertTriggered(alertValue, paceLogic)) {
                alertDone[i] = true;
                showBanner("FUEL " + describeAlert(alertValue), 0xF2A640, paceLogic.elapsedSec + config.bannerShortSec);
                vibrate();
            }
        }
    }

    function checkFiveKmFeedback(paceLogic as RacePaceLogic, hrLogic as RaceHeartRateLogic, reservePercent) as Void {
        if (paceLogic.distanceKm < nextFeedbackKm) {
            return;
        }

        var message = buildFeedbackMessage(paceLogic, hrLogic, reservePercent);
        var color = feedbackColor(message);
        showBanner(message, color, paceLogic.elapsedSec + config.bannerLongSec);
        nextFeedbackKm += 5.0;
    }

    function buildFeedbackMessage(paceLogic as RacePaceLogic, hrLogic as RaceHeartRateLogic, reservePercent) as String {
        var paceDelta = paceLogic.rolling5MinPaceSec > 0.0 ? paceLogic.rolling5MinPaceSec - config.targetPaceSec : 0.0;

        if (hrLogic.driftActive) {
            return "HR drift increasing";
        }

        if (paceLogic.rolling5MinPaceSec > 0.0 && absoluteFloat(paceDelta) <= 5.0) {
            return "On pace";
        }

        if (paceDelta < -5.0 && !hrLogic.driftActive) {
            return "Slightly fast but stable";
        }

        if (paceDelta > 8.0 && (reservePercent == null || reservePercent >= 55) && hrLogic.zoneIndex() <= 3) {
            return "You can push";
        }

        return "On pace";
    }

    function feedbackColor(message as String) as Number {
        if (message == "HR drift increasing") {
            return 0xF2A640;
        } else if (message == "You can push") {
            return 0x4DCB77;
        } else if (message == "Slightly fast but stable") {
            return 0x61BDEB;
        }
        return 0x4DCB77;
    }

    function isAlertTriggered(alertValue as Number, paceLogic as RacePaceLogic) as Boolean {
        if (alertValue > 0) {
            return (paceLogic.distanceKm * 1000.0) >= alertValue.toFloat();
        }
        return paceLogic.elapsedSec >= -alertValue;
    }

    function describeAlert(alertValue as Number) as String {
        if (alertValue > 0) {
            var km = alertValue.toFloat() / 1000.0;
            return formatDecimal(km, 1) + " km";
        }
        return ((-alertValue) / 60).format("%d") + " min";
    }

    function formatDecimal(value as Float, digits as Number) as String {
        if (digits == 0) {
            return value.format("%.0f");
        }
        return value.format("%.1f");
    }

    function showBanner(text as String, color as Number, untilSec as Number) as Void {
        bannerText = text;
        bannerColor = color;
        bannerUntilSec = untilSec;
    }

    function hasActiveBanner(currentSec as Number) as Boolean {
        return bannerText != "" && currentSec <= bannerUntilSec;
    }

    function clearExpiredBanner(currentSec as Number) as Void {
        if (currentSec > bannerUntilSec) {
            bannerText = "";
        }
    }

    function vibrate() as Void {
        try {
            var pattern = [
                new Attention.VibeProfile(80, 160),
                new Attention.VibeProfile(0, 80),
                new Attention.VibeProfile(100, 240)
            ];
            Attention.vibrate(pattern);
        } catch (e) {
        }
    }

    function absoluteFloat(value as Float) as Float {
        if (value < 0.0) {
            return -value;
        }
        return value;
    }
}
