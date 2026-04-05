import Toybox.Lang;
import Toybox.SensorHistory;

// ---------------------------------------------------------------------------
// RaceHeartRateLogic  –  HR tracking, rolling average, drift detection
// ---------------------------------------------------------------------------
// FIX: Removed unreachable `instanceof Number` branch in loadHrZones caller.
//      All array accesses now have explicit `as Type` casts.
// ---------------------------------------------------------------------------

class RaceHeartRateLogic {

    var config;

    var currentHr     = 0;
    var averageHr     = 0.0;
    var rolling5MinHr = 0.0;

    var driftActive   = false;
    var driftDeltaBpm = 0;
    var driftResetSec = 0;

    var hrSamples      = [] as Array<Number>;
    var totalHr        = 0.0;
    var totalHrSamples = 0;
    var deviceAverageHr = 0;

    var lastHeavyUpdateSec = -100;

    function initialize(configRef) {
        config = configRef;
    }

    // -----------------------------------------------------------------------
    // Called every compute() cycle
    // -----------------------------------------------------------------------
    function update(info, isNewSecond as Boolean) as Void {
        if (info.currentHeartRate != null && info.currentHeartRate > 0) {
            currentHr = info.currentHeartRate as Number;
        }

        if (info.averageHeartRate != null && info.averageHeartRate > 0) {
            deviceAverageHr = info.averageHeartRate as Number;
            averageHr       = deviceAverageHr.toFloat();
        }

        if (isNewSecond && currentHr > 0) {
            hrSamples.add(currentHr);
            trimSamples(hrSamples, config.sampleWindowSec);
            totalHr        += currentHr.toFloat();
            totalHrSamples += 1;
        }

        if (deviceAverageHr <= 0 && totalHrSamples > 0) {
            averageHr = totalHr / totalHrSamples.toFloat();
        }
    }

    // -----------------------------------------------------------------------
    // Heavy refresh (every config.heavyUpdateSec seconds)
    // -----------------------------------------------------------------------
    function refreshHeavy(paceLogic as RacePaceLogic) as Void {
        var historyHr = getHistoryRollingHr(config.rollingWindowSec);
        if (historyHr > 0.0) {
            rolling5MinHr = historyHr;
        } else {
            rolling5MinHr = averageRange(hrSamples, config.rollingWindowSec, 0);
        }

        if (deviceAverageHr <= 0 && totalHrSamples > 0) {
            averageHr = totalHr / totalHrSamples.toFloat();
        }

        evaluateDrift(paceLogic);
        lastHeavyUpdateSec = paceLogic.elapsedSec;
    }

    // -----------------------------------------------------------------------
    // SensorHistory-based rolling HR average
    // -----------------------------------------------------------------------
    function getHistoryRollingHr(periodSeconds as Number) as Float {
        try {
            var iterator = SensorHistory.getHeartRateHistory({
                :period => periodSeconds,
                :order  => SensorHistory.ORDER_NEWEST_FIRST
            });
            // No null-check needed: getHeartRateHistory() always returns a
            // valid iterator or throws – a null return is not possible.
            var sum    = 0.0;
            var count  = 0;
            var sample = iterator.next();
            while (sample != null) {
                if (sample.data != null && sample.data > 0) {
                    sum   += (sample.data as Number).toFloat();
                    count += 1;
                }
                sample = iterator.next();
            }
            return count > 0 ? sum / count.toFloat() : 0.0;
        } catch (e) {
            return 0.0;
        }
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
    function trimSamples(samples as Array<Number>, maxCount as Number) as Void {
        while (samples.size() > maxCount) { samples.remove(0); }
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
