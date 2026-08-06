import Toybox.Activity;
import Toybox.Lang;
import Toybox.Sensor;
import Toybox.System;

// ---------------------------------------------------------------------------
// RaceEngine  –  the complete update path, free of Activity.Info and of Dc
// ---------------------------------------------------------------------------
// Running_RaceView used to own this.  It moved into its own class so the unit
// tests in test/RaceEngineTest.mc can drive the *real* three-tier update with a
// synthetic race — auto-pause, GPS dropouts, a 42 km run-out — instead of only
// poking the logic classes one at a time.  The view keeps references to the
// same logic objects, so every drawing routine is unchanged.
//
// tick() takes plain numbers; onCompute() is the thin Activity.Info adapter.
// ---------------------------------------------------------------------------

class RaceEngine {

    const MAX_RACE_SEC = 86400;      // 24 h – anything beyond is a bad reading
    const MAX_RACE_KM  = 500.0;
    const MAX_POWER_W  = 2000;

    var config;
    var paceLogic;
    var hrLogic;
    var reserveLogic;
    var alertLogic;

    var currentPower   = 0;
    var hasPower       = false;
    var hasHrStrap     = false;   // verticalRatio present => RD pod / chest strap
    var chestStatus    = 0;
    var phoneConnected = false;

    function initialize() {
        config       = new RaceConfig();
        paceLogic    = new RacePaceLogic(config);
        hrLogic      = new RaceHeartRateLogic(config);
        reserveLogic = new RaceReserveLogic(config);
        alertLogic   = new RaceAlertLogic(config);
    }

    // -----------------------------------------------------------------------
    // Called from Running_RaceView.compute() several times per second.
    // Wrapped whole in try/catch: a single unexpected sensor value must never
    // throw out of here and freeze/kill the field mid-race.
    // -----------------------------------------------------------------------
    function onCompute(info as Activity.Info) as Void {
        try {
            // timerTime, NOT elapsedTime.  elapsedTime is wall clock and keeps
            // running while the activity is stopped or auto-paused; feeding it
            // in made the field tick a "new second" every second while standing
            // still, stacking stale pace samples and inflating the projection.
            // timerTime is the same clock the watch's own Timer field shows.
            var timerSec = paceLogic.elapsedSec;
            if (info.timerTime != null) {
                timerSec = (info.timerTime / 1000).toNumber();
            } else if (info.elapsedTime != null) {
                timerSec = (info.elapsedTime / 1000).toNumber();
            }

            var distKm = paceLogic.distanceKm;
            if (info.elapsedDistance != null) { distKm = info.elapsedDistance / 1000.0; }

            // Course awareness: PacePro's target pace is not exposed by CIQ, but
            // a loaded route is.  When navigating, feed the true remaining
            // distance so "remaining" and the finish projection track the real
            // course; 0 keeps the configured race distance as the fallback.
            var courseRemainingKm = 0.0;
            if (info has :distanceToDestination) {
                var dtd = info.distanceToDestination;
                if (dtd != null && dtd > 0.0) { courseRemainingKm = dtd / 1000.0; }
            }

            // Power is no longer displayed, but RaceReserveLogic still uses it
            // for the power-efficiency term when a meter is present.
            var power = info.currentPower;

            hasHrStrap = false;
            if (info has :verticalRatio) {
                var vr = info.verticalRatio;
                if (vr != null && vr > 0.0) { hasHrStrap = true; }
            }

            tick(timerSec, distKm, info.currentSpeed, info.averageSpeed,
                 info.currentHeartRate, power, courseRemainingKm);
        } catch (ex) {
            // Swallow: keep the last good values on screen rather than crash.
        }
    }

    // -----------------------------------------------------------------------
    // The three-tier update.  Every argument may be null or nonsense — this is
    // the boundary where sensor data is made safe for the logic classes.
    //   1. every call        : raw instantaneous values only
    //   2. every new second  : samples, smoothed pace, laps, banners
    //   3. every heavyUpdateSec : rolling pace, projection, reserve, feedback
    // -----------------------------------------------------------------------
    function tick(timerSec, distanceKm, currentSpeed, averageSpeed,
                  heartRate, power, courseRemainingKm) as Void {

        var t = sanitizeSeconds(timerSec);
        var d = sanitizeDistanceKm(distanceKm);

        currentPower = 0;
        hasPower     = false;
        if (power != null && power > 0 && power < MAX_POWER_W) {
            currentPower = power.toNumber();
            hasPower     = true;
        }

        paceLogic.courseRemainingKm = sanitizeDistanceKm(courseRemainingKm);

        var isNewSecond = paceLogic.update(t, d, currentSpeed, averageSpeed);
        hrLogic.update(heartRate, isNewSecond);

        if (isNewSecond) {
            alertLogic.clearExpiredBanner(paceLogic.elapsedSec);
            alertLogic.checkNutrition(paceLogic);
        }
        if (paceLogic.isHeavyRefreshDue()) {
            refreshSettings();
            paceLogic.refreshHeavy();
            hrLogic.refreshHeavy(paceLogic);
            reserveLogic.refreshHeavy(paceLogic, hrLogic, currentPower, hasPower);
            refreshSensorStatus();
            alertLogic.checkFiveKmFeedback(paceLogic, hrLogic,
                                           reserveLogic.reservePercent);
        }
    }

    function onTimerLap() as Void {
        try {
            paceLogic.handleLapTrigger();
            hrLogic.resetDrift(paceLogic.lastLapResetSec);
            alertLogic.showBanner("Lap synced", 0x63C6F5,
                                  paceLogic.elapsedSec + config.bannerShortSec);
        } catch (ex) {
            // A lap press must never be able to take the field down.
        }
    }

    // -----------------------------------------------------------------------
    // Settings – heavy tier only
    // -----------------------------------------------------------------------
    // Target pace and race distance are editable from the wrist now (see
    // RaceSettingsMenu), so they can change in the middle of a race and the
    // cached config has to follow.  Two cadences, because the two costs differ
    // by an order of magnitude:
    //   · RaceSetup.dirty is set by the settings menu and by
    //     AppBase.onSettingsChanged(), and triggers a full reload — including
    //     the UserProfile HR-zone lookup, which is far too expensive to repeat.
    //   · Otherwise just poll the three race targets: three property reads
    //     every 10 s, and config only re-applies when a value really moved.
    // The poll is the belt to the flag's braces: it lands the change even if
    // the settings view ran outside this app instance.
    // -----------------------------------------------------------------------
    function refreshSettings() as Void {
        if (RaceSetup.dirty) {
            RaceSetup.dirty = false;
            config.load();
        } else {
            config.pollTargets();
        }
    }

    // -----------------------------------------------------------------------
    // Connection status – heavy tier only, both calls are relatively expensive
    // -----------------------------------------------------------------------
    function refreshSensorStatus() as Void {
        chestStatus = 0;
        try {
            if (Sensor has :getRegisteredSensors) {
                var it = Sensor.getRegisteredSensors(Sensor.SENSOR_HEARTRATE);
                if (it != null) {
                    var s = it.next();
                    while (s != null) {
                        if (s.enabled) {
                            if (s.technology == Sensor.SENSOR_TECHNOLOGY_ANT) {
                                chestStatus = 2;
                                break;
                            }
                            if (chestStatus < 1) { chestStatus = 1; }
                        }
                        s = it.next();
                    }
                }
            }
        } catch (e) { chestStatus = 0; }
        if (hasHrStrap && chestStatus < 2) { chestStatus = 2; }

        phoneConnected = false;
        try {
            var ds = System.getDeviceSettings();
            if (ds != null && ds has :phoneConnected && ds.phoneConnected != null) {
                phoneConnected = ds.phoneConnected;
            }
        } catch (e) { phoneConnected = false; }
    }

    // -----------------------------------------------------------------------
    // Input sanitisers.  `!(v > 0.0)` also rejects NaN, which every ordinary
    // `v <= 0.0` comparison would silently let through.
    // -----------------------------------------------------------------------
    function sanitizeSeconds(value) as Number {
        if (value == null) { return 0; }
        // Range-check as a Float first: toNumber() on a NaN or on something far
        // past 2^31 is not defined to do anything sensible.
        var f = value.toFloat();
        if (!(f > 0.0))                       { return 0; }
        if (f > MAX_RACE_SEC.toFloat())       { return MAX_RACE_SEC; }
        return f.toNumber();
    }

    function sanitizeDistanceKm(value) as Float {
        if (value == null) { return 0.0; }
        var v = value.toFloat();
        if (!(v > 0.0))      { return 0.0; }
        if (v > MAX_RACE_KM) { return MAX_RACE_KM; }
        return v;
    }
}
