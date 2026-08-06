import Toybox.Lang;

// ---------------------------------------------------------------------------
// RacePaceLogic  –  all pace / distance / lap calculations
// ---------------------------------------------------------------------------
// BUG FIX: updateInstantPace() previously wrote smoothedPaceSec = instantPaceSec
// on every compute() call (which fires multiple times per second), completely
// overwriting the rolling-average that addPaceSample() had just built once per
// second.  Now smoothedPaceSec is ONLY written inside addPaceSample().
//
// CRASH FIX (watchdog kill mid-run): see trimSamples() — the ring buffer never
// actually shrank, so the trim loop spun forever once the buffer filled up.
// ---------------------------------------------------------------------------

class RacePaceLogic {

    // Trimming reallocates, so let the buffer overshoot by this much and cut it
    // back in one go: one reallocation every ~32 s instead of one every second.
    // averageRange() indexes from the end, so the overshoot is harmless.
    const TRIM_SLACK = 32;

    // Minimum distance since the lap anchor before a lap pace means anything.
    const MIN_LAP_DISTANCE_KM = 0.03;

    // Every pace in this class is bounded by these: 1200 s/km is 20 min/km,
    // i.e. slower than walking, and 24 h caps the finish projection.  Nothing
    // unbounded may reach a .toNumber(), which silently wraps past 2^31.
    const MAX_PACE_SEC   = 1200.0;
    const MAX_FINISH_SEC = 86400;

    var config;

    // --- live values updated every compute() ---
    var elapsedSec      = 0;     // activity TIMER seconds (frozen while paused)
    var distanceKm      = 0.0;
    // What is still to run (km).  This is the number on the face next to the
    // distance covered, and the one the finish projection multiplies out.
    var remainingKm     = 42.195;
    // Real remaining distance along a loaded course (km), 0 = no course active.
    // Set by the engine from Activity.Info.distanceToDestination each compute().
    // PacePro's target pace is NOT exposed by Connect IQ, but the loaded route
    // is — so when navigating we take the true remaining distance from it.
    var courseRemainingKm = 0.0;
    var instantPaceSec  = 0.0;   // raw GPS pace – noisy, do NOT display directly
    var smoothedPaceSec = 0.0;   // rolling-average over config.smoothWindowSec samples

    // --- heavy-update values (every 10 s) ---
    var averagePaceSec      = 0.0;
    var rolling5MinPaceSec  = 0.0;
    var projectedFinishSec  = 0;

    // --- lap ---
    var lapAnchorDistanceKm = 0.0;
    var lapAnchorElapsedSec = 0.0;
    var nextAutoLapKm       = 1.0;
    var lastLapResetSec     = 0;

    // --- internal ---
    var prevDistanceKm     = 0.0;
    var prevElapsedSec     = 0;
    var lastSampleSecond   = -1;
    var lastHeavyUpdateSec = -100;

    // pace sample ring-buffer: 1 entry/second of activity, capped at sampleWindowSec
    var paceSamples = [] as Array<Numeric>;

    function initialize(configRef) {
        config = configRef;
    }

    // -----------------------------------------------------------------------
    // Called every compute() cycle. Returns true once per elapsed second.
    // -----------------------------------------------------------------------
    function update(elapsedSeconds as Number,
                    distanceKilometers as Float,
                    currentSpeed,
                    averageSpeed) as Boolean {

        var isNewSecond = (elapsedSeconds != lastSampleSecond);

        if (isNewSecond) {
            prevElapsedSec = elapsedSec;
            prevDistanceKm = distanceKm;
        }

        elapsedSec  = elapsedSeconds;
        distanceKm  = distanceKilometers;
        if (courseRemainingKm > 0.0) {
            remainingKm = courseRemainingKm;          // true remaining on a route
        } else {
            remainingKm = config.raceDistanceKm - distanceKm;
            if (remainingKm < 0.0) { remainingKm = 0.0; }
        }

        // Raw GPS pace every cycle – does NOT touch smoothedPaceSec
        updateInstantPace(currentSpeed);

        if (isNewSecond) {
            updateAveragePace(averageSpeed);
            addPaceSample();     // <-- only place that writes smoothedPaceSec
            updateAutoLap();
            lastSampleSecond = elapsedSec;
        }

        return isNewSecond;
    }

    // -----------------------------------------------------------------------
    // Stores the instantaneous GPS pace.  Does NOT update smoothedPaceSec.
    // -----------------------------------------------------------------------
    function updateInstantPace(currentSpeed) as Void {
        if (currentSpeed != null && currentSpeed > 0.25) {
            var raw = 1000.0 / currentSpeed;
            if (raw > 0.0 && raw < 1200.0) {
                instantPaceSec = raw;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Derive average pace from the device's averageSpeed field (most accurate).
    // Both branches are bounded by MAX_PACE_SEC, the same sanity limit the
    // instant pace uses.  Without it a crawl produces absurd values — 0.26 m/s
    // gives 3846 s/km, and the distance fallback at 20 m after 20 minutes gives
    // 60000 s/km — which then flowed straight into the finish projection.
    // -----------------------------------------------------------------------
    function updateAveragePace(averageSpeed) as Void {
        var pace = 0.0;
        if (averageSpeed != null && averageSpeed > 0.25) {
            pace = 1000.0 / averageSpeed;
        } else if (distanceKm > 0.01 && elapsedSec > 0) {
            pace = elapsedSec.toFloat() / distanceKm;
        }
        if (pace > 0.0 && pace < MAX_PACE_SEC) {
            averagePaceSec = pace;
        }
    }

    // -----------------------------------------------------------------------
    // Add one sample per second and compute the smoothed pace from the ring.
    // This is the ONLY function that writes smoothedPaceSec.
    // -----------------------------------------------------------------------
    function addPaceSample() as Void {
        if (instantPaceSec > 0.0 && instantPaceSec < 1200.0) {
            paceSamples.add(instantPaceSec);
            paceSamples = trimSamples(paceSamples, config.sampleWindowSec);
        }

        var avg = averageLast(paceSamples, config.smoothWindowSec);
        if (avg > 0.0) {
            smoothedPaceSec = avg;
        } else if (averagePaceSec > 0.0) {
            // Fallback during the first few seconds before samples accumulate
            smoothedPaceSec = averagePaceSec;
        }
    }

    // -----------------------------------------------------------------------
    // Heavy refresh – called every config.heavyUpdateSec (default 10 s)
    // -----------------------------------------------------------------------
    function isHeavyRefreshDue() as Boolean {
        // A backwards clock (timer reset, bad reading) must not wedge the heavy
        // tier off forever, so treat it as immediately due.
        if (elapsedSec < lastHeavyUpdateSec) { return true; }
        return (elapsedSec - lastHeavyUpdateSec) >= config.heavyUpdateSec;
    }

    function refreshHeavy() as Void {
        rolling5MinPaceSec = averageLast(paceSamples, config.rollingWindowSec);

        // Projected finish: 70 % rolling pace + 30 % overall average pace
        var projectionPace = config.targetPaceSec;
        if (rolling5MinPaceSec > 0.0 && averagePaceSec > 0.0) {
            projectionPace = (rolling5MinPaceSec * 0.7) + (averagePaceSec * 0.3);
        } else if (rolling5MinPaceSec > 0.0) {
            projectionPace = rolling5MinPaceSec;
        } else if (averagePaceSec > 0.0) {
            projectionPace = averagePaceSec;
        }

        if (distanceKm <= 0.05) {
            projectedFinishSec = effectiveTargetTimeSec();
        } else if (remainingKm <= 0.0) {
            projectedFinishSec = elapsedSec;
        } else {
            projectedFinishSec = elapsedSec + roundNumber(projectionPace * remainingKm);
        }
        // Bounded so the h:mm formatter can never be handed something that
        // overflows when it adds its rounding offset.
        if (projectedFinishSec < 0)               { projectedFinishSec = 0; }
        if (projectedFinishSec > MAX_FINISH_SEC)  { projectedFinishSec = MAX_FINISH_SEC; }

        lastHeavyUpdateSec = elapsedSec;
    }

    // -----------------------------------------------------------------------
    // Auto-lap: anchor on every full kilometre.
    // Deliberately O(1): a GPS re-acquire after a tunnel can add several km in
    // one sample, and only the most recent crossing matters for the anchor —
    // looping through each skipped kilometre would put an unbounded loop inside
    // compute(), which is exactly the class of bug that killed the field.
    // -----------------------------------------------------------------------
    function updateAutoLap() as Void {
        if (distanceKm < nextAutoLapKm) { return; }

        var lastCrossedKm = distanceKm.toNumber().toFloat();   // floor, distance >= 0
        if (lastCrossedKm < nextAutoLapKm) { lastCrossedKm = nextAutoLapKm; }

        setLapAnchor(lastCrossedKm, estimateElapsedAtDistance(lastCrossedKm));
        nextAutoLapKm = lastCrossedKm + 1.0;
    }

    // -----------------------------------------------------------------------
    // Manual lap: snap to nearest km if within config.lapSnapMeters
    // -----------------------------------------------------------------------
    function handleLapTrigger() as Void {
        var snappedDist    = distanceKm;
        var snappedElapsed = elapsedSec.toFloat();
        var nearestKm      = roundNumber(distanceKm);
        var deltaMeters    = absoluteFloat(distanceKm - nearestKm.toFloat()) * 1000.0;

        if (nearestKm > lapAnchorDistanceKm &&
            deltaMeters <= config.lapSnapMeters) {
            snappedDist    = nearestKm.toFloat();
            snappedElapsed = estimateElapsedAtDistance(snappedDist);
        }

        setLapAnchor(snappedDist, snappedElapsed);
        nextAutoLapKm = snappedDist.toNumber() + 1.0;
        if (nextAutoLapKm <= snappedDist) {
            nextAutoLapKm = snappedDist + 1.0;
        }
    }

    function setLapAnchor(anchorDist as Float, anchorElapsed as Float) as Void {
        lapAnchorDistanceKm = anchorDist;
        lapAnchorElapsedSec = anchorElapsed;
        lastLapResetSec     = anchorElapsed.toNumber();
    }

    // Linear interpolation: find elapsed time at a past distance crossing.
    // Always clamped into [0, elapsedSec] — an extrapolation from a stale pace
    // can otherwise land far in the past or the future and poison drift resets.
    function estimateElapsedAtDistance(targetKm as Float) as Float {
        var span = distanceKm - prevDistanceKm;
        if (span > 0.0 &&
            targetKm >= prevDistanceKm &&
            targetKm <= distanceKm) {
            var ratio = (targetKm - prevDistanceKm) / span;
            return clampElapsed(prevElapsedSec.toFloat() +
                                ((elapsedSec - prevElapsedSec).toFloat() * ratio));
        }
        var refPace = smoothedPaceSec > 0.0 ? smoothedPaceSec : averagePaceSec;
        if (refPace <= 0.0) { return elapsedSec.toFloat(); }
        return clampElapsed(elapsedSec.toFloat() -
                            ((distanceKm - targetKm) * refPace));
    }

    function clampElapsed(value as Float) as Float {
        if (!(value > 0.0))               { return 0.0; }   // also catches NaN
        if (value > elapsedSec.toFloat()) { return elapsedSec.toFloat(); }
        return value;
    }

    // Pace over the current lap.  Auto-lap anchors on every full kilometre, so
    // this is the running split for the kilometre you are in.  Returns 0 for
    // "nothing to say yet": right after an anchor there is not enough distance
    // to divide by, and the first few metres would otherwise throw out a wild
    // number for a second or two on every single kilometre.
    function lapPaceSec() as Float {
        var distDelta = distanceKm - lapAnchorDistanceKm;
        var timeDelta = elapsedSec.toFloat() - lapAnchorElapsedSec;
        if (distDelta < MIN_LAP_DISTANCE_KM || timeDelta <= 0.0) { return 0.0; }
        var pace = timeDelta / distDelta;
        if (!(pace > 0.0) || pace > 1200.0) { return 0.0; }
        return pace;
    }

    // -----------------------------------------------------------------------
    // How long the race actually is today
    // -----------------------------------------------------------------------
    // A loaded course outranks the configured distance: on the day, the route
    // in the watch is the truth, and it is the only way Connect IQ lets a data
    // field learn the real course length (PacePro's target pace is not exposed,
    // but Activity.Info.distanceToDestination is).  Without one, this is the
    // distance set on the phone or on the wrist.
    //
    // Everything that divides by "the race" divides by this — the progress arc,
    // the reserve estimate and the target time — so a 42.4 km measured course
    // moves all three together rather than only the remaining-distance readout.
    function effectiveRaceDistanceKm() as Float {
        if (courseRemainingKm > 0.0) {
            var total = distanceKm + courseRemainingKm;
            if (total > 0.0) { return total; }
        }
        return config.raceDistanceKm;
    }

    // The goal time, re-derived from the target pace over whatever distance is
    // actually being run.  Not a stored setting: pace and distance are both
    // editable mid-race now, and a separately stored time would start
    // contradicting them the moment either one moved.
    function effectiveTargetTimeSec() as Number {
        var total = effectiveRaceDistanceKm();
        if (!(total > 0.0)) { return config.targetTimeSec; }
        return RaceSetup.clampTimeSec(roundNumber(config.targetPaceSec * total));
    }

    // Fraction of the race completed, 0.0 .. 1.0 — drives the progress arc.
    // Guards the divide: the distance comes from a setting or a course, and a
    // zero from either must not be able to reach the drawing code.
    function raceProgress() as Float {
        var total = effectiveRaceDistanceKm();
        if (!(total > 0.0)) { return 0.0; }
        var p = distanceKm / total;
        if (!(p > 0.0)) { return 0.0; }
        if (p > 1.0)    { return 1.0; }
        return p;
    }

    // -----------------------------------------------------------------------
    // Pace status against the target — the single status axis on the face now
    // that the separate delta field is gone.
    //   -1 = faster than target · 0 = inside tolerance · +1 = slower than target
    // A missing reading returns 0 so the hero pace never flashes a false alarm.
    // -----------------------------------------------------------------------
    function paceStatus(paceSeconds as Float) as Number {
        if (!(paceSeconds > 0.0) || paceSeconds > 1200.0) { return 0; }
        var delta = paceSeconds - config.targetPaceSec;
        if (delta < -config.paceToleranceSec) { return -1; }
        if (delta >  config.paceToleranceSec) { return  1; }
        return 0;
    }

    // -----------------------------------------------------------------------
    // Shared helpers
    // -----------------------------------------------------------------------
    // CRASH FIX.  This used to be:
    //     while (samples.size() > maxCount) { samples.remove(0); }
    // Toybox.Lang.Array.remove() removes by VALUE, not by index — it looked for
    // an element equal to 0, never found one (every sample is > 0), returned
    // false and left the array untouched.  The loop therefore never terminated
    // once the buffer filled (~10 min of running at sampleWindowSec = 600):
    // compute() stopped returning, the field froze, and the watchdog killed it
    // and dropped it from the data screen.  slice() is the index-based cut.
    function trimSamples(samples as Array<Numeric>,
                         maxCount as Number) as Array<Numeric> {
        if (maxCount <= 0) { return [] as Array<Numeric>; }
        var n = samples.size();
        if (n <= maxCount + TRIM_SLACK) { return samples; }
        return samples.slice(n - maxCount, null) as Array<Numeric>;
    }

    function averageLast(samples as Array<Numeric>,
                         requestedCount as Number) as Float {
        return averageRange(samples, requestedCount, 0);
    }

    // averageRange is also called by RaceHeartRateLogic for drift detection
    function averageRange(samples as Array<Numeric>,
                          requestedCount as Number,
                          offsetFromEnd as Number) as Float {
        var n = samples.size();
        if (n <= 0 || requestedCount <= 0) { return 0.0; }

        var endIdx   = n - offsetFromEnd;
        if (endIdx < 0) { endIdx = 0; }
        var startIdx = endIdx - requestedCount;
        if (startIdx < 0) { startIdx = 0; }

        var sum   = 0.0;
        var count = 0;
        for (var i = startIdx; i < endIdx; i += 1) {
            sum   += samples[i].toFloat();
            count += 1;
        }
        return count > 0 ? sum / count.toFloat() : 0.0;
    }

    function roundNumber(value) as Number {
        if (value < 0) { return (value - 0.5).toNumber(); }
        return (value + 0.5).toNumber();
    }

    function absoluteFloat(value as Float) as Float {
        return value < 0.0 ? -value : value;
    }
}
