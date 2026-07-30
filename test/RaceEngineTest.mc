import Toybox.Lang;
import Toybox.System;
import Toybox.Test;

// ---------------------------------------------------------------------------
// Unit tests  –  run with `.\run.ps1 -Test`
// ---------------------------------------------------------------------------
// These are regression tests for the failure mode that killed the field during
// a real run on 2026-07-29: the watch froze shortly after an auto-pause and the
// data field was gone after the reboot.  Two defects combined —
//
//   1. trimSamples() used Array.remove(0), which removes by VALUE.  No sample
//      is ever 0, so the ring buffer never shrank and the trim loop spun
//      forever the moment it filled up (~10 min of running).  compute() never
//      returned; the watchdog killed the field.
//   2. compute() read Activity.Info.elapsedTime (wall clock, keeps running
//      while paused) instead of timerTime, so standing still still ticked a
//      "new second" every second and stacked stale samples into that buffer.
//
// So the bar for this suite is: drive the REAL update path for a REAL race
// distance, including a stop, and assert that it terminates, stays bounded in
// time and memory, and produces sane numbers.  A short happy-path test would
// have passed while the field was still lethal.
// ---------------------------------------------------------------------------

// === 1. the crash itself ===================================================

// Direct, non-hanging check on the trim primitive.  Deliberately first: if the
// buffer logic regresses, this fails in milliseconds instead of hanging the
// whole suite the way the long-running tests below would.
(:test)
function testTrimSamplesDropsOldestAndTerminates(logger as Test.Logger) as Boolean {
    var pace = new RacePaceLogic(new RaceConfig());

    var buf = [] as Array<Numeric>;
    for (var i = 1; i <= 500; i += 1) { buf.add(i.toFloat()); }

    buf = pace.trimSamples(buf, 100);
    logger.debug("500 samples trimmed to " + buf.size());

    Test.assertMessage(buf.size() <= 100 + pace.TRIM_SLACK,
        "buffer was not trimmed: " + buf.size() + " entries left");
    Test.assertMessage(buf.size() >= 100,
        "trim cut below the requested window: " + buf.size() + " entries left");
    Test.assertEqualMessage(buf[buf.size() - 1], 500.0,
        "trim dropped from the wrong end - the newest sample is gone");
    Test.assertMessage((buf[0] as Float) > 1.0,
        "trim kept the oldest sample, so nothing was actually removed");

    // Degenerate inputs must terminate too.
    Test.assertEqual(pace.trimSamples(buf, 0).size(), 0);
    Test.assertEqual(pace.trimSamples([] as Array<Numeric>, 10).size(), 0);
    return true;
}

// The full race.  This is the test that reproduces the crash end to end: it
// runs well past the 600 s sample window, so the broken trim loop would hang
// here rather than pass.
(:test)
function testFullMarathonWithAStopStaysHealthy(logger as Test.Logger) as Boolean {
    var sim = new RaceSim();

    sim.run(120,   0.0,   null, 3);   // waiting on the start line, no GPS speed
    sim.run(1800,  300.0, 150,  3);   // 30 min on target pace
    sim.pause(90,  4);                // shoe stop -> Garmin auto-pause
    sim.run(300,   595.0, 120,  3);   // the 9:55/km crawl right after restarting
    sim.runWithoutGps(120, 300.0, 155, 3);   // tunnel: no fix, distance still moves
    sim.run(11000, 305.0, 158,  1);   // the rest of the marathon

    var pace = sim.engine.paceLogic;
    var hr   = sim.engine.hrLogic;

    logger.debug("finished " + pace.distanceKm + " km in " + pace.elapsedSec + " s"
                 + ", pace buffer " + pace.paceSamples.size()
                 + ", hr buffer " + hr.hrSamples.size()
                 + ", reserve " + sim.engine.reserveLogic.reservePercent + "%");

    // The buffers must stay bounded — this is the crash condition.
    Test.assertMessage(
        pace.paceSamples.size() <= sim.engine.config.sampleWindowSec + pace.TRIM_SLACK,
        "pace buffer grew unbounded: " + pace.paceSamples.size() + " samples");
    Test.assertMessage(
        hr.hrSamples.size() <= sim.engine.config.sampleWindowSec + hr.TRIM_SLACK,
        "hr buffer grew unbounded: " + hr.hrSamples.size() + " samples");

    // ...and the race must still make sense at the finish.
    Test.assertEqualMessage(pace.elapsedSec, sim.timerSec,
        "race clock drifted away from the activity timer");
    Test.assertMessage(pace.distanceKm >= 42.195,
        "the simulated race never reached the finish: " + pace.distanceKm + " km");
    Test.assertEqualMessage(pace.remainingKm, 0.0,
        "remaining distance did not run out at the finish");
    Test.assertMessage(pace.smoothedPaceSec > 0.0 && pace.smoothedPaceSec < 1200.0,
        "smoothed pace out of range: " + pace.smoothedPaceSec);
    Test.assertMessage(pace.averagePaceSec > 0.0 && pace.averagePaceSec < 1200.0,
        "average pace out of range: " + pace.averagePaceSec);
    Test.assertMessage(pace.projectedFinishSec > 0 && pace.projectedFinishSec < 86400,
        "projected finish out of range: " + pace.projectedFinishSec);
    Test.assertMessage(sim.engine.reserveLogic.reservePercent >= 0 &&
                       sim.engine.reserveLogic.reservePercent <= 100,
        "reserve is not a percentage: " + sim.engine.reserveLogic.reservePercent);
    return true;
}

// === 2. the auto-pause that triggered it ===================================

(:test)
function testAutoPauseDoesNotAdvanceTheRace(logger as Test.Logger) as Boolean {
    var sim = new RaceSim();
    sim.run(600, 300.0, 150, 3);

    var pace           = sim.engine.paceLogic;
    var secBefore      = pace.elapsedSec;
    var samplesBefore  = pace.paceSamples.size();
    var finishBefore   = pace.projectedFinishSec;
    var distanceBefore = pace.distanceKm;

    sim.pause(300, 4);   // five minutes standing still, ~1200 compute() calls

    Test.assertEqualMessage(pace.elapsedSec, secBefore,
        "paused time leaked into the race clock");
    Test.assertEqualMessage(pace.paceSamples.size(), samplesBefore,
        "stale pace samples stacked up while the timer was paused");
    Test.assertEqualMessage(pace.projectedFinishSec, finishBefore,
        "the finish projection drifted while the timer was paused");
    Test.assertEqualMessage(pace.distanceKm, distanceBefore,
        "distance moved while standing still");

    // ...and the race picks up cleanly afterwards.
    sim.run(120, 300.0, 150, 3);
    Test.assertEqualMessage(pace.elapsedSec, secBefore + 120,
        "the clock did not resume correctly after the pause");
    return true;
}

// === 3. unbounded loops and unbounded memory ===============================

// A tunnel re-acquire can drop several kilometres in at once.  Catching up must
// be O(1): a per-kilometre loop inside compute() is the same class of bug as
// the trim loop that caused the crash.
(:test)
function testGpsJumpDoesNotStallTheLapLoop(logger as Test.Logger) as Boolean {
    var sim = new RaceSim();
    sim.run(60, 300.0, 150, 1);

    var start = System.getTimer();
    sim.engine.tick(61, 12.4, 3.3, 3.3, 150, null, 0.0);
    var ms = System.getTimer() - start;
    logger.debug("12 km GPS jump handled in " + ms + " ms");

    Test.assertEqualMessage(sim.engine.paceLogic.nextAutoLapKm, 13.0,
        "auto-lap did not catch up to the jump in a single step");
    Test.assertMessage(ms < 1000, "a single tick took " + ms + " ms");
    return true;
}

(:test)
function testMemoryDoesNotGrowOverTheRace(logger as Test.Logger) as Boolean {
    var sim = new RaceSim();
    sim.run(1200, 300.0, 150, 1);            // let every buffer reach steady state

    var before = System.getSystemStats().usedMemory;
    sim.run(3600, 300.0, 150, 1);            // another hour of racing
    var after  = System.getSystemStats().usedMemory;

    logger.debug("used memory " + before + " -> " + after + " bytes");
    Test.assertMessage((after - before) < 8192,
        "memory grew by " + (after - before) + " bytes over an hour of racing");
    return true;
}

// Guards the time budget of compute() itself.  The bound is deliberately loose:
// this is here to catch a runaway loop or accidental O(n^2) work, not to police
// microseconds on a simulator whose speed varies by machine.
(:test)
function testTickCostStaysWithinBudget(logger as Test.Logger) as Boolean {
    var sim = new RaceSim();
    sim.run(600, 300.0, 150, 1);             // warm the buffers up first

    var start = System.getTimer();
    sim.run(600, 300.0, 150, 4);             // 2400 compute() calls
    var ms = System.getTimer() - start;

    logger.debug("2400 ticks in " + ms + " ms");
    Test.assertMessage(ms < 20000,
        "compute() is far too slow: " + ms + " ms for 2400 calls");
    return true;
}

// === 4. hostile sensor data ================================================

// Every one of these is something a watch really can hand a data field: a
// dropped sensor, a bad fix, a clock that steps backwards.  None may throw.
(:test)
function testHostileInputsNeverThrow(logger as Test.Logger) as Boolean {
    var sim = new RaceSim();
    var e   = sim.engine;

    e.tick(null, null, null, null, null, null, null);          // everything missing
    e.tick(-500, -3.0, -1.0, -1.0, -40, -10, -2.0);            // negatives
    e.tick(10, 0.0, 0.0, 0.0, 0, 0, 0.0);                      // all zero
    e.tick(999999999, 99999.0, 100000.0, 100000.0, 900, 50000, 99999.0);  // absurd
    e.tick(20, 1.0, 0.0000001, 0.0000001, 250, null, 0.0);     // near-zero speed
    e.tick(5, 0.5, 3.0, 3.0, 150, null, 0.0);                  // clock steps back
    e.onTimerLap();
    e.tick(6, 0.51, 3.0, 3.0, 150, 260, 0.0);

    var pace = e.paceLogic;
    Test.assertMessage(pace.smoothedPaceSec >= 0.0,
        "pace went negative: " + pace.smoothedPaceSec);
    Test.assertMessage(pace.elapsedSec >= 0, "clock went negative");
    Test.assertMessage(pace.distanceKm >= 0.0, "distance went negative");
    Test.assertMessage(pace.remainingKm >= 0.0, "remaining distance went negative");
    Test.assertMessage(e.reserveLogic.reservePercent >= 0 &&
                       e.reserveLogic.reservePercent <= 100,
        "reserve is not a percentage: " + e.reserveLogic.reservePercent);
    return true;
}

// Crawling speeds used to produce absurd average paces (0.26 m/s -> 3846 s/km,
// or 20 m after 20 min -> 60000 s/km) which fed straight into the finish
// projection and could push it past what a Number can hold.
(:test)
function testCrawlingSpeedsCannotBlowUpTheProjection(logger as Test.Logger) as Boolean {
    var sim  = new RaceSim();
    var e    = sim.engine;
    var pace = e.paceLogic;

    // 20 m covered in 20 minutes, reported both ways round
    e.tick(1200, 0.02, 0.0008, 0.0008, 140, null, 0.0);
    e.tick(1210, 0.021, 0.26,   0.26,   140, null, 0.0);
    e.tick(1220, 0.022, 0.26,   0.26,   140, null, 0.0);
    logger.debug("avg pace " + pace.averagePaceSec +
                 " s/km, projection " + pace.projectedFinishSec + " s");

    Test.assertMessage(pace.averagePaceSec >= 0.0 && pace.averagePaceSec <= 1200.0,
        "average pace escaped its bound: " + pace.averagePaceSec);
    Test.assertMessage(pace.projectedFinishSec >= 0 &&
                       pace.projectedFinishSec <= 86400,
        "finish projection escaped its bound: " + pace.projectedFinishSec);

    // ...and a 500 km course remaining must not push it out either
    e.tick(1230, 0.023, 0.26, 0.26, 140, null, 9000.0);
    Test.assertMessage(pace.projectedFinishSec >= 0 &&
                       pace.projectedFinishSec <= 86400,
        "a long course blew up the projection: " + pace.projectedFinishSec);
    return true;
}

// rolling5MinHr must come from this activity's own samples.  It used to be read
// from SensorHistory with a :period that means "entries", not seconds, so it
// averaged hours of history — including resting HR — and sat far below the
// running HR for the whole race.
(:test)
function testRollingHrReflectsTheCurrentActivity(logger as Test.Logger) as Boolean {
    var sim = new RaceSim();
    sim.run(900, 300.0, 158, 1);        // 15 min at a steady 158 bpm
    var hr = sim.engine.hrLogic;

    logger.debug("current " + hr.currentHr + " bpm, rolling " + hr.rolling5MinHr);
    Test.assertEqualMessage(hr.currentHr, 158, "current HR was not picked up");
    Test.assertMessage(hr.rolling5MinHr > 156.0 && hr.rolling5MinHr < 160.0,
        "rolling HR is not tracking the activity: " + hr.rolling5MinHr);
    Test.assertMessage(!hr.driftActive,
        "a perfectly steady HR must not register as drift");
    return true;
}

// A backwards clock must not wedge the heavy tier off for the rest of the race.
(:test)
function testHeavyTierRecoversFromABackwardsClock(logger as Test.Logger) as Boolean {
    var sim = new RaceSim();
    sim.run(300, 300.0, 150, 1);

    var pace = sim.engine.paceLogic;
    pace.elapsedSec = 10;                    // clock steps far back
    Test.assertMessage(pace.isHeavyRefreshDue(),
        "the heavy tier stayed switched off after the clock stepped backwards");
    return true;
}

// === 5. what the face actually shows =======================================

(:test)
function testPaceStatusBands(logger as Test.Logger) as Boolean {
    var cfg = new RaceConfig();
    cfg.targetPaceSec    = 300.0;            // 5:00 /km
    cfg.paceToleranceSec = 10.0;
    var pace = new RacePaceLogic(cfg);

    Test.assertEqualMessage(pace.paceStatus(300.0),  0, "5:00 must read as on target");
    Test.assertEqualMessage(pace.paceStatus(291.0),  0, "4:51 is inside tolerance");
    Test.assertEqualMessage(pace.paceStatus(309.0),  0, "5:09 is inside tolerance");
    Test.assertEqualMessage(pace.paceStatus(280.0), -1, "4:40 must read as too fast");
    Test.assertEqualMessage(pace.paceStatus(330.0),  1, "5:30 must read as too slow");
    Test.assertEqualMessage(pace.paceStatus(0.0),    0, "no reading must not raise an alarm");
    Test.assertEqualMessage(pace.paceStatus(5000.0), 0, "a junk reading must not raise an alarm");
    return true;
}

// Lap pace divides by the distance since the anchor, which is ~0 for a moment
// on every single kilometre — and it must follow the current lap, not quietly
// track the whole-race average.
(:test)
function testLapPaceTracksTheCurrentKilometre(logger as Test.Logger) as Boolean {
    var sim = new RaceSim();
    sim.run(605, 300.0, 150, 1);        // just past 2 km at 5:00/km
    var pace = sim.engine.paceLogic;

    Test.assertEqualMessage(pace.lapAnchorDistanceKm, 2.0,
        "auto-lap did not anchor on the 2 km mark");
    Test.assertEqualMessage(pace.lapPaceSec(), 0.0,
        "a lap with almost no distance yet must report nothing, not a divide");

    sim.run(120, 270.0, 150, 1);        // 2 min into the new km, 30 s/km faster
    logger.debug("lap pace " + pace.lapPaceSec() +
                 " s/km vs average " + pace.averagePaceSec);

    Test.assertMessage(pace.lapPaceSec() > 260.0 && pace.lapPaceSec() < 285.0,
        "lap pace did not track the current kilometre: " + pace.lapPaceSec());
    Test.assertMessage(pace.lapPaceSec() < pace.averagePaceSec,
        "lap pace is following the whole-race average instead of the current lap");

    // A manual lap press re-anchors and clears it again.
    sim.engine.onTimerLap();
    Test.assertEqualMessage(pace.lapPaceSec(), 0.0,
        "lap pace survived a lap press instead of restarting");
    return true;
}

// The progress arc divides by a setting, so a zero or a finished race must not
// be able to reach the drawing code as a bad fraction.
(:test)
function testRaceProgressStaysAFraction(logger as Test.Logger) as Boolean {
    var cfg  = new RaceConfig();
    cfg.raceDistanceKm = 42.195;
    var pace = new RacePaceLogic(cfg);

    Test.assertEqualMessage(pace.raceProgress(), 0.0, "an unstarted race is not at 0");

    pace.distanceKm = 21.0975;
    Test.assertMessage(pace.raceProgress() > 0.49 && pace.raceProgress() < 0.51,
        "halfway did not read as ~0.5: " + pace.raceProgress());

    pace.distanceKm = 50.0;                  // overshoot past the finish
    Test.assertEqualMessage(pace.raceProgress(), 1.0, "progress ran past 1.0");

    pace.distanceKm = -3.0;
    Test.assertEqualMessage(pace.raceProgress(), 0.0, "progress went negative");

    cfg.raceDistanceKm = 0.0;                // must not divide by zero
    pace.distanceKm    = 10.0;
    Test.assertEqualMessage(pace.raceProgress(), 0.0,
        "a zero race distance must yield no progress, not a divide");
    return true;
}

(:test)
function testBannersExpire(logger as Test.Logger) as Boolean {
    var alerts = new RaceAlertLogic(new RaceConfig());

    alerts.showBanner("TEST", 0xFFFFFF, 30);
    Test.assertMessage(alerts.hasActiveBanner(20), "banner did not come up");

    alerts.clearExpiredBanner(31);
    Test.assertMessage(!alerts.hasActiveBanner(31),
        "banner outstayed its window and would keep covering the pace tile");
    return true;
}

// Settings arrive from the phone and can be missing or out of range; a bad one
// must never be able to poison every pace comparison for the whole race.
(:test)
function testConfigClampsHostileSettings(logger as Test.Logger) as Boolean {
    var cfg = new RaceConfig();

    Test.assertMessage(cfg.targetPaceSec >= 120.0 && cfg.targetPaceSec <= 900.0,
        "target pace out of range: " + cfg.targetPaceSec);
    Test.assertMessage(cfg.paceToleranceSec >= 1.0 && cfg.paceToleranceSec <= 120.0,
        "pace tolerance out of range: " + cfg.paceToleranceSec);
    Test.assertMessage(cfg.targetTimeSec >= 600 && cfg.targetTimeSec <= 86400,
        "target time out of range: " + cfg.targetTimeSec);
    Test.assertEqualMessage(cfg.readInt("no_such_property_at_all", 42), 42,
        "an unknown property must fall back to its default");

    var zones = cfg.hrZones as Array<Number>;
    Test.assertEqualMessage(zones.size(), 5, "there must be exactly five HR zones");
    for (var i = 1; i < zones.size(); i += 1) {
        Test.assertMessage((zones[i] as Number) > (zones[i - 1] as Number),
            "HR zone thresholds are not strictly increasing at index " + i);
    }
    return true;
}
