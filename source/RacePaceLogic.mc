import Toybox.Lang;

class RacePaceLogic {

    var config;
    var elapsedSec = 0;
    var distanceKm = 0.0;
    var remainingKm = 42.195;
    var instantPaceSec = 0.0;
    var smoothedPaceSec = 0.0;
    var averagePaceSec = 0.0;
    var rolling5MinPaceSec = 0.0;
    var projectedFinishSec = 0;
    var lapPaceSec = 0.0;
    var lapAnchorDistanceKm = 0.0;
    var lapAnchorElapsedSec = 0.0;
    var nextAutoLapKm = 1.0;
    var prevDistanceKm = 0.0;
    var prevElapsedSec = 0;
    var lastSampleSecond = -1;
    var lastHeavyUpdateSec = -100;
    var lastLapResetSec = 0;
    var lapVersion = 0;

    var paceSamples = [] as Array<Numeric>;

    function initialize(configRef) {
        config = configRef;
    }

    function update(elapsedSeconds as Number, distanceKilometers as Float, currentSpeed, averageSpeed) as Boolean {
        var isNewSecond = elapsedSeconds != lastSampleSecond;

        if (isNewSecond) {
            prevElapsedSec = elapsedSec;
            prevDistanceKm = distanceKm;
        }

        elapsedSec = elapsedSeconds;
        distanceKm = distanceKilometers;
        remainingKm = config.raceDistanceKm - distanceKm;
        if (remainingKm < 0.0) {
            remainingKm = 0.0;
        }

        updateInstantPace(currentSpeed);
        updateAveragePace(averageSpeed);

        if (isNewSecond) {
            addPaceSample();
            updateAutoLap();
            updateLapPace();
            lastSampleSecond = elapsedSec;
        }

        return isNewSecond;
    }

    function updateInstantPace(currentSpeed) as Void {
        if (currentSpeed != null && currentSpeed > 0.25) {
            instantPaceSec = 1000.0 / currentSpeed;
            if (instantPaceSec > 0.0 && instantPaceSec < 1200.0) {
                smoothedPaceSec = instantPaceSec;
            }
        }
    }

    function updateAveragePace(averageSpeed) as Void {
        if (averageSpeed != null && averageSpeed > 0.25) {
            averagePaceSec = 1000.0 / averageSpeed;
        } else if (distanceKm > 0.01 && elapsedSec > 0) {
            averagePaceSec = elapsedSec.toFloat() / distanceKm;
        }
    }

    function addPaceSample() as Void {
        if (instantPaceSec > 0.0 && instantPaceSec < 1200.0) {
            paceSamples.add(instantPaceSec);
            trimSamples(paceSamples, config.sampleWindowSec);
            smoothedPaceSec = averageLast(paceSamples, config.smoothWindowSec);
        }
    }

    function trimSamples(samples as Array<Numeric>, maxCount as Number) as Void {
        while (samples.size() > maxCount) {
            samples.remove(0);
        }
    }

    function averageLast(samples as Array<Numeric>, requestedCount as Number) as Float {
        return averageRange(samples, requestedCount, 0);
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

    function isHeavyRefreshDue() as Boolean {
        return elapsedSec - lastHeavyUpdateSec >= config.heavyUpdateSec;
    }

    function refreshHeavy() as Void {
        rolling5MinPaceSec = averageLast(paceSamples, config.rollingWindowSec);

        var projectionPace = rolling5MinPaceSec;
        if (projectionPace <= 0.0) {
            projectionPace = smoothedPaceSec;
        }
        if (projectionPace <= 0.0) {
            projectionPace = averagePaceSec;
        }
        if (projectionPace <= 0.0) {
            projectionPace = config.targetPaceSec;
        }

        if (rolling5MinPaceSec > 0.0 && averagePaceSec > 0.0) {
            projectionPace = (rolling5MinPaceSec * 0.7) + (averagePaceSec * 0.3);
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

    function updateAutoLap() as Void {
        while (distanceKm >= nextAutoLapKm) {
            setLapAnchor(nextAutoLapKm, estimateElapsedAtDistance(nextAutoLapKm));
            nextAutoLapKm += 1.0;
        }
    }

    function handleLapTrigger() as Void {
        var snappedDistanceKm = distanceKm;
        var snappedElapsedSec = elapsedSec.toFloat();
        var nearestKm = roundNumber(distanceKm);
        var distanceDeltaMeters = absoluteFloat(distanceKm - nearestKm.toFloat()) * 1000.0;

        if (nearestKm > lapAnchorDistanceKm && distanceDeltaMeters <= config.lapSnapMeters) {
            snappedDistanceKm = nearestKm.toFloat();
            snappedElapsedSec = estimateElapsedAtDistance(snappedDistanceKm);
        }

        setLapAnchor(snappedDistanceKm, snappedElapsedSec);
        nextAutoLapKm = snappedDistanceKm.toNumber() + 1.0;
        if (nextAutoLapKm <= snappedDistanceKm) {
            nextAutoLapKm = snappedDistanceKm + 1.0;
        }
    }

    function setLapAnchor(anchorDistanceKm as Float, anchorElapsed as Float) as Void {
        lapAnchorDistanceKm = anchorDistanceKm;
        lapAnchorElapsedSec = anchorElapsed;
        lastLapResetSec = anchorElapsed.toNumber();
        lapVersion += 1;
        updateLapPace();
    }

    function estimateElapsedAtDistance(targetDistanceKm as Float) as Float {
        var distanceSpanKm = distanceKm - prevDistanceKm;
        if (distanceSpanKm > 0.0 && targetDistanceKm >= prevDistanceKm && targetDistanceKm <= distanceKm) {
            var ratio = (targetDistanceKm - prevDistanceKm) / distanceSpanKm;
            return prevElapsedSec.toFloat() + ((elapsedSec - prevElapsedSec).toFloat() * ratio);
        }

        var referencePace = smoothedPaceSec;
        if (referencePace <= 0.0) {
            referencePace = averagePaceSec;
        }
        if (referencePace <= 0.0) {
            return elapsedSec.toFloat();
        }

        return elapsedSec.toFloat() - ((distanceKm - targetDistanceKm) * referencePace);
    }

    function updateLapPace() as Void {
        var lapDistanceKm = distanceKm - lapAnchorDistanceKm;
        var lapTimeSec = elapsedSec.toFloat() - lapAnchorElapsedSec;
        if (lapDistanceKm > 0.01 && lapTimeSec > 0.0) {
            lapPaceSec = lapTimeSec / lapDistanceKm;
        }
    }

    function deltaToTargetSec() as Float {
        if (smoothedPaceSec <= 0.0) {
            return 0.0;
        }
        return smoothedPaceSec - config.targetPaceSec;
    }

    function roundNumber(value) as Number {
        if (value < 0) {
            return (value - 0.5).toNumber();
        }
        return (value + 0.5).toNumber();
    }

    function absoluteFloat(value as Float) as Float {
        if (value < 0.0) {
            return -value;
        }
        return value;
    }
}
