#ifndef AMAP_ADVICE_STRATEGY_H
#define AMAP_ADVICE_STRATEGY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum {
    AdviceUnavailable = 0,
    AdviceMaintain,
    AdviceAccelerate,
    AdviceDecelerate,
    AdviceReduceToLimit,
    AdvicePrepareStop
} AdviceAction;

typedef struct {
    double startEpochSeconds;
    double endEpochSeconds;
} AdviceGreenWindow;

typedef struct {
    double accelerationMps2;
    double decelerationMps2;
    double minimumCurrentSpeedMps;
    double minimumRollingSpeedMps;
    double maximumSpeedMps;
    double maximumSpeedIncreaseMps;
    double minimumAccelerationDistanceMeters;
    double greenStartBufferSeconds;
    double greenEndBufferSeconds;
    double maximumPredictionSeconds;
    unsigned maximumWindows;
} AdviceConfig;

typedef struct {
    double nowEpochSeconds;
    double distanceMeters;
    double currentSpeedMps;
    const AdviceGreenWindow *greenWindows;
    size_t greenWindowCount;
    bool allowAcceleration;
    double preferredWindowStartEpochSeconds;
    double windowSwitchImprovementMps;
} AdviceInput;

typedef struct {
    AdviceAction action;
    bool available;
    double targetSpeedMps;
    double speedDeltaMps;
    double predictedArrivalSeconds;
    double windowStartEpochSeconds;
    double windowEndEpochSeconds;
    unsigned windowIndex;
} AdviceResult;

typedef struct {
    bool initialized;
    bool pending;
    uint64_t signalId;
    double pendingSinceEpochSeconds;
    AdviceResult displayed;
    AdviceResult pendingResult;
} AdviceStabilizer;

AdviceConfig AdviceDefaultConfig(void);
double AdviceArrivalTimeSeconds(double distanceMeters, double currentSpeedMps,
                                double targetSpeedMps,
                                const AdviceConfig *config);
AdviceResult AdviceCompute(const AdviceInput *input,
                           const AdviceConfig *config);
AdviceResult AdviceStabilize(AdviceStabilizer *state,
                             AdviceResult raw,
                             uint64_t signalId,
                             double nowEpochSeconds,
                             double currentSpeedMps,
                             double persistenceSeconds,
                             double targetDeadbandMps);

#endif
