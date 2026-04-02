import Toybox.Lang;

class RaceReserveLogic {

    var config;
    var reservePercent = 100;
    var baselineEstablished = false;
    var baselineRunEfficiency = 0.0;
    var baselinePowerEfficiency = 0.0;
    var lastComputedSec = -1;

    function initialize(configRef) {
        config = configRef;
    }

    function refreshHeavy(paceLogic as RacePaceLogic, hrLogic as RaceHeartRateLogic, currentPower as Number, hasPower as Boolean) as Void {
        var paceSec = preferredPace(paceLogic);
        var hrValue = preferredHr(hrLogic);
        if (paceSec <= 0.0 || hrValue <= 0.0) {
            return;
        }

        establishBaseline(paceLogic, paceSec, hrValue, currentPower, hasPower);

        var computedReserve = computeReserve(paceLogic, hrLogic, paceSec, hrValue, currentPower, hasPower);
        if (lastComputedSec < 0) {
            reservePercent = roundNumber(computedReserve);
        } else {
            reservePercent = roundNumber((reservePercent.toFloat() * 0.55) + (computedReserve * 0.45));
        }

        if (paceLogic.distanceKm >= config.raceDistanceKm) {
            reservePercent = 0;
        }

        lastComputedSec = paceLogic.elapsedSec;
    }

    function preferredPace(paceLogic as RacePaceLogic) as Float {
        if (paceLogic.rolling5MinPaceSec > 0.0) {
            return paceLogic.rolling5MinPaceSec;
        } else if (paceLogic.smoothedPaceSec > 0.0) {
            return paceLogic.smoothedPaceSec;
        }
        return paceLogic.averagePaceSec;
    }

    function preferredHr(hrLogic as RaceHeartRateLogic) as Float {
        if (hrLogic.rolling5MinHr > 0.0) {
            return hrLogic.rolling5MinHr;
        }
        return hrLogic.currentHr.toFloat();
    }

    function establishBaseline(paceLogic as RacePaceLogic, paceSec as Float, hrValue as Float, currentPower as Number, hasPower as Boolean) as Void {
        if (baselineEstablished || paceLogic.elapsedSec < 600 || paceLogic.distanceKm < 2.0) {
            return;
        }

        baselineRunEfficiency = speedFromPace(paceSec) / hrValue;
        if (hasPower && currentPower > 0) {
            baselinePowerEfficiency = speedFromPace(paceSec) / currentPower.toFloat();
        }
        baselineEstablished = baselineRunEfficiency > 0.0;
    }

    function computeReserve(paceLogic as RacePaceLogic, hrLogic as RaceHeartRateLogic, paceSec as Float, hrValue as Float, currentPower as Number, hasPower as Boolean) as Float {
        var capacityScore = 100.0;
        var paceDelta = paceSec - config.targetPaceSec;
        var paceVolatility = absoluteFloat(paceLogic.smoothedPaceSec - paceSec);

        capacityScore -= headroomPenalty(hrValue);
        capacityScore -= clamp((paceVolatility / 12.0) * 8.0, 0.0, 8.0);

        if (paceDelta < 0.0) {
            capacityScore -= clamp((absoluteFloat(paceDelta) / 15.0) * 10.0, 0.0, 10.0);
        } else {
            capacityScore -= clamp((paceDelta / 20.0) * 6.0, 0.0, 6.0);
        }

        if (hrLogic.driftActive) {
            capacityScore -= clamp(hrLogic.driftDeltaBpm.toFloat() * 2.0, 10.0, 20.0);
        }

        if (baselineEstablished && baselineRunEfficiency > 0.0) {
            var currentRunEfficiency = speedFromPace(paceSec) / hrValue;
            if (currentRunEfficiency > 0.0 && currentRunEfficiency < baselineRunEfficiency) {
                var runEfficiencyLoss = 1.0 - (currentRunEfficiency / baselineRunEfficiency);
                capacityScore -= clamp(runEfficiencyLoss * 28.0, 0.0, 18.0);
            }
        }

        if (baselinePowerEfficiency > 0.0 && hasPower && currentPower > 0) {
            var currentPowerEfficiency = speedFromPace(paceSec) / currentPower.toFloat();
            if (currentPowerEfficiency > 0.0 && currentPowerEfficiency < baselinePowerEfficiency) {
                var powerEfficiencyLoss = 1.0 - (currentPowerEfficiency / baselinePowerEfficiency);
                capacityScore -= clamp(powerEfficiencyLoss * 22.0, 0.0, 12.0);
            }
        }

        if (!hrLogic.driftActive && absoluteFloat(paceDelta) <= 5.0 && hrValue <= config.hrZones[2]) {
            capacityScore += 4.0;
        }

        capacityScore = clamp(capacityScore, 18.0, 100.0);

        var progress = 0.0;
        if (config.raceDistanceKm > 0.0) {
            progress = clamp(paceLogic.distanceKm / config.raceDistanceKm, 0.0, 1.0);
        }

        var progressFactor = 1.0 - (progress * 0.78);
        if (progressFactor < 0.05) {
            progressFactor = 0.05;
        }

        if (progress >= 1.0) {
            return 0.0;
        }

        return clamp(capacityScore * progressFactor, 0.0, 100.0);
    }

    function headroomPenalty(hrValue as Float) as Float {
        var cautionHr = config.hrZones[2].toFloat();
        var limitHr = config.hrZones[3].toFloat();
        var maxHr = config.hrZones[4].toFloat();
        var penalty = 0.0;

        if (hrValue > cautionHr && limitHr > cautionHr) {
            penalty += clamp(((hrValue - cautionHr) / (limitHr - cautionHr)) * 20.0, 0.0, 20.0);
        }

        if (hrValue > limitHr && maxHr > limitHr) {
            penalty += clamp(((hrValue - limitHr) / (maxHr - limitHr)) * 14.0, 0.0, 14.0);
        }

        return penalty;
    }

    function speedFromPace(paceSec as Float) as Float {
        if (paceSec <= 0.0) {
            return 0.0;
        }
        return 1000.0 / paceSec;
    }

    function clamp(value as Float, low as Float, high as Float) as Float {
        if (value < low) {
            return low;
        } else if (value > high) {
            return high;
        }
        return value;
    }

    function absoluteFloat(value as Float) as Float {
        if (value < 0.0) {
            return -value;
        }
        return value;
    }

    function roundNumber(value as Float) as Number {
        if (value < 0.0) {
            return (value - 0.5).toNumber();
        }
        return (value + 0.5).toNumber();
    }
}
