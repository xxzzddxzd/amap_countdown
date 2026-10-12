#include "SignalCapture.h"

#include <math.h>
#include <string.h>

enum {
    SC_CAR_STRIDE = 232,
    SC_CAR_MAX_COUNT = 512,
    SC_TRAVEL_STRIDE = 112,
    SC_TRAVEL_MAX_COUNT = 256,
    SC_INNER_STRIDE = 88,
    SC_INNER_MAX_COUNT = 32,
    SC_PHASE_STRIDE = 24,
    SC_CAR_MAX_PHASES = 64,
    SC_TRAVEL_MAX_PHASES = 32,
    SC_NORMALIZED_MAX_PHASES = SC_CAR_MAX_PHASES * 2
};

/* Match the existing in-process readers; these do not replace the native
 * callback's lifetime guarantee or prove that arbitrary addresses are mapped. */
static bool SCPointer(uintptr_t value, uintptr_t alignment) {
    return value >= UINT64_C(0x100000000) &&
           (value & (alignment - 1)) == 0 && (value >> 48) == 0;
}

static bool SCRange(uintptr_t begin, uintptr_t end, size_t stride,
                     size_t maximumCount, size_t *count) {
    *count = 0;
    if (begin == end) return begin == 0 || SCPointer(begin, 8);
    if (!SCPointer(begin, 8) || !SCPointer(end, 8) || end < begin ||
        end - begin > stride * maximumCount || (end - begin) % stride != 0)
        return false;
    *count = (size_t)(end - begin) / stride;
    return true;
}

static uintptr_t SCPtrAt(const void *object, size_t offset) {
    uintptr_t value = 0;
    memcpy(&value, (const unsigned char *)object + offset, sizeof(value));
    return value;
}

static int32_t SCIntAt(const void *object, size_t offset) {
    int32_t value = 0;
    memcpy(&value, (const unsigned char *)object + offset, sizeof(value));
    return value;
}

static uint64_t SCIdAt(const void *object, size_t offset) {
    uint64_t value = 0;
    memcpy(&value, (const unsigned char *)object + offset, sizeof(value));
    return value;
}

static int SCColor(int32_t code, bool car) {
    if (car) {
        if (code == 1 || code == 30) return 1;
        if (code == 11) return 3;
    } else {
        if (code == 1) return 1;
        if (code == 2 || code == 5) return 2;
        if (code == 10 || code == 11) return 3;
    }
    return 0;
}

static bool SCAppend(SHPhase *phases, size_t *count, int color,
                      double startsAt, double endsAt) {
    if (endsAt <= startsAt) return true;
    if (*count && phases[*count - 1].color == color &&
        phases[*count - 1].endsAt == startsAt) {
        if (endsAt - phases[*count - 1].startsAt > 999.0) return false;
        phases[*count - 1].endsAt = endsAt;
        return true;
    }
    if (*count >= SC_NORMALIZED_MAX_PHASES || endsAt - startsAt > 999.0)
        return false;
    phases[(*count)++] = (SHPhase){color, startsAt, endsAt};
    return true;
}

/* Validate the whole native table before publishing even a truncated prefix.
 * A bad/unknown row suppresses fallback for this observation, so old learned
 * data cannot mask an observed incompatible native state. Data availability
 * does not change the verified outer signal/occurrence identity. */
static bool SCPhases(uintptr_t begin, uintptr_t end, bool car,
                      int32_t yellowSeconds, SRSignal *signal) {
    size_t count = 0;
    if (!SCRange(begin, end, SC_PHASE_STRIDE,
                  car ? SC_CAR_MAX_PHASES : SC_TRAVEL_MAX_PHASES, &count))
        return false;
    SHPhase raw[SC_NORMALIZED_MAX_PHASES];
    size_t rawCount = 0;
    int64_t previousEnd = 0;
    for (size_t index = 0; index < count; ++index) {
        const unsigned char *row =
            (const unsigned char *)(begin + index * SC_PHASE_STRIDE);
        int32_t code = 0;
        int64_t startsAt = 0, endsAt = 0;
        memcpy(&code, row, sizeof(code));
        memcpy(&startsAt, row + 8, sizeof(startsAt));
        memcpy(&endsAt, row + 16, sizeof(endsAt));
        int color = SCColor(code, car);
        if (!color || startsAt <= 0 || endsAt <= startsAt ||
            endsAt - startsAt > (car ? 999 : 180) ||
            (index && startsAt < previousEnd))
            return false;

        if (!SCAppend(raw, &rawCount, color, (double)startsAt, (double)endsAt))
            return false;
        previousEnd = endsAt;
    }

    SHPhase normalized[SC_NORMALIZED_MAX_PHASES];
    size_t normalizedCount = 0;
    for (size_t index = 0; index < rawCount; ++index) {
        int color = raw[index].color;
        double startsAt = raw[index].startsAt, endsAt = raw[index].endsAt;
        /* Merge native fragments before applying the car yellow threshold;
         * otherwise consecutive green fragments manufacture yellow cycles. */
        if (!car && index && raw[index - 1].color == 3 && color == 1 &&
            startsAt - raw[index - 1].endsAt >= 1.0 &&
            startsAt - raw[index - 1].endsAt <= 5.0 &&
            !SCAppend(normalized, &normalizedCount, 2,
                        raw[index - 1].endsAt, startsAt))
            return false;
        if (car && color == 3 && yellowSeconds >= 0) {
            double yellowStart = endsAt - yellowSeconds;
            if (yellowStart < startsAt) yellowStart = startsAt;
            if (!SCAppend(normalized, &normalizedCount, 3,
                            startsAt, yellowStart) ||
                !SCAppend(normalized, &normalizedCount, 2,
                            yellowStart, endsAt))
                return false;
        } else if (!SCAppend(normalized, &normalizedCount, color,
                               startsAt, endsAt)) {
            return false;
        }
    }
    signal->phaseCount = (unsigned)(normalizedCount < SR_MAX_PHASES
        ? normalizedCount : SR_MAX_PHASES);
    memcpy(signal->phases, normalized, signal->phaseCount * sizeof(SHPhase));
    return true;
}

static void SCWaiting(SRSignal *signal) {
    signal->dataUnavailable = true;
    signal->phaseCount = 0;
    memset(signal->phases, 0, sizeof(signal->phases));
}

/* Ordered insertion keeps the nearest capacity signals across the COMPLETE
 * vector, including missing-ID and unsupported waiting slots. Equal distances
 * retain native order; the route layer handles occurrence ambiguity. */
static void SCKeep(const SRSignal *signal, SRSignal *out, size_t capacity,
                    size_t *count) {
    if (!capacity) return;
    size_t position = 0;
    while (position < *count &&
           out[position].distanceMeters <= signal->distanceMeters)
        ++position;
    if (position == capacity) return;
    size_t newCount = *count < capacity ? *count + 1 : *count;
    if (position + 1 < newCount)
        memmove(out + position + 1, out + position,
                  (newCount - position - 1) * sizeof(*out));
    out[position] = *signal;
    *count = newCount;
}

static bool SCArguments(const void *object, int currentOffset,
                         double capturedAt, SRSignal *out, size_t capacity,
                         size_t *outCount) {
    if (!outCount) return false;
    *outCount = 0;
    return SCPointer((uintptr_t)object, 8) && currentOffset >= 0 &&
           isfinite(capturedAt) && capturedAt > 0.0 && (!capacity || out);
}

bool SCReadCar(const void *feed, int currentOffset, double capturedAt,
               SRSignal *out, size_t capacity, size_t *outCount) {
    if (!SCArguments(feed, currentOffset, capturedAt, out, capacity, outCount))
        return false;
    uintptr_t begin = SCPtrAt(feed, 296), end = SCPtrAt(feed, 304);
    size_t count = 0;
    if (!SCRange(begin, end, SC_CAR_STRIDE, SC_CAR_MAX_COUNT, &count))
        return false;
    for (size_t index = 0; index < count; ++index) {
        const void *item = (const void *)(begin + index * SC_CAR_STRIDE);
        int target = SCIntAt(item, 0x4c);
        if (target < 0 || target > currentOffset) continue;
        SRSignal signal = {
            .id = SCIdAt(item, 0x60), .targetOffset = target,
            .distanceMeters = (double)((int64_t)currentOffset - target),
            .source = 3, .capturedAt = capturedAt
        };
        if (!signal.id || signal.id == UINT64_MAX) {
            signal.id = 0;
            signal.ambiguous = true;
            SCWaiting(&signal);
        } else if (SCIntAt(item, 8) != 1) {
            SCWaiting(&signal);
        } else if (!SCPhases(SCPtrAt(item, 136), SCPtrAt(item, 144), true,
                               SCIntAt(item, 224), &signal)) {
            SCWaiting(&signal);
        }
        SCKeep(&signal, out, capacity, outCount);
    }
    return true;
}

bool SCReadTravel(const void *processor, int currentOffset, double capturedAt,
                  SRSignal *out, size_t capacity, size_t *outCount) {
    if (!SCArguments(processor, currentOffset, capturedAt,
                       out, capacity, outCount))
        return false;
    uintptr_t begin = SCPtrAt(processor, 0x68), end = SCPtrAt(processor, 0x70);
    size_t count = 0;
    if (!SCRange(begin, end, SC_TRAVEL_STRIDE, SC_TRAVEL_MAX_COUNT, &count))
        return false;
    for (size_t index = 0; index < count; ++index) {
        const void *item = (const void *)(begin + index * SC_TRAVEL_STRIDE);
        int target = SCIntAt(item, 0x44);
        if (target < 0 || target > currentOffset) continue;
        SRSignal signal = {
            .id = SCIdAt(item, 8), .targetOffset = target,
            .distanceMeters = (double)((int64_t)currentOffset - target),
            .source = 2, .capturedAt = capturedAt
        };
        uintptr_t innerBegin = SCPtrAt(item, 0x28);
        uintptr_t innerEnd = SCPtrAt(item, 0x30);
        size_t innerCount = 0;
        if (!signal.id || signal.id == UINT64_MAX) {
            signal.id = 0;
            signal.ambiguous = true;
            SCWaiting(&signal);
        } else if (SCIntAt(item, 0x48) < target ||
                   !SCRange(innerBegin, innerEnd, SC_INNER_STRIDE,
                               SC_INNER_MAX_COUNT, &innerCount) ||
                   innerCount != 1) {
            SCWaiting(&signal);
        } else {
            const void *light = (const void *)innerBegin;
            if (!SCPhases(SCPtrAt(light, 0x10), SCPtrAt(light, 0x18),
                             false, -1, &signal))
                SCWaiting(&signal);
        }
        SCKeep(&signal, out, capacity, outCount);
    }
    return true;
}
