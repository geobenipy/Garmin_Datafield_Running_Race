import Toybox.Lang;

class RaceHeartRateLogic {

    var config;
    var currentHr = 0;
    var averageHr = 0.0;
    var rolling5MinHr = 0.0;
    var driftActive = false;
    var driftDeltaBpm = 0;
    var driftResetSec = 0;
    var lastHeavyUpdateSec = -100;
    var deviceAverageHr = 0;
    var totalHr = 0.0;
    var totalHrSamples = 0;

    var hrSamples = [] as Array<Numeric>;

    function initialize(configRef) {
        config = configRef;
    }

    function update(info, isNewSecond as Boolean) as Void {
        if (info.currentHeartRate != null) {
            currentHr = info.currentHeartRate;
        }

        if (info.averageHeartRate != null && info.averageHeartRate > 0) {
            deviceAverageHr = info.averageHeartRate;
            averageHr = info.averageHeartRate.toFloat();
        }

        if (isNewSecond && currentHr > 0) {
            hrSamples.add(currentHr);
            trimSamples(hrSamples, config.sampleWindowSec);
            totalHr += currentHr.toFloat();
            totalHrSamples += 1;
        }

        if (deviceAverageHr <= 0 && totalHrSamples > 0) {
            averageHr = totalHr / totalHrSamples.toFloat();
        }
    }

    function trimSamples(samples as Array<Numeric>, maxCount as Number) as Void {
        while (samples.size() > maxCount) {
            samples.remove(0);
        }
    }

    function averageRange(samples as Array<Numeric>, requestedCount as Number, offsetFromEnd as Number) as Float {
        var sampleCount = samples.size();
        if (sampleCount <= 0 || requestedCount <= 0) {
            return 0.0;
        }

        var endIndex = sampleCount - offsetFromEnd;
        if (endIndex < 0) {
            endIndex = 0;
        }

        var startIndex = endIndex - requestedCount;
        if (startIndex < 0) {
            startIndex = 0;
        }

        var sum = 0.0;
        var count = 0;
        for (var i = startIndex; i < endIndex; i += 1) {
            sum += samples[i].toFloat();
            count += 1;
        }

        if (count <= 0) {
            return 0.0;
        }

        return sum / count.toFloat();
    }

    function refreshHeavy(paceLogic as RacePaceLogic) as Void {
        rolling5MinHr = averageRange(hrSamples, config.rollingWindowSec, 0);
        if (deviceAverageHr <= 0 && totalHrSamples > 0) {
            averageHr = totalHr / totalHrSamples.toFloat();
        }

        evaluateDrift(paceLogic);
        lastHeavyUpdateSec = paceLogic.elapsedSec;
    }

    function evaluateDrift(paceLogic as RacePaceLogic) as Void {
        if (paceLogic.elapsedSec - driftResetSec < (config.rollingWindowSec * 2)) {
            driftActive = false;
            driftDeltaBpm = 0;
            return;
        }

        var currentPaceWindow = paceLogic.averageRange(paceLogic.paceSamples, config.rollingWindowSec, 0);
        var previousPaceWindow = paceLogic.averageRange(paceLogic.paceSamples, config.rollingWindowSec, config.rollingWindowSec);
        var currentHrWindow = averageRange(hrSamples, config.rollingWindowSec, 0);
        var previousHrWindow = averageRange(hrSamples, config.rollingWindowSec, config.rollingWindowSec);

        if (currentPaceWindow <= 0.0 || previousPaceWindow <= 0.0 || currentHrWindow <= 0.0 || previousHrWindow <= 0.0) {
            driftActive = false;
            driftDeltaBpm = 0;
            return;
        }

        var paceDelta = currentPaceWindow - previousPaceWindow;
        if (paceDelta < 0.0) {
            paceDelta = -paceDelta;
        }

        var hrDelta = currentHrWindow - previousHrWindow;
        driftActive = paceDelta <= config.driftPaceStableSec && hrDelta >= config.driftHrDeltaBpm;
        if (driftActive) {
            driftDeltaBpm = roundNumber(hrDelta);
        } else {
            driftDeltaBpm = 0;
        }
    }

    function resetDrift(resetAtSec as Number) as Void {
        driftResetSec = resetAtSec;
        driftActive = false;
        driftDeltaBpm = 0;
    }

    function zoneIndex() as Number {
        if (currentHr <= 0) {
            return 0;
        } else if (currentHr <= config.hrZones[0]) {
            return 1;
        } else if (currentHr <= config.hrZones[1]) {
            return 2;
        } else if (currentHr <= config.hrZones[2]) {
            return 3;
        } else if (currentHr <= config.hrZones[3]) {
            return 4;
        }
        return 5;
    }

    function roundNumber(value as Float) as Number {
        if (value < 0.0) {
            return (value - 0.5).toNumber();
        }
        return (value + 0.5).toNumber();
    }
}
