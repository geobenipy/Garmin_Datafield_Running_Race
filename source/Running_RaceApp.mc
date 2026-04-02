import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

class Running_RaceApp extends Application.AppBase {

    function initialize() {
        AppBase.initialize();
        initializeDefaultProperties();
    }

    function initializeDefaultProperties() as Void {
        if (Application.Properties.getValue("backgroundMode") == null) {
            Application.Properties.setValue("backgroundMode", 0);
        }

        if (Application.Properties.getValue("targetPaceSecPerKm") == null) {
            Application.Properties.setValue("targetPaceSecPerKm", 300);
        }

        if (Application.Properties.getValue("targetDistanceCode") == null) {
            Application.Properties.setValue("targetDistanceCode", 2);
        }

        if (Application.Properties.getValue("targetTime") == null) {
            Application.Properties.setValue("targetTime", 12600);
        }

        if (Application.Properties.getValue("paceToleranceSec") == null) {
            Application.Properties.setValue("paceToleranceSec", 10);
        }

        if (Application.Properties.getValue("nutritionStartDelaySec") == null) {
            Application.Properties.setValue("nutritionStartDelaySec", 900);
        }

        // Fuel alerts: meter > 0, seconds < 0, 0 = off
        if (Application.Properties.getValue("nutritionAlarm1") == null) {
            Application.Properties.setValue("nutritionAlarm1", 8000);
        }
        if (Application.Properties.getValue("nutritionAlarm2") == null) {
            Application.Properties.setValue("nutritionAlarm2", 18000);
        }
        if (Application.Properties.getValue("nutritionAlarm3") == null) {
            Application.Properties.setValue("nutritionAlarm3", 30000);
        }
        if (Application.Properties.getValue("nutritionAlarm4") == null) {
            Application.Properties.setValue("nutritionAlarm4", 38000);
        }

        if (Application.Properties.getValue("hrZone1") == null) {
            Application.Properties.setValue("hrZone1", 114);
        }
        if (Application.Properties.getValue("hrZone2") == null) {
            Application.Properties.setValue("hrZone2", 133);
        }
        if (Application.Properties.getValue("hrZone3") == null) {
            Application.Properties.setValue("hrZone3", 152);
        }
        if (Application.Properties.getValue("hrZone4") == null) {
            Application.Properties.setValue("hrZone4", 171);
        }
        if (Application.Properties.getValue("hrZone5") == null) {
            Application.Properties.setValue("hrZone5", 190);
        }
    }

    function onStart(state as Dictionary?) as Void {}
    function onStop(state as Dictionary?) as Void {}

    function getInitialView() as [Views] or [Views, InputDelegates] {
        return [new Running_RaceView()];
    }
}

function getApp() as Running_RaceApp {
    return Application.getApp() as Running_RaceApp;
}
