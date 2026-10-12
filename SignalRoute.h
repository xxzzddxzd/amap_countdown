#ifndef AMAP_SIGNAL_ROUTE_H
#define AMAP_SIGNAL_ROUTE_H

#include "SignalHistory.h"

#ifdef __cplusplus
extern "C" {
#endif

#define SR_MAX_PHASES 64
#define SR_NAME_CAPACITY 192
#define SR_APPROACH_CAPACITY 160
#define SR_NATIVE_MAX_AGE_SECONDS 2.5

typedef struct SRRoute SRRoute;

/* targetOffset identifies one occurrence within the current navigation only.
 * Call SRReset on navigation start/end or a route change; it is not a road ID. */
typedef struct {
    uint64_t id;
    int targetOffset;
    double distanceMeters;
    int source; /* 1 car, 2 travel, 3 raw */
    bool ambiguous;
    /* Identity can remain reliable even when native state is unusable.
     * Such occurrences retain bindings/blacklists but show no prediction. */
    bool dataUnavailable;
    double capturedAt;
    unsigned phaseCount;
    SHPhase phases[SR_MAX_PHASES];
} SRSignal;

typedef struct {
    uint64_t id;
    int targetOffset;
    double distanceMeters;
    int source;
    int color; /* 0 unknown, 1 red, 2 yellow, 3 green */
    int seconds; /* -1 when unknown */
    bool predicted;
    bool bound;
    bool ambiguous;
    bool isNearest; /* nearest non-blacklisted occurrence still ahead */
    char name[SR_NAME_CAPACITY];
    char approachKey[SR_APPROACH_CAPACITY];
    char approachName[SR_APPROACH_CAPACITY];
} SRDisplay;

/* The store remains owned by the caller and may be NULL. Calls must be made
 * on one thread (normally the UI thread). */
SRRoute *SRCreate(SHStore *store);
void SRDestroy(SRRoute *route);
void SRReset(SRRoute *route);

/* Replaces the upcoming route, keeping a manually selected occurrence only
 * while it is still ahead. Negative/nonfinite distances are excluded. */
bool SRUpdate(SRRoute *route, const SRSignal *signals, size_t count, double now);
void SRRefresh(SRRoute *route, double now);

/* relativeIndex 0 is the selected main light; 1 and 2 are its successors. */
bool SRGetVisible(SRRoute *route, unsigned relativeIndex, double now,
                  SRDisplay *display);
size_t SRVisibleCount(SRRoute *route);
bool SRMove(SRRoute *route, int step);

/* Explicitly binds an occurrence still ahead to the entering road. No history
 * direction is ever chosen automatically. Ambiguous occurrences cannot bind.
 * Keys must be nonempty and fit SR_APPROACH_CAPACITY without truncation.
 * Calling this again can change the direction or update its display names. */
bool SRBind(SRRoute *route, uint64_t id, int targetOffset,
            const char *approachKey, const char *approachName,
            const char *name, double now);

#ifdef __cplusplus
}
#endif
#endif
