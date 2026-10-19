import Toybox.Graphics;
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
    Test.assertMessage(cfg.targetTimeSec >= RaceSetup.MIN_TIME_SEC &&
                       cfg.targetTimeSec <= RaceSetup.MAX_TIME_SEC,
        "target time out of range: " + cfg.targetTimeSec);
    Test.assertMessage(cfg.raceDistanceKm >= 0.5 && cfg.raceDistanceKm <= 200.0,
        "race distance out of range: " + cfg.raceDistanceKm);
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

// === 6. the race distance and the target it implies ========================

// The distance readout counts down: 0.0/42.2 on the start line, 10.0/32.2 at
// ten kilometres, and never past zero however far the GPS overshoots.  This is
// what the face's R2 row prints, so it is worth pinning directly.
(:test)
function testRemainingDistanceCountsDown(logger as Test.Logger) as Boolean {
    var sim  = new RaceSim();
    var e    = sim.engine;
    var pace = e.paceLogic;

    e.tick(1, 0.0, null, null, 150, null, 0.0);
    Test.assertMessage(nearly(pace.remainingKm, 42.195),
        "a race that has not started must have all of it left: " + pace.remainingKm);

    e.tick(2, 10.0, 3.33, 3.33, 150, null, 0.0);
    Test.assertMessage(nearly(pace.remainingKm, 32.195),
        "10 km into a marathon must leave 32.195 km: " + pace.remainingKm);

    e.tick(3, 21.0975, 3.33, 3.33, 150, null, 0.0);
    Test.assertMessage(nearly(pace.remainingKm, 21.0975),
        "halfway must leave half: " + pace.remainingKm);

    e.tick(4, 45.0, 3.33, 3.33, 150, null, 0.0);
    Test.assertEqualMessage(pace.remainingKm, 0.0,
        "overshooting the finish must not count backwards: " + pace.remainingKm);
    return true;
}

// A loaded route outranks the configured distance — and not just for the
// remaining-distance readout: the progress arc, the reserve drain and the goal
// time all have to move onto the course's real length with it.
(:test)
function testALoadedCourseSetsTheRaceDistance(logger as Test.Logger) as Boolean {
    var sim  = new RaceSim();
    var e    = sim.engine;
    var pace = e.paceLogic;

    // 12 km done with 30.4 km of route ahead: a 42.4 km course, not the
    // 42.195 km configured.
    e.tick(3600, 12.0, 3.33, 3.33, 150, null, 30.4);
    logger.debug("course length " + pace.effectiveRaceDistanceKm() +
                 " km, target " + pace.effectiveTargetTimeSec() + " s");

    Test.assertMessage(nearly(pace.effectiveRaceDistanceKm(), 42.4),
        "the course length was not picked up: " + pace.effectiveRaceDistanceKm());
    Test.assertEqualMessage(pace.remainingKm, 30.4,
        "remaining distance ignored the course: " + pace.remainingKm);
    Test.assertMessage(pace.raceProgress() > 0.28 && pace.raceProgress() < 0.29,
        "progress is still measured against the setting: " + pace.raceProgress());
    Test.assertEqualMessage(pace.effectiveTargetTimeSec(),
        RaceSetup.timeSecFor(300, 42400),
        "the goal time did not follow the course length");

    // Navigation ends (or was never on): fall back to the configured race.
    e.tick(3601, 12.0, 3.33, 3.33, 150, null, 0.0);
    Test.assertEqualMessage(pace.effectiveRaceDistanceKm(), 42.195,
        "dropping the course did not fall back to the configured distance");
    Test.assertMessage(nearly(pace.remainingKm, 30.195),
        "remaining distance did not fall back: " + pace.remainingKm);
    Test.assertEqualMessage(pace.effectiveTargetTimeSec(), 12659,
        "the goal time did not fall back with it");
    return true;
}

// Pace, distance and goal time are three views of two numbers.  Round-tripping
// has to land back where it started, and neither direction may escape its
// bounds — the on-watch adjuster writes straight through these.
(:test)
function testTargetTimeAndPaceDeriveFromEachOther(logger as Test.Logger) as Boolean {
    Test.assertEqualMessage(RaceSetup.timeSecFor(300, 42195), 12659,
        "5:00 /km over a marathon is 3:30:59");
    Test.assertEqualMessage(RaceSetup.paceSecFor(12659, 42195), 300,
        "3:30:59 over a marathon is 5:00 /km");
    Test.assertEqualMessage(RaceSetup.paceSecFor(RaceSetup.timeSecFor(285, 21098), 21098),
        285, "a pace -> time -> pace round trip did not come back");

    // Hostile inputs: a zero distance must not reach either divide.
    Test.assertEqualMessage(RaceSetup.timeSecFor(300, 0), RaceSetup.MIN_TIME_SEC,
        "a zero distance divided into the goal time");
    Test.assertEqualMessage(RaceSetup.paceSecFor(12000, 0), RaceSetup.DEFAULT_PACE_SEC,
        "a zero distance divided into the goal pace");

    // ...and the clamps hold from both ends.
    Test.assertEqualMessage(RaceSetup.clampPaceSec(30), RaceSetup.MIN_PACE_SEC, "pace floor");
    Test.assertEqualMessage(RaceSetup.clampPaceSec(9999), RaceSetup.MAX_PACE_SEC, "pace ceiling");
    Test.assertEqualMessage(RaceSetup.clampDistanceM(0), RaceSetup.MIN_DIST_M, "distance floor");
    Test.assertEqualMessage(RaceSetup.clampDistanceM(999999), RaceSetup.MAX_DIST_M, "distance ceiling");
    Test.assertEqualMessage(RaceSetup.timeSecFor(900, 200000), RaceSetup.MAX_TIME_SEC,
        "the goal time escaped the 24 h ceiling the finish formatter relies on");

    // A step is always clamped, so the adjuster can never hold a bad value.
    Test.assertEqualMessage(
        RaceSetup.fieldStep(RaceSetup.FIELD_PACE, RaceSetup.MIN_PACE_SEC, -1),
        RaceSetup.MIN_PACE_SEC, "stepping down past the pace floor");
    Test.assertEqualMessage(
        RaceSetup.fieldStep(RaceSetup.FIELD_DISTANCE, 42195, 1),
        42195 + RaceSetup.DIST_STEP_M, "a distance step is not one step");

    // The goal time starts out derived (3:30:59 for 5:00 /km over a marathon),
    // so its step has to snap to whole minutes instead of carrying the seconds.
    Test.assertEqualMessage(RaceSetup.fieldStep(RaceSetup.FIELD_TIME, 12659, -1),
        12600, "stepping down from 3:30:59 must land on 3:30:00");
    Test.assertEqualMessage(RaceSetup.fieldStep(RaceSetup.FIELD_TIME, 12659, 1),
        12660, "stepping up from 3:30:59 must land on 3:31:00");
    Test.assertEqualMessage(RaceSetup.fieldStep(RaceSetup.FIELD_TIME, 12600, -1),
        12540, "a whole minute must still step a whole minute down");
    return true;
}

// The whole point of putting the targets on the watch: a change made on the
// start line, after the field is already running, has to reach it.  The engine
// picks it up at the next heavy refresh (10 s) without the activity restarting.
(:test)
function testTargetChangedOnTheWatchTakesEffectMidRace(logger as Test.Logger) as Boolean {
    var savedPace = RaceSetup.paceSec();
    var savedDist = RaceSetup.distanceM();

    var sim = new RaceSim();
    sim.run(60, 300.0, 150, 2);

    // The runner switches from the marathon to the half, 30 s/km quicker.
    RaceSetup.setDistanceM(21098);
    RaceSetup.setPaceSec(270);
    sim.run(15, 300.0, 150, 2);        // one heavy refresh is 10 s

    // Capture before restoring, so a failing assertion cannot leave the
    // simulator's stored settings pointing at a half marathon.
    var cfg        = sim.engine.config;
    var gotPace    = cfg.targetPaceSec;
    var gotDistKm  = cfg.raceDistanceKm;
    var gotTime    = cfg.targetTimeSec;
    var gotRemain  = sim.engine.paceLogic.remainingKm;

    RaceSetup.setPaceSec(savedPace);
    RaceSetup.setDistanceM(savedDist);
    RaceSetup.dirty = false;

    logger.debug("mid-race target: " + gotDistKm + " km at " + gotPace +
                 " s/km -> " + gotTime + " s");

    Test.assertEqualMessage(gotPace, 270.0,
        "a target pace set on the watch never reached the field: " + gotPace);
    Test.assertMessage(nearly(gotDistKm, 21.098),
        "a race distance set on the watch never reached the field: " + gotDistKm);
    Test.assertEqualMessage(gotTime, RaceSetup.timeSecFor(270, 21098),
        "the goal time was not re-derived from the new pace and distance");
    Test.assertMessage(gotRemain < 21.098,
        "the remaining distance did not move onto the new race: " + gotRemain);
    return true;
}

// The heavy tier re-reads the targets every 10 s.  It must only *apply* them
// when a stored value really moved — otherwise it would quietly revert anything
// held on a config instance, which is exactly what RaceSim and the layout
// preview do.
(:test)
function testTheSettingsPollOnlyActsOnRealChanges(logger as Test.Logger) as Boolean {
    var sim = new RaceSim();
    sim.engine.config.targetPaceSec = 333.0;    // nothing stored says 333

    sim.run(120, 300.0, 150, 2);                // a dozen heavy refreshes

    Test.assertEqualMessage(sim.engine.config.targetPaceSec, 333.0,
        "the settings poll reverted a value nothing had changed");
    return true;
}

// === 7. the on-watch settings menu =========================================

// The settings UI cannot be reached from a test the way the system reaches it
// (it pushes the views itself, from the activity menu), but everything that can
// go wrong before that can: building the menu, stepping a value to its bounds,
// writing it back, and drawing the adjuster.  Rendering into a buffered bitmap
// gives a real Dc, so a bad font or a bad primitive fails here rather than on
// the wrist.
(:test)
function testTheSettingsMenuBuildsAndDraws(logger as Test.Logger) as Boolean {
    var savedPace = RaceSetup.paceSec();

    // Building it exercises MenuItem, setSubLabel and the derived time line.
    var menu = new RaceSettingsMenu();
    Test.assertEqualMessage(menu.getItem(0).getLabel(), "Distance",
        "the first setting is not the race distance");
    Test.assertEqualMessage(menu.timeItem.getSubLabel(),
        RaceSetup.formatTime(RaceSetup.targetTimeSec()),
        "the goal time line does not match the stored pace and distance");
    new RaceDistanceMenu();

    // Draw every adjuster into a real Dc.
    var buffer = Graphics.createBufferedBitmap({:width => 416, :height => 416});
    var dc     = (buffer.get() as Graphics.BufferedBitmap).getDc();
    var fields = [RaceSetup.FIELD_DISTANCE, RaceSetup.FIELD_PACE,
                  RaceSetup.FIELD_TIME, RaceSetup.FIELD_TOLERANCE] as Array<Number>;
    for (var i = 0; i < fields.size(); i += 1) {
        var view = new RaceAdjustView(fields[i] as Number);
        view.change(1);
        view.change(-1);
        view.onUpdate(dc);
        logger.debug(RaceSetup.fieldTitle(fields[i] as Number) + " -> " +
                     RaceSetup.fieldText(fields[i] as Number, view.value));
    }

    // Holding a key down must run into the clamp, not out of it.
    var paceView = new RaceAdjustView(RaceSetup.FIELD_PACE);
    for (var i = 0; i < 400; i += 1) { paceView.change(-1); }
    Test.assertEqualMessage(paceView.value, RaceSetup.MIN_PACE_SEC,
        "scrolling down ran past the pace floor: " + paceView.value);
    for (var i = 0; i < 400; i += 1) { paceView.change(1); }
    Test.assertEqualMessage(paceView.value, RaceSetup.MAX_PACE_SEC,
        "scrolling up ran past the pace ceiling: " + paceView.value);

    // Confirming an edited goal time has to come back out as a pace.
    var timeView = new RaceAdjustView(RaceSetup.FIELD_TIME);
    timeView.change(1);                      // one minute slower
    var wantedTime = timeView.value;
    timeView.save();
    var gotPace = RaceSetup.paceSec();
    RaceSetup.setPaceSec(savedPace);
    RaceSetup.dirty = false;

    Test.assertEqualMessage(gotPace,
        RaceSetup.paceSecFor(wantedTime, RaceSetup.distanceM()),
        "confirming a goal time did not store the pace that produces it");
    return true;
}

// Float comparison for distances: 42.195 km never survives a round trip
// through a division exactly, and a test that demands it would only ever be
// measuring the arithmetic.
function nearly(actual as Float, expected as Float) as Boolean {
    var delta = actual - expected;
    if (delta < 0.0) { delta = -delta; }
    return delta < 0.001;
}
