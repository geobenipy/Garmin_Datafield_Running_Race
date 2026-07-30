import Toybox.Lang;

// ---------------------------------------------------------------------------
// RaceSim  –  drives a real RaceEngine through a synthetic race
// ---------------------------------------------------------------------------
// Test-only harness (test/ is not on the release sourcePath, see test.jungle).
//
// The point of this class is that it calls the SAME RaceEngine.tick() the watch
// calls, at the same rate — several times per second, once per second a new
// timer second — so the tests exercise the real three-tier update instead of a
// hand-rolled imitation of it.  The crash on 2026-07-29 lived in that path:
// the pace ring buffer never shrank, compute() stopped returning, and the
// watchdog killed the field.  Any test that never runs longer than the buffer
// window would have missed it, so the marathon test runs the full distance.
// ---------------------------------------------------------------------------

class RaceSim {

    var engine;
    var timerSec   = 0;        // activity TIMER seconds, frozen while paused
    var distanceKm = 0.0;

    function initialize() {
        engine = new RaceEngine();
        // Pin the tuning so assertions never depend on the simulator's user
        // profile or on whatever settings happen to be stored.
        engine.config.targetPaceSec    = 300.0;      // 5:00 /km
        engine.config.paceToleranceSec = 10.0;
        engine.config.raceDistanceKm   = 42.195;
        engine.config.targetTimeSec    = 12659;      // 42.195 km at 5:00 /km
        engine.config.hrZones          = [114, 133, 152, 171, 190] as Array<Number>;
    }

    // Run `seconds` of moving activity at `paceSec` per km.  ticksPerSecond
    // mirrors the watch calling compute() several times per second — the tier
    // gating has to survive that, it is what the original smoothing bug was.
    // paceSec <= 0 means "standing on the start line": timer runs, GPS speed is
    // null, no distance accrues.
    function run(seconds as Number, paceSec as Float,
                 hrValue, ticksPerSecond as Number) as Void {
        var speed = paceSec > 0.0 ? 1000.0 / paceSec : null;
        for (var i = 0; i < seconds; i += 1) {
            timerSec += 1;
            if (speed != null) { distanceKm += speed / 1000.0; }
            for (var k = 0; k < ticksPerSecond; k += 1) {
                engine.tick(timerSec, distanceKm, speed, averageSpeed(),
                            hrValue, null, 0.0);
            }
        }
    }

    // Stopped or auto-paused: the timer is frozen and distance does not move,
    // but compute() keeps being called several times a second.  This is exactly
    // the shoe-tying stop that preceded the crash.
    function pause(seconds as Number, ticksPerSecond as Number) as Void {
        for (var i = 0; i < seconds; i += 1) {
            for (var k = 0; k < ticksPerSecond; k += 1) {
                engine.tick(timerSec, distanceKm, 0.0, averageSpeed(),
                            null, null, 0.0);
            }
        }
    }

    // Moving with no GPS fix: the timer and distance still advance (the watch
    // dead-reckons from the accelerometer) but currentSpeed reads null.
    function runWithoutGps(seconds as Number, paceSec as Float,
                           hrValue, ticksPerSecond as Number) as Void {
        var speed = paceSec > 0.0 ? 1000.0 / paceSec : 0.0;
        for (var i = 0; i < seconds; i += 1) {
            timerSec   += 1;
            distanceKm += speed / 1000.0;
            for (var k = 0; k < ticksPerSecond; k += 1) {
                engine.tick(timerSec, distanceKm, null, averageSpeed(),
                            hrValue, null, 0.0);
            }
        }
    }

    function averageSpeed() {
        if (timerSec <= 0 || distanceKm <= 0.0) { return null; }
        return (distanceKm * 1000.0) / timerSec.toFloat();
    }
}
