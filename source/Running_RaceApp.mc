import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

// ---------------------------------------------------------------------------
// Running_RaceApp  –  application entry point
// ---------------------------------------------------------------------------
// IMPROVEMENT: Default property initialisation now covers all properties
// declared in properties.xml, including targetDistanceCode which was missing
// from the original initializeDefaultProperties().
// Also: property keys are only written once (on first install) – subsequent
// launches respect the user's already-saved settings.
// ---------------------------------------------------------------------------

class Running_RaceApp extends Application.AppBase {

    function initialize() {
        AppBase.initialize();
        initializeDefaultProperties();
    }

    // Write defaults only if a property has never been set (first install).
    function initializeDefaultProperties() as Void {
        setDefault("backgroundMode",         0);
        setDefault("targetPaceSecPerKm",     300);
        setDefault("targetDistanceCode",     2);    // 0=10 km, 1=HM, 2=Marathon
        setDefault("targetTime",             12600);
        setDefault("paceToleranceSec",       10);
        setDefault("nutritionStartDelaySec", 900);
        setDefault("nutritionAlarm1",        8000);
        setDefault("nutritionAlarm2",        18000);
        setDefault("nutritionAlarm3",        30000);
        setDefault("nutritionAlarm4",        38000);
        setDefault("hrZone1",  114);
        setDefault("hrZone2",  133);
        setDefault("hrZone3",  152);
        setDefault("hrZone4",  171);
        setDefault("hrZone5",  190);
    }

    // Helper: write value only if the key is not yet set.
    function setDefault(key as String, value as Number) as Void {
        if (Application.Properties.getValue(key) == null) {
            Application.Properties.setValue(key, value);
        }
    }

    function onStart(state as Dictionary?) as Void {}
    function onStop(state as Dictionary?)  as Void {}

    function getInitialView() as [Views] or [Views, InputDelegates] {
        return [new Running_RaceView()];
    }
}

function getApp() as Running_RaceApp {
    return Application.getApp() as Running_RaceApp;
}
