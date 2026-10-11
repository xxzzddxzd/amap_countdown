#include "AdviceStrategy.h"

#include <float.h>
#include <math.h>

static double Minimum(double a, double b) { return a < b ? a : b; }
static double Maximum(double a, double b) { return a > b ? a : b; }

AdviceConfig AdviceDefaultConfig(void) {
    AdviceConfig config = {
        .accelerationMps2 = 0.4,
        .decelerationMps2 = 0.6,
        .minimumCurrentSpeedMps = 0.5,
        .minimumRollingSpeedMps = 5.0 / 3.6,
        .maximumSpeedMps = 25.0 / 3.6,
        .maximumSpeedIncreaseMps = 5.0 / 3.6,
        .minimumAccelerationDistanceMeters = 30.0,
        .greenStartBufferSeconds = 0.0,
        .greenEndBufferSeconds = 4.0,
        .maximumPredictionSeconds = 300.0,
        .maximumWindows = 5,
    };
    return config;
}

double AdviceArrivalTimeSeconds(double distanceMeters, double currentSpeedMps,
                                double targetSpeedMps,
                                const AdviceConfig *config) {
    if (!config || !isfinite(distanceMeters) || !isfinite(currentSpeedMps) ||
        !isfinite(targetSpeedMps) || distanceMeters < 0.0 ||
        currentSpeedMps < 0.0 || targetSpeedMps <= 0.0)
        return INFINITY;
    if (distanceMeters == 0.0) return 0.0;

    double delta = targetSpeedMps - currentSpeedMps;
    if (fabs(delta) < 1e-9) return distanceMeters / targetSpeedMps;

    double acceleration = delta > 0.0 ? config->accelerationMps2
                                      : config->decelerationMps2;
    if (!isfinite(acceleration) || acceleration <= 0.0) return INFINITY;

    double rampTime = fabs(delta) / acceleration;
    double rampDistance = (currentSpeedMps + targetSpeedMps) * 0.5 * rampTime;
    if (distanceMeters <= rampDistance) {
        if (delta > 0.0) {
            double discriminant = currentSpeedMps * currentSpeedMps +
                                  2.0 * acceleration * distanceMeters;
            return (-currentSpeedMps + sqrt(Maximum(0.0, discriminant))) /
                   acceleration;
        }
        double discriminant = currentSpeedMps * currentSpeedMps -
                              2.0 * acceleration * distanceMeters;
        if (discriminant < 0.0) return INFINITY;
        return (currentSpeedMps - sqrt(discriminant)) / acceleration;
    }
    return rampTime + (distanceMeters - rampDistance) / targetSpeedMps;
}

static AdviceResult EmptyResult(void) {
    AdviceResult result = {
        .action = AdviceUnavailable,
        .available = false,
        .targetSpeedMps = 0.0,
        .speedDeltaMps = 0.0,
        .predictedArrivalSeconds = INFINITY,
        .windowStartEpochSeconds = 0.0,
        .windowEndEpochSeconds = 0.0,
        .windowIndex = 0,
    };
    return result;
}

static int ActionPriority(AdviceAction action) {
    if (action == AdviceMaintain) return 0;
    if (action == AdviceDecelerate || action == AdviceReduceToLimit) return 1;
    if (action == AdviceAccelerate) return 2;
    return 3;
}

static bool BetterCandidate(const AdviceResult *candidate,
                            const AdviceResult *best) {
    if (!best->available) return true;
    double candidateChange = fabs(candidate->speedDeltaMps);
    double bestChange = fabs(best->speedDeltaMps);
    if (candidateChange + 1e-5 < bestChange) return true;
    if (bestChange + 1e-5 < candidateChange) return false;
    int candidatePriority = ActionPriority(candidate->action);
    int bestPriority = ActionPriority(best->action);
    if (candidatePriority != bestPriority)
        return candidatePriority < bestPriority;
    if (candidate->windowStartEpochSeconds != best->windowStartEpochSeconds)
        return candidate->windowStartEpochSeconds <
               best->windowStartEpochSeconds;
    return candidate->targetSpeedMps < best->targetSpeedMps;
}

static AdviceResult CandidateForWindow(const AdviceInput *input,
                                       const AdviceConfig *config,
                                       double safeStartEpoch,
                                       double safeEndEpoch,
                                       unsigned windowIndex) {
    AdviceResult result = EmptyResult();
    double start = Maximum(0.0, safeStartEpoch - input->nowEpochSeconds);
    double end = safeEndEpoch - input->nowEpochSeconds;
    if (end <= 0.0 || end < start || start > config->maximumPredictionSeconds)
        return result;
    end = Minimum(end, config->maximumPredictionSeconds);
    if (end < start) return result;

    double current = input->currentSpeedMps;
    double currentArrival = AdviceArrivalTimeSeconds(
        input->distanceMeters, current, current, config);
    double target = current;
    AdviceAction action = AdviceMaintain;

    if (currentArrival > end + 1e-6) {
        if (!input->allowAcceleration ||
            input->distanceMeters < config->minimumAccelerationDistanceMeters)
            return result;
        double low = current;
        double high = Minimum(config->maximumSpeedMps,
                              current + config->maximumSpeedIncreaseMps);
        if (high <= low || AdviceArrivalTimeSeconds(
                input->distanceMeters, current, high, config) > end)
            return result;
        for (unsigned iteration = 0; iteration < 64; ++iteration) {
            double middle = (low + high) * 0.5;
            double arrival = AdviceArrivalTimeSeconds(
                input->distanceMeters, current, middle, config);
            if (arrival <= end)
                high = middle;
            else
                low = middle;
        }
        target = high;
        action = AdviceAccelerate;
    } else if (currentArrival + 1e-6 < start) {
        double low = config->minimumRollingSpeedMps;
        double high = current;
        if (high <= low || AdviceArrivalTimeSeconds(
                input->distanceMeters, current, low, config) < start)
            return result;
        for (unsigned iteration = 0; iteration < 64; ++iteration) {
            double middle = (low + high) * 0.5;
            double arrival = AdviceArrivalTimeSeconds(
                input->distanceMeters, current, middle, config);
            if (arrival >= start)
                low = middle;
            else
                high = middle;
        }
        target = low;
        action = AdviceDecelerate;
    }

    double arrival = AdviceArrivalTimeSeconds(
        input->distanceMeters, current, target, config);
    if (!isfinite(arrival) || arrival + 1e-4 < start ||
        arrival - 1e-4 > end)
        return result;

    result.action = action;
    result.available = true;
    result.targetSpeedMps = target;
    result.speedDeltaMps = target - current;
    result.predictedArrivalSeconds = arrival;
    result.windowStartEpochSeconds = safeStartEpoch;
    result.windowEndEpochSeconds = safeEndEpoch;
    result.windowIndex = windowIndex;
    return result;
}

AdviceResult AdviceCompute(const AdviceInput *input,
                           const AdviceConfig *config) {
    AdviceResult empty = EmptyResult();
    if (!input || !config || !input->greenWindows ||
        !input->greenWindowCount || !isfinite(input->nowEpochSeconds) ||
        !isfinite(input->distanceMeters) || input->distanceMeters <= 0.0 ||
        !isfinite(input->currentSpeedMps) ||
        input->currentSpeedMps < config->minimumCurrentSpeedMps ||
        config->minimumRollingSpeedMps <= 0.0 ||
        config->maximumSpeedMps <= config->minimumRollingSpeedMps)
        return empty;

    if (input->currentSpeedMps > config->maximumSpeedMps + 1e-6) {
        AdviceResult limit = EmptyResult();
        limit.action = AdviceReduceToLimit;
        limit.available = true;
        limit.targetSpeedMps = config->maximumSpeedMps;
        limit.speedDeltaMps = config->maximumSpeedMps -
                              input->currentSpeedMps;
        limit.predictedArrivalSeconds = AdviceArrivalTimeSeconds(
            input->distanceMeters, input->currentSpeedMps,
            config->maximumSpeedMps, config);
        return limit;
    }

    AdviceResult best = EmptyResult();
    AdviceResult preferred = EmptyResult();
    unsigned considered = 0;
    for (size_t index = 0; index < input->greenWindowCount; ++index) {
        const AdviceGreenWindow *window = &input->greenWindows[index];
        if (!isfinite(window->startEpochSeconds) ||
            !isfinite(window->endEpochSeconds) ||
            window->endEpochSeconds <= window->startEpochSeconds)
            continue;
        double safeStart = window->startEpochSeconds +
                           config->greenStartBufferSeconds;
        double safeEnd = window->endEpochSeconds -
                         config->greenEndBufferSeconds;
        if (safeEnd <= input->nowEpochSeconds || safeEnd < safeStart) continue;
        if (considered++ >= config->maximumWindows) break;

        AdviceResult candidate = CandidateForWindow(
            input, config, safeStart, safeEnd, (unsigned)index);
        if (!candidate.available) continue;
        if (BetterCandidate(&candidate, &best)) best = candidate;
        if (input->preferredWindowStartEpochSeconds > 0.0 &&
            fabs(safeStart - input->preferredWindowStartEpochSeconds) < 0.5)
            preferred = candidate;
    }

    if (!best.available) {
        AdviceResult stop = EmptyResult();
        stop.action = AdvicePrepareStop;
        stop.available = true;
        stop.targetSpeedMps = input->currentSpeedMps;
        stop.predictedArrivalSeconds = AdviceArrivalTimeSeconds(
            input->distanceMeters, input->currentSpeedMps,
            input->currentSpeedMps, config);
        return stop;
    }

    if (preferred.available && best.action != AdviceMaintain) {
        double improvement = fabs(preferred.speedDeltaMps) -
                             fabs(best.speedDeltaMps);
        if (improvement >= 0.0 &&
            improvement < input->windowSwitchImprovementMps)
            best = preferred;
    }
    return best;
}

static int SafetyRank(AdviceAction action) {
    if (action == AdvicePrepareStop || action == AdviceReduceToLimit) return 3;
    if (action == AdviceDecelerate) return 2;
    if (action == AdviceMaintain) return 1;
    if (action == AdviceAccelerate) return 0;
    return 4;
}

static bool SamePlan(const AdviceResult *left, const AdviceResult *right,
                     double targetDeadbandMps) {
    if (left->action != right->action || left->windowIndex != right->windowIndex)
        return false;
    if (left->action != AdvicePrepareStop &&
        left->action != AdviceReduceToLimit &&
        fabs(left->windowStartEpochSeconds -
             right->windowStartEpochSeconds) >= 0.5)
        return false;
    return fabs(left->targetSpeedMps - right->targetSpeedMps) <=
           targetDeadbandMps;
}

AdviceResult AdviceStabilize(AdviceStabilizer *state,
                             AdviceResult raw,
                             uint64_t signalId,
                             double nowEpochSeconds,
                             double currentSpeedMps,
                             double persistenceSeconds,
                             double targetDeadbandMps) {
    if (!state || !isfinite(nowEpochSeconds) || !isfinite(currentSpeedMps) ||
        persistenceSeconds < 0.0 || targetDeadbandMps < 0.0)
        return raw;

    bool signalChanged = state->initialized && state->signalId != signalId;
    bool immediate = !state->initialized || signalChanged || !raw.available ||
                     raw.action == AdviceUnavailable ||
                     raw.action == AdvicePrepareStop ||
                     raw.action == AdviceReduceToLimit ||
                     (state->initialized &&
                      state->displayed.action == AdviceUnavailable) ||
                     (state->initialized &&
                      SafetyRank(raw.action) >
                          SafetyRank(state->displayed.action)) ||
                     (state->initialized &&
                      state->displayed.action == AdviceAccelerate &&
                      raw.action != AdviceAccelerate);
    if (immediate) {
        state->initialized = true;
        state->pending = false;
        state->signalId = signalId;
        state->displayed = raw;
        return raw;
    }

    state->signalId = signalId;
    if (SamePlan(&state->displayed, &raw, targetDeadbandMps)) {
        AdviceResult stable = raw;
        stable.targetSpeedMps = state->displayed.targetSpeedMps;
        stable.speedDeltaMps = stable.targetSpeedMps - currentSpeedMps;
        state->displayed = stable;
        state->pending = false;
        return stable;
    }

    bool lessAggressiveTarget =
        (raw.action == AdviceAccelerate &&
         raw.targetSpeedMps < state->displayed.targetSpeedMps) ||
        ((raw.action == AdviceDecelerate ||
          raw.action == AdviceReduceToLimit) &&
         raw.targetSpeedMps < state->displayed.targetSpeedMps);
    if (raw.action == state->displayed.action && lessAggressiveTarget) {
        state->displayed = raw;
        state->pending = false;
        return raw;
    }

    if (!state->pending ||
        !SamePlan(&state->pendingResult, &raw, targetDeadbandMps)) {
        state->pending = true;
        state->pendingSinceEpochSeconds = nowEpochSeconds;
        state->pendingResult = raw;
    } else {
        state->pendingResult = raw;
    }
    if (nowEpochSeconds - state->pendingSinceEpochSeconds >=
        persistenceSeconds) {
        state->displayed = state->pendingResult;
        state->pending = false;
        return state->displayed;
    }

    AdviceResult held = state->displayed;
    held.speedDeltaMps = held.targetSpeedMps - currentSpeedMps;
    return held;
}
