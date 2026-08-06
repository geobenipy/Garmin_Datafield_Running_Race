import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

// ---------------------------------------------------------------------------
// Running_RaceApp  –  application entry point
// ---------------------------------------------------------------------------
// Two entry points, not one:
//   getInitialView()  – the data field itself, drawn during the activity.
//   getSettingsView() – the on-watch race setup.  A data field may not take
//                       input while it is drawing, so this is the sanctioned
//                       way to configure one from the wrist: the system pushes
//                       the menu itself, from the activity menu.  (Connect IQ
//                       Programmer's Guide, "On Device Watch Face and Data
//                       Field Settings", API 3.2.0+ — this app needs 6.0.0.)
//
// Property keys are only written once, on first install — subsequent launches
// respect whatever the user has saved.
// ---------------------------------------------------------------------------

class Running_RaceApp extends Application.AppBase {

    function initialize() {
        AppBase.initialize();
        initializeDefaultProperties();
    }

    // Write defaults only if a property has never been set (first install).
    function initializeDefaultProperties() as Void {
        setDefault("targetPaceSecPerKm",     RaceSetup.DEFAULT_PACE_SEC);
        setDefault("paceToleranceSec",       RaceSetup.DEFAULT_TOL_SEC);
        migrateRaceDistance();
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

    // raceDistanceM (free metres, settable on the watch) replaced the old
    // three-way targetDistanceCode.  On an upgrade the new key is still null
    // while the old one holds the user's actual choice, so carry it over once
    // rather than silently resetting someone's half marathon to a marathon.
    // targetDistanceCode stays declared in properties.xml purely so this read
    // is well defined; nothing else looks at it.
    function migrateRaceDistance() as Void {
        try {
            if (Application.Properties.getValue("raceDistanceM") != null) { return; }
        } catch (e) {
            return;    // cannot tell – leave the default from properties.xml
        }

        var meters = RaceSetup.DEFAULT_DIST_M;         // 2 = Marathon
        var code   = RaceSetup.readNumber("targetDistanceCode", 2);
        if (code == 0)      { meters = 10000; }
        else if (code == 1) { meters = 21098; }
        RaceSetup.setDistanceM(meters);
    }

    // Helper: write value only if the key is not yet set.
    function setDefault(key as String, value as Number) as Void {
        try {
            if (Application.Properties.getValue(key) == null) {
                Application.Properties.setValue(key, value);
            }
        } catch (e) {
            // An unreadable key must not stop the remaining defaults, and must
            // certainly not stop the field from loading.
        }
    }

    function onStart(state as Dictionary?) as Void {}
    function onStop(state as Dictionary?)  as Void {}

    // A phone or Garmin Express sync landing mid-race.  The field is running in
    // its own view, so all this does is raise the flag RaceEngine clears at its
    // next heavy refresh, which is where the reload actually happens.
    function onSettingsChanged() as Void {
        RaceSetup.dirty = true;
    }

    function getInitialView() as [Views] or [Views, InputDelegates] {
        return [new Running_RaceView()];
    }

    // The on-watch race setup, pushed by the system from the activity menu.
    function getSettingsView() as [Views] or [Views, InputDelegates] or Null {
        var menu = new RaceSettingsMenu();
        return [menu, new RaceSettingsMenuDelegate(menu)];
    }
}

function getApp() as Running_RaceApp {
    return Application.getApp() as Running_RaceApp;
}
