import Toybox.Lang;

// ---------------------------------------------------------------------------
// RaceHeartRateLogic  –  HR tracking, rolling average, drift detection
// ---------------------------------------------------------------------------
// FIX: Removed unreachable `instanceof Number` branch in loadHrZones caller.
//      All array accesses now have explicit `as Type` casts.
//
// CRASH FIX: trimSamples() had the same never-terminating loop as the one in
//      RacePaceLogic — see the comment on trimSamples() down below.
// ---------------------------------------------------------------------------

class RaceHeartRateLogic {

    // See RacePaceLogic.TRIM_SLACK
    const TRIM_SLACK = 32;

    var config;

    var currentHr     = 0;
    var rolling5MinHr = 0.0;

    var driftActive   = false;
    var driftDeltaBpm = 0;
    var driftResetSec = 0;

    var hrSamples      = [] as Array<Number>;

    var lastHeavyUpdateSec = -100;

    function initialize(configRef) {
        config = configRef;
    }

    // -----------------------------------------------------------------------
    // Called every compute() cycle.  Takes the raw bpm reading (may be null)
    // rather than an Activity.Info, so the whole update path is testable.
    // -----------------------------------------------------------------------
    function update(heartRate, isNewSecond as Boolean) as Void {
        if (heartRate != null && heartRate > 0 && heartRate < 300) {
            currentHr = heartRate.toNumber();
        }

        if (isNewSecond && currentHr > 0) {
            hrSamples.add(currentHr);
            hrSamples = trimSamples(hrSamples, config.sampleWindowSec);
        }
    }

    // -----------------------------------------------------------------------
    // Heavy refresh (every config.heavyUpdateSec seconds)
    // -----------------------------------------------------------------------
    // The rolling average comes from this class's own 1 Hz ring buffer, which
    // is a true rolling `rollingWindowSec` of the *current activity*.
    //
    // It used to come from SensorHistory.getHeartRateHistory({:period => 300}).
    // That was wrong: a Number :period means "the last 300 ENTRIES", not 300
    // seconds, and the watch writes HR history only every minute or two — so it
    // was averaging hours of history including resting HR.  rolling5MinHr came
    // out far below the running HR, which pinned the drift arrow to "rising"
    // for the whole race and made RaceReserveLogic read the effort as easier
    // than it was.  Dropping it also takes an iterator loop and a permission
    // out of the heavy tier.
    // -----------------------------------------------------------------------
    function refreshHeavy(paceLogic as RacePaceLogic) as Void {
        rolling5MinHr = averageRange(hrSamples, config.rollingWindowSec, 0);
        evaluateDrift(paceLogic);
        lastHeavyUpdateSec = paceLogic.elapsedSec;
    }

    // -----------------------------------------------------------------------
    // HR drift detection
    // -----------------------------------------------------------------------
    function evaluateDrift(paceLogic as RacePaceLogic) as Void {
        if (paceLogic.elapsedSec - driftResetSec <
                (config.rollingWindowSec * 2)) {
            driftActive   = false;
            driftDeltaBpm = 0;
            return;
        }

        var curPace  = paceLogic.averageRange(
                           paceLogic.paceSamples, config.rollingWindowSec, 0);
        var prevPace = paceLogic.averageRange(
                           paceLogic.paceSamples,
                           config.rollingWindowSec,
                           config.rollingWindowSec);
        var curHr    = averageRange(hrSamples, config.rollingWindowSec, 0);
        var prevHr   = averageRange(hrSamples, config.rollingWindowSec,
                                    config.rollingWindowSec);

        if (curPace <= 0.0 || prevPace <= 0.0 ||
            curHr  <= 0.0 || prevHr  <= 0.0) {
            driftActive   = false;
            driftDeltaBpm = 0;
            return;
        }

        var paceDelta = curPace - prevPace;
        if (paceDelta < 0.0) { paceDelta = -paceDelta; }

        var hrDelta  = curHr - prevHr;
        driftActive  = (paceDelta <= config.driftPaceStableSec) &&
                       (hrDelta   >= config.driftHrDeltaBpm);
        driftDeltaBpm = driftActive ? roundNumber(hrDelta) : 0;
    }

    function resetDrift(resetAtSec as Number) as Void {
        driftResetSec = resetAtSec;
        driftActive   = false;
        driftDeltaBpm = 0;
    }

    // Zone index 1–5 for current HR
    function zoneIndex() as Number {
        var zones = config.hrZones as Array<Number>;
        if (currentHr <= 0)              { return 0; }
        if (currentHr <= zones[0])       { return 1; }
        if (currentHr <= zones[1])       { return 2; }
        if (currentHr <= zones[2])       { return 3; }
        if (currentHr <= zones[3])       { return 4; }
        return 5;
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------
    // CRASH FIX — identical to RacePaceLogic.trimSamples().  The old
    //     while (samples.size() > maxCount) { samples.remove(0); }
    // never terminated: Array.remove() removes by VALUE, and no HR sample is
    // ever 0, so the array never shrank and compute() hung until the watchdog
    // killed the field.  slice() is the index-based cut.
    function trimSamples(samples as Array<Number>,
                         maxCount as Number) as Array<Number> {
        if (maxCount <= 0) { return [] as Array<Number>; }
        var n = samples.size();
        if (n <= maxCount + TRIM_SLACK) { return samples; }
        return samples.slice(n - maxCount, null) as Array<Number>;
    }

    // FIX: explicit `as Number` cast on array element access eliminates
    //      "Cannot determine if container access is using container type" warnings
    function averageRange(samples as Array<Number>,
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
            sum   += (samples[i] as Number).toFloat();
            count += 1;
        }
        return count > 0 ? sum / count.toFloat() : 0.0;
    }

    function roundNumber(value as Float) as Number {
        if (value < 0.0) { return (value - 0.5).toNumber(); }
        return (value + 0.5).toNumber();
    }
}
