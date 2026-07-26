import Toybox.Lang;

// ---------------------------------------------------------------------------
// RacePaceLogic  –  all pace / distance / lap calculations
// ---------------------------------------------------------------------------
// BUG FIX: updateInstantPace() previously wrote smoothedPaceSec = instantPaceSec
// on every compute() call (which fires multiple times per second), completely
// overwriting the rolling-average that addPaceSample() had just built once per
// second.  Now smoothedPaceSec is ONLY written inside addPaceSample().
// ---------------------------------------------------------------------------

class RacePaceLogic {

    var config;

    // --- live values updated every compute() ---
    var elapsedSec      = 0;
    var distanceKm      = 0.0;
    var remainingKm     = 42.195;
    // Real remaining distance along a loaded course (km), 0 = no course active.
    // Set by the view from Activity.Info.distanceToDestination each compute().
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
    // -----------------------------------------------------------------------
    function updateAveragePace(averageSpeed) as Void {
        if (averageSpeed != null && averageSpeed > 0.25) {
            averagePaceSec = 1000.0 / averageSpeed;
        } else if (distanceKm > 0.01 && elapsedSec > 0) {
            averagePaceSec = elapsedSec.toFloat() / distanceKm;
        }
    }

    // -----------------------------------------------------------------------
    // Add one sample per second and compute the smoothed pace from the ring.
    // This is the ONLY function that writes smoothedPaceSec.
    // -----------------------------------------------------------------------
    function addPaceSample() as Void {
        if (instantPaceSec > 0.0 && instantPaceSec < 1200.0) {
            paceSamples.add(instantPaceSec);
            trimSamples(paceSamples, config.sampleWindowSec);
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
            projectedFinishSec = config.targetTimeSec;
        } else if (remainingKm <= 0.0) {
            projectedFinishSec = elapsedSec;
        } else {
            projectedFinishSec = elapsedSec + roundNumber(projectionPace * remainingKm);
        }

        lastHeavyUpdateSec = elapsedSec;
    }

    // -----------------------------------------------------------------------
    // Auto-lap: trigger once every full kilometre
    // -----------------------------------------------------------------------
    function updateAutoLap() as Void {
        while (distanceKm >= nextAutoLapKm) {
            setLapAnchor(nextAutoLapKm,
                         estimateElapsedAtDistance(nextAutoLapKm));
            nextAutoLapKm += 1.0;
        }
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

    // Linear interpolation: find elapsed time at a past distance crossing
    function estimateElapsedAtDistance(targetKm as Float) as Float {
        var span = distanceKm - prevDistanceKm;
        if (span > 0.0 &&
            targetKm >= prevDistanceKm &&
            targetKm <= distanceKm) {
            var ratio = (targetKm - prevDistanceKm) / span;
            return prevElapsedSec.toFloat() +
                   ((elapsedSec - prevElapsedSec).toFloat() * ratio);
        }
        var refPace = smoothedPaceSec > 0.0 ? smoothedPaceSec : averagePaceSec;
        if (refPace <= 0.0) { return elapsedSec.toFloat(); }
        return elapsedSec.toFloat() - ((distanceKm - targetKm) * refPace);
    }

    // Negative = faster than target (green), positive = slower (red)
    function deltaToTargetSec() as Float {
        if (smoothedPaceSec <= 0.0) { return 0.0; }
        return smoothedPaceSec - config.targetPaceSec;
    }

    // -----------------------------------------------------------------------
    // Shared helpers
    // -----------------------------------------------------------------------
    function trimSamples(samples as Array<Numeric>, maxCount as Number) as Void {
        while (samples.size() > maxCount) { samples.remove(0); }
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
