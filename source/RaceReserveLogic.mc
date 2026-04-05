import Toybox.Lang;

// ---------------------------------------------------------------------------
// RaceReserveLogic  –  running reserve / stamina estimate (Feld 12)
// ---------------------------------------------------------------------------
// FIX: Explicit `as Number` / `as Float` casts on config.hrZones[] and
//      config.verticalRatioZones[] access to eliminate container-type warnings.
// ---------------------------------------------------------------------------

class RaceReserveLogic {

    var config;
    var reservePercent          = 100;
    var baselineEstablished     = false;
    var baselineRunEfficiency   = 0.0;
    var baselinePowerEfficiency = 0.0;
    var lastComputedSec         = -1;

    function initialize(configRef) {
        config = configRef;
    }

    // -----------------------------------------------------------------------
    // Heavy refresh – every config.heavyUpdateSec seconds
    // -----------------------------------------------------------------------
    function refreshHeavy(paceLogic  as RacePaceLogic,
                          hrLogic    as RaceHeartRateLogic,
                          currentPower as Number,
                          hasPower     as Boolean) as Void {
        var paceSec = preferredPace(paceLogic);
        var hrValue = preferredHr(hrLogic);
        if (paceSec <= 0.0 || hrValue <= 0.0) { return; }

        establishBaseline(paceLogic, paceSec, hrValue, currentPower, hasPower);

        var computed = computeReserve(paceLogic, hrLogic,
                                      paceSec, hrValue,
                                      currentPower, hasPower);
        if (lastComputedSec < 0) {
            reservePercent = roundNumber(computed);
        } else {
            reservePercent = roundNumber(
                (reservePercent.toFloat() * 0.55) + (computed * 0.45));
        }

        if (paceLogic.distanceKm >= config.raceDistanceKm) {
            reservePercent = 0;
        }

        lastComputedSec = paceLogic.elapsedSec;
    }

    function preferredPace(paceLogic as RacePaceLogic) as Float {
        if (paceLogic.rolling5MinPaceSec > 0.0) { return paceLogic.rolling5MinPaceSec; }
        if (paceLogic.smoothedPaceSec    > 0.0) { return paceLogic.smoothedPaceSec;    }
        return paceLogic.averagePaceSec;
    }

    function preferredHr(hrLogic as RaceHeartRateLogic) as Float {
        if (hrLogic.rolling5MinHr > 0.0) { return hrLogic.rolling5MinHr; }
        return hrLogic.currentHr.toFloat();
    }

    function establishBaseline(paceLogic    as RacePaceLogic,
                                paceSec     as Float,
                                hrValue     as Float,
                                currentPower as Number,
                                hasPower     as Boolean) as Void {
        if (baselineEstablished ||
            paceLogic.elapsedSec < 600 ||
            paceLogic.distanceKm < 2.0) { return; }

        baselineRunEfficiency = speedFromPace(paceSec) / hrValue;
        if (hasPower && currentPower > 0) {
            baselinePowerEfficiency = speedFromPace(paceSec) /
                                      currentPower.toFloat();
        }
        baselineEstablished = baselineRunEfficiency > 0.0;
    }

    function computeReserve(paceLogic    as RacePaceLogic,
                             hrLogic     as RaceHeartRateLogic,
                             paceSec     as Float,
                             hrValue     as Float,
                             currentPower as Number,
                             hasPower     as Boolean) as Float {
        var score       = 100.0;
        var paceDelta   = paceSec - config.targetPaceSec;
        var volatility  = absoluteFloat(paceLogic.smoothedPaceSec - paceSec);

        score -= headroomPenalty(hrValue);
        score -= clamp((volatility / 12.0) * 8.0, 0.0, 8.0);

        if (paceDelta < 0.0) {
            score -= clamp((absoluteFloat(paceDelta) / 15.0) * 10.0, 0.0, 10.0);
        } else {
            score -= clamp((paceDelta / 20.0) * 6.0, 0.0, 6.0);
        }

        if (hrLogic.driftActive) {
            score -= clamp(hrLogic.driftDeltaBpm.toFloat() * 2.0, 10.0, 20.0);
        }

        if (baselineEstablished && baselineRunEfficiency > 0.0) {
            var curEff = speedFromPace(paceSec) / hrValue;
            if (curEff > 0.0 && curEff < baselineRunEfficiency) {
                var loss = 1.0 - (curEff / baselineRunEfficiency);
                score -= clamp(loss * 28.0, 0.0, 18.0);
            }
        }

        if (baselinePowerEfficiency > 0.0 && hasPower && currentPower > 0) {
            var curPwrEff = speedFromPace(paceSec) / currentPower.toFloat();
            if (curPwrEff > 0.0 && curPwrEff < baselinePowerEfficiency) {
                var pwrLoss = 1.0 - (curPwrEff / baselinePowerEfficiency);
                score -= clamp(pwrLoss * 22.0, 0.0, 12.0);
            }
        }

        // Bonus: stable, in-zone running
        var hrZones = config.hrZones as Array<Number>;
        if (!hrLogic.driftActive &&
            absoluteFloat(paceDelta) <= 5.0 &&
            hrValue <= (hrZones[2] as Number).toFloat()) {
            score += 4.0;
        }

        score = clamp(score, 18.0, 100.0);

        var progress = config.raceDistanceKm > 0.0
                     ? clamp(paceLogic.distanceKm / config.raceDistanceKm,
                             0.0, 1.0)
                     : 0.0;

        if (progress >= 1.0) { return 0.0; }

        var pf = clamp(1.0 - (progress * 0.78), 0.05, 1.0);
        return clamp(score * pf, 0.0, 100.0);
    }

    // FIX: explicit `as Number` casts on hrZones array access
    function headroomPenalty(hrValue as Float) as Float {
        var hrZones  = config.hrZones as Array<Number>;
        var cautionHr = (hrZones[2] as Number).toFloat();
        var limitHr   = (hrZones[3] as Number).toFloat();
        var maxHr     = (hrZones[4] as Number).toFloat();
        var penalty   = 0.0;

        if (hrValue > cautionHr && limitHr > cautionHr) {
            penalty += clamp(((hrValue - cautionHr) / (limitHr - cautionHr)) * 20.0,
                             0.0, 20.0);
        }
        if (hrValue > limitHr && maxHr > limitHr) {
            penalty += clamp(((hrValue - limitHr) / (maxHr - limitHr)) * 14.0,
                             0.0, 14.0);
        }
        return penalty;
    }

    function speedFromPace(paceSec as Float) as Float {
        return paceSec <= 0.0 ? 0.0 : 1000.0 / paceSec;
    }

    function clamp(value as Float, low as Float, high as Float) as Float {
        if (value < low)  { return low;  }
        if (value > high) { return high; }
        return value;
    }

    function absoluteFloat(value as Float) as Float {
        return value < 0.0 ? -value : value;
    }

    function roundNumber(value as Float) as Number {
        if (value < 0.0) { return (value - 0.5).toNumber(); }
        return (value + 0.5).toNumber();
    }
}
