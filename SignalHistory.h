#ifndef AMAP_SIGNAL_HISTORY_H
#define AMAP_SIGNAL_HISTORY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Keys must identify the entering road. NULL/empty keys are never persisted. */
#define SH_KEY_CAPACITY 256
#define SH_NAME_CAPACITY 256
#define SH_PREDICTION_MAX_AGE_SECONDS (6.0 * 60.0 * 60.0)

typedef struct SHStore SHStore;

typedef struct {
    int color; /* 1 red, 2 yellow, 3 green */
    double startsAt;
    double endsAt;
} SHPhase;

typedef struct {
    uint64_t signalId;
    const char *approachKey;
    /* NULL preserves an existing name; an empty string clears it. */
    const char *name;
    const char *approachName;
} SHIdentity;

typedef struct {
    int color;
    double remaining;
    double phaseEndsAt;
    double learnedAt;
    bool available;
} SHPrediction;

typedef struct {
    uint64_t signalId;
    char approachKey[SH_KEY_CAPACITY];
    char name[SH_NAME_CAPACITY];
    char approachName[SH_NAME_CAPACITY];
    bool blacklisted;
    double lastObservedAt;
    bool hasPrediction;
    double learnedAt;
    double redSeconds;
    double yellowSeconds;
    double greenSeconds;
} SHEntry;

/* The caller creates the parent directory; calls are internally serialized. */
SHStore *SHOpen(const char *path);
void SHClose(SHStore *store);
bool SHUpsertIdentity(SHStore *store, const SHIdentity *identity);

/* Only complete native phases belong here; predictions are never inputs.
 * Repeated identical snapshots do not insert additional sample rows.
 * Learning requires two contiguous, matching complete cycles. */
bool SHRemember(SHStore *store, const SHIdentity *identity,
                const SHPhase *phases, size_t count, double observedAt);

/* Tracks a live countdown. A first observation is partial; only a phase whose
 * beginning and end were both observed through transitions is learned. */
bool SHObserve(SHStore *store, const SHIdentity *identity, int color,
               double phaseEndsAt, double observedAt);

/* Returns true only for a complete, fresh model. Boundaries use [start, end). */
bool SHPredict(SHStore *store, uint64_t signalId, const char *approachKey,
               double now, SHPrediction *prediction);
bool SHSetBlacklisted(SHStore *store, uint64_t signalId,
                      const char *approachKey, bool blacklisted);
bool SHIsBlacklisted(SHStore *store, uint64_t signalId,
                     const char *approachKey);

/* Returns the total entry count, writing at most capacity entries. */
size_t SHList(SHStore *store, SHEntry *entries, size_t capacity);

#ifdef __cplusplus
}
#endif
#endif
