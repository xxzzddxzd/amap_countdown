#include "SignalRoute.h"

#include <ctype.h>
#include <limits.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    SRSignal signal;
    size_t originalOrder;
    bool bound;
    char name[SR_NAME_CAPACITY];
    char approachKey[SR_APPROACH_CAPACITY];
    char approachName[SR_APPROACH_CAPACITY];
} SRItem;

struct SRRoute {
    SHStore *store;
    SRItem *items;
    size_t count;
    bool selected;
    bool manualSelection;
    uint64_t selectedId;
    int selectedOffset;
    double now;
};

/* Avoid leaving a truncated UTF-8 character in UI labels. Keys are never
 * truncated: truncating one could merge two entering roads. */
static void CopyLabel(char *destination, size_t capacity, const char *source) {
    if (!source) source = "";
    size_t length = strlen(source);
    if (length >= capacity) {
        length = capacity - 1;
        while (length && ((unsigned char)source[length] & 0xc0) == 0x80)
            length--;
    }
    memcpy(destination, source, length);
    destination[length] = '\0';
}

static bool ValidKey(const char *key) {
    if (!key || !key[0] || strlen(key) >= SR_APPROACH_CAPACITY) return false;
    for (const unsigned char *cursor = (const unsigned char *)key; *cursor;
         cursor++) {
        if (!isspace(*cursor)) return true;
    }
    return false;
}

static bool SameOccurrence(const SRSignal *left, const SRSignal *right) {
    return left->id == right->id && left->targetOffset == right->targetOffset;
}

static int CompareItems(const void *first, const void *second) {
    const SRItem *left = first;
    const SRItem *right = second;
    if (left->signal.distanceMeters < right->signal.distanceMeters) return -1;
    if (left->signal.distanceMeters > right->signal.distanceMeters) return 1;
    if (left->originalOrder < right->originalOrder) return -1;
    if (left->originalOrder > right->originalOrder) return 1;
    return 0;
}

static bool Blacklisted(const SRRoute *route, const SRItem *item) {
    return route->store && item->bound && !item->signal.ambiguous &&
           SHIsBlacklisted(route->store, item->signal.id, item->approachKey);
}

static size_t NearestIndex(const SRRoute *route) {
    for (size_t index = 0; index < route->count; index++) {
        if (!Blacklisted(route, &route->items[index])) return index;
    }
    return route->count;
}

static size_t SelectedIndex(const SRRoute *route) {
    if (route->selected) {
        size_t found = route->count;
        for (size_t index = 0; index < route->count; index++) {
            const SRItem *item = &route->items[index];
            if (item->signal.id != route->selectedId ||
                item->signal.targetOffset != route->selectedOffset) continue;
            /* An exact duplicate no longer identifies a unique occurrence. */
            if (found != route->count) return route->count;
            found = index;
        }
        if (found != route->count && !Blacklisted(route, &route->items[found]))
            return found;
    }
    return route->count;
}

static void SelectIndex(SRRoute *route, size_t index) {
    route->selected = index < route->count;
    if (route->selected) {
        route->selectedId = route->items[index].signal.id;
        route->selectedOffset = route->items[index].signal.targetOffset;
    } else {
        route->selectedId = 0;
        route->selectedOffset = -1;
    }
}

static size_t ReconcileSelection(SRRoute *route) {
    size_t index = route->manualSelection ? SelectedIndex(route) : route->count;
    if (index != route->count) return index;
    route->manualSelection = false;
    index = NearestIndex(route);
    SelectIndex(route, index);
    return index;
}

static bool ValidPhase(const SHPhase *phase) {
    return phase->color >= 1 && phase->color <= 3 &&
           isfinite(phase->startsAt) && isfinite(phase->endsAt) &&
           phase->endsAt > phase->startsAt;
}

static bool NativeCurrent(const SRSignal *signal, double now, SHPhase *current) {
    double age = now - signal->capturedAt;
    if (signal->dataUnavailable || !isfinite(now) || !isfinite(signal->capturedAt) ||
        signal->capturedAt <= 0.0 || !isfinite(age) || age < -0.5 ||
        age > SR_NATIVE_MAX_AGE_SECONDS || signal->phaseCount == 0 ||
        signal->phaseCount > SR_MAX_PHASES) return false;
    bool found = false;
    for (unsigned index = 0; index < signal->phaseCount; index++) {
        const SHPhase *phase = &signal->phases[index];
        if (!ValidPhase(phase)) return false;
        if (phase->startsAt <= now && now < phase->endsAt) {
            if (found) return false;
            *current = *phase;
            found = true;
        }
    }
    return found;
}

static SHIdentity IdentityFor(const SRItem *item) {
    SHIdentity identity = {
        .signalId = item->signal.id,
        .approachKey = item->approachKey,
        .name = item->name,
        .approachName = item->approachName
    };
    return identity;
}

static void RecordNative(SRRoute *route, const SRItem *item, double now) {
    if (!route->store || !item->bound || item->signal.ambiguous ||
        item->signal.dataUnavailable ||
        item->signal.id == 0) return;
    SHPhase current;
    if (!NativeCurrent(&item->signal, now, &current)) return;
    SHIdentity identity = IdentityFor(item);
    SHRemember(route->store, &identity, item->signal.phases,
               item->signal.phaseCount, now);
    SHObserve(route->store, &identity, current.color, current.endsAt, now);
}

SRRoute *SRCreate(SHStore *store) {
    SRRoute *route = calloc(1, sizeof(*route));
    if (route) {
        route->store = store;
        route->selectedOffset = -1;
    }
    return route;
}

void SRReset(SRRoute *route) {
    if (!route) return;
    free(route->items);
    route->items = NULL;
    route->count = 0;
    route->now = 0.0;
    route->manualSelection = false;
    SelectIndex(route, 0);
}

void SRDestroy(SRRoute *route) {
    if (!route) return;
    SRReset(route);
    free(route);
}

bool SRUpdate(SRRoute *route, const SRSignal *signals, size_t count, double now) {
    if (!route || !isfinite(now) || (count && !signals) ||
        count > SIZE_MAX / sizeof(SRItem)) return false;
    SRItem *next = count ? calloc(count, sizeof(*next)) : NULL;
    if (count && !next) return false;
    size_t kept = 0;
    for (size_t index = 0; index < count; index++) {
        if (!isfinite(signals[index].distanceMeters) ||
            signals[index].distanceMeters < 0.0) continue;
        next[kept].signal = signals[index];
        next[kept].originalOrder = index;
        if (next[kept].signal.id == 0) next[kept].signal.ambiguous = true;
        kept++;
    }
    if (kept) qsort(next, kept, sizeof(*next), CompareItems);
    for (size_t left = 0; left < kept; left++) {
        for (size_t right = left + 1; right < kept; right++) {
            if (SameOccurrence(&next[left].signal, &next[right].signal) ||
                fabs(next[left].signal.distanceMeters -
                     next[right].signal.distanceMeters) <= 0.01) {
                next[left].signal.ambiguous = true;
                next[right].signal.ambiguous = true;
            }
        }
    }
    for (size_t index = 0; index < kept; index++) {
        if (next[index].signal.ambiguous) continue;
        for (size_t previous = 0; previous < route->count; previous++) {
            const SRItem *old = &route->items[previous];
            if (!old->bound || old->signal.ambiguous ||
                !SameOccurrence(&next[index].signal, &old->signal)) continue;
            next[index].bound = true;
            memcpy(next[index].name, old->name, sizeof(old->name));
            memcpy(next[index].approachKey, old->approachKey,
                   sizeof(old->approachKey));
            memcpy(next[index].approachName, old->approachName,
                   sizeof(old->approachName));
            break;
        }
    }
    free(route->items);
    route->items = next;
    route->count = kept;
    route->now = now;
    ReconcileSelection(route);
    for (size_t index = 0; index < kept; index++)
        RecordNative(route, &route->items[index], now);
    return true;
}

void SRRefresh(SRRoute *route, double now) {
    if (!route) return;
    if (isfinite(now)) route->now = now;
    ReconcileSelection(route);
}

static int RemainingSeconds(double remaining) {
    if (!isfinite(remaining) || remaining <= 0.0) return -1;
    if (remaining >= INT_MAX) return INT_MAX;
    return (int)ceil(remaining);
}

bool SRGetVisible(SRRoute *route, unsigned relativeIndex, double now,
                  SRDisplay *display) {
    if (!display) return false;
    memset(display, 0, sizeof(*display));
    display->seconds = -1;
    display->targetOffset = -1;
    display->distanceMeters = -1.0;
    if (!route || !isfinite(now)) return false;
    SRRefresh(route, now);
    size_t index = ReconcileSelection(route);
    if (index == route->count) return false;
    unsigned relative = 0;
    for (; index < route->count; index++) {
        if (Blacklisted(route, &route->items[index])) continue;
        if (relative == relativeIndex) break;
        relative++;
    }
    if (index == route->count) return false;
    const SRItem *item = &route->items[index];
    display->id = item->signal.id;
    display->targetOffset = item->signal.targetOffset;
    display->distanceMeters = item->signal.distanceMeters;
    display->source = item->signal.source;
    display->bound = item->bound;
    display->ambiguous = item->signal.ambiguous;
    display->isNearest = index == NearestIndex(route);
    memcpy(display->name, item->name, sizeof(display->name));
    memcpy(display->approachKey, item->approachKey, sizeof(display->approachKey));
    memcpy(display->approachName, item->approachName, sizeof(display->approachName));
    SHPhase current;
    if (!item->signal.ambiguous && NativeCurrent(&item->signal, now, &current)) {
        display->color = current.color;
        display->seconds = RemainingSeconds(current.endsAt - now);
    } else if (route->store && item->bound && !item->signal.ambiguous &&
               !item->signal.dataUnavailable) {
        SHPrediction prediction;
        if (SHPredict(route->store, item->signal.id, item->approachKey, now,
                      &prediction)) {
            display->color = prediction.color;
            display->seconds = RemainingSeconds(prediction.remaining);
            display->predicted = true;
        }
    }
    return true;
}

size_t SRVisibleCount(SRRoute *route) {
    if (!route) return 0;
    ReconcileSelection(route);
    size_t count = 0;
    for (size_t index = 0; index < route->count; index++) {
        if (!Blacklisted(route, &route->items[index])) count++;
    }
    return count;
}

bool SRMove(SRRoute *route, int step) {
    if (!route || step == 0) return false;
    size_t current = ReconcileSelection(route);
    if (current == route->count) return false;
    size_t index = current;
    long long remaining = step;
    while (remaining != 0) {
        if (remaining > 0) {
            do {
                index++;
            } while (index < route->count && Blacklisted(route, &route->items[index]));
            if (index == route->count) return false;
            remaining--;
        } else {
            if (index == 0) return false;
            do {
                index--;
            } while (index > 0 && Blacklisted(route, &route->items[index]));
            if (Blacklisted(route, &route->items[index])) return false;
            remaining++;
        }
    }
    SelectIndex(route, index);
    route->manualSelection = true;
    return true;
}

bool SRBind(SRRoute *route, uint64_t id, int targetOffset,
            const char *approachKey, const char *approachName,
            const char *name, double now) {
    if (!route || id == 0 || !isfinite(now) || !ValidKey(approachKey)) return false;
    size_t found = route->count;
    for (size_t index = 0; index < route->count; index++) {
        if (route->items[index].signal.id != id ||
            route->items[index].signal.targetOffset != targetOffset) continue;
        if (found != route->count || route->items[index].signal.ambiguous)
            return false;
        found = index;
    }
    if (found == route->count) return false;
    double captureAge = now - route->items[found].signal.capturedAt;
    if (!isfinite(route->items[found].signal.capturedAt) ||
        route->items[found].signal.capturedAt <= 0.0 ||
        !isfinite(captureAge) || captureAge < 0.0 ||
        captureAge > SR_NATIVE_MAX_AGE_SECONDS) return false;
    SRItem next = route->items[found];
    bool sameDirection = next.bound && strcmp(next.approachKey, approachKey) == 0;
    next.bound = true;
    memcpy(next.approachKey, approachKey, strlen(approachKey) + 1);
    if (approachName || !sameDirection)
        CopyLabel(next.approachName, sizeof(next.approachName),
                  approachName ? approachName : approachKey);
    if (name || !sameDirection)
        CopyLabel(next.name, sizeof(next.name), name);
    SHIdentity identity = IdentityFor(&next);
    if (route->store && !SHUpsertIdentity(route->store, &identity)) return false;
    route->items[found] = next;
    route->now = now;
    RecordNative(route, &route->items[found], now);
    ReconcileSelection(route);
    return true;
}
