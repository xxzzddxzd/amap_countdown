// AMap Signal Countdown — personal rootless tweak for AMap 16.11.1.
// Reads only AMap's in-process native traffic-light, route-distance, and travel
// speed outputs. No OCR, network interception, GPS/Core Location collection,
// geospatial distance inference, or view-tree scanning.

#include "AdviceStrategy.h"

#ifndef DSH_PLUGIN_VERSION
#define DSH_PLUGIN_VERSION "development"
#endif

#include <dlfcn.h>
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>

typedef signed char BOOL;
typedef unsigned long NSUInteger;
typedef long NSInteger;
typedef double CGFloat;
typedef void *id;
typedef void *Class;
typedef void *SEL;
typedef void (*IMP)(void);
typedef struct { CGFloat x, y; } CGPoint;
typedef struct { CGFloat width, height; } CGSize;
typedef struct { CGPoint origin; CGSize size; } CGRect;

#ifndef YES
#define YES ((BOOL)1)
#define NO ((BOOL)0)
#endif

extern Class objc_getClass(const char *name);
extern SEL sel_registerName(const char *name);
extern id objc_msgSend(id self, SEL op, ...);
extern Class objc_allocateClassPair(Class superclass, const char *name, size_t extraBytes);
extern void objc_registerClassPair(Class cls);
extern BOOL class_addMethod(Class cls, SEL name, IMP imp, const char *types);
extern uint32_t _dyld_image_count(void);
extern const char *_dyld_get_image_name(uint32_t imageIndex);
extern const void *_dyld_get_image_header(uint32_t imageIndex);

static SEL S(const char *name) { return sel_registerName(name); }
static Class C(const char *name) { return objc_getClass(name); }

static id MsgId(id target, const char *selector) {
    return target ? ((id (*)(id, SEL))objc_msgSend)(target, S(selector)) : (id)0;
}

static void MsgVoid(id target, const char *selector) {
    if (target) ((void (*)(id, SEL))objc_msgSend)(target, S(selector));
}

static void MsgVoidObj(id target, const char *selector, id object) {
    if (target) ((void (*)(id, SEL, id))objc_msgSend)(target, S(selector), object);
}

static BOOL MsgBool(id target, const char *selector) {
    return target ? ((BOOL (*)(id, SEL))objc_msgSend)(target, S(selector)) : NO;
}

static BOOL Responds(id target, const char *selector) {
    return target
        ? ((BOOL (*)(id, SEL, SEL))objc_msgSend)(target, S("respondsToSelector:"), S(selector))
        : NO;
}

static NSUInteger Count(id collection) {
    return collection
        ? ((NSUInteger (*)(id, SEL))objc_msgSend)(collection, S("count"))
        : 0;
}

static id At(id collection, NSUInteger index) {
    return collection
        ? ((id (*)(id, SEL, NSUInteger))objc_msgSend)(collection, S("objectAtIndex:"), index)
        : (id)0;
}

static CGRect MsgRect(id target, const char *selector) {
    CGRect zero = {{0, 0}, {0, 0}};
    return target ? ((CGRect (*)(id, SEL))objc_msgSend)(target, S(selector)) : zero;
}

static CGSize MsgSize(id target, const char *selector, CGSize constraint) {
    CGSize zero = {0, 0};
    return target
        ? ((CGSize (*)(id, SEL, CGSize))objc_msgSend)(
              target, S(selector), constraint)
        : zero;
}

static void SetRect(id target, const char *selector, CGRect rect) {
    if (target) ((void (*)(id, SEL, CGRect))objc_msgSend)(target, S(selector), rect);
}

static id NSStr(const char *utf8) {
    Class cls = C("NSString");
    return cls && utf8
        ? ((id (*)(id, SEL, const char *))objc_msgSend)((id)cls, S("stringWithUTF8String:"), utf8)
        : (id)0;
}

static double MonotonicSeconds(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (double)value.tv_sec + (double)value.tv_nsec / 1000000000.0;
}

static double WallSeconds(void) {
    struct timeval value;
    gettimeofday(&value, 0);
    return (double)value.tv_sec + (double)value.tv_usec / 1000000.0;
}

static BOOL PlausibleNativePointer(uintptr_t pointer, uintptr_t alignment) {
    return pointer >= 0x100000000ULL &&
           (pointer & (alignment - 1)) == 0 &&
           (pointer >> 48) == 0;
}

static BOOL PlausibleNativeRange(uintptr_t begin, uintptr_t end,
                                 uintptr_t maxBytes, uintptr_t alignment) {
    return PlausibleNativePointer(begin, alignment) &&
           PlausibleNativePointer(end, alignment) && end >= begin &&
           end - begin <= maxBytes;
}

static char gLogPath[768];

static void LogLine(const char *format, ...) {
    if (!gLogPath[0]) {
        const char *tmp = getenv("TMPDIR");
        if (!tmp || !*tmp) tmp = "/tmp/";
        snprintf(gLogPath, sizeof(gLogPath), "%s%s", tmp,
                 tmp[strlen(tmp) - 1] == '/' ? "amap-signal-countdown.log"
                                              : "/amap-signal-countdown.log");
    }
    FILE *file = fopen(gLogPath, "a");
    if (!file) return;
    time_t now = time(0);
    struct tm local;
    localtime_r(&now, &local);
    fprintf(file, "%02d:%02d:%02d ", local.tm_hour, local.tm_min, local.tm_sec);
    va_list arguments;
    va_start(arguments, format);
    vfprintf(file, format, arguments);
    va_end(arguments);
    fputc('\n', file);
    fclose(file);
}

typedef void (*MSHookFunctionFn)(void *symbol, void *replacement, void **original);
typedef void *(*SignalStatusSerializeFn)(void *model, void *serializer);
typedef void *(*SignalCountdownSerializeFn)(void *model, void *serializer);
typedef void (*DynamicTrafficSignalUpdateFn)(void *processor, void *data,
                                             void *componentName);
typedef uintptr_t (*ActiveTravelSignalRouteFn)(void *processor, void *signals,
                                               void *navigationState);
typedef int (*ActiveTrafficRecordsFn)(void *records);
typedef uintptr_t (*CarTrafficInputFn)(void *processor, const void *feed,
                                       const void *navigationState);
typedef int64_t (*TravelLocationUpdateFn)(void *service,
                                          const void *locationInfo,
                                          int32_t pointType);
typedef uintptr_t (*TravelRouteForTypeFn)(void *routes, int32_t routeType);
typedef int64_t (*TravelNaviInfoSerializeFn)(const uint8_t *info,
                                             void *writer);
typedef int32_t (*TravelRecommendSpeedFn)(void *provider, void *phases,
                                            uint32_t distanceMeters,
                                            int64_t currentTimeSeconds,
                                            int32_t averageSpeedKmh, int32_t maximumWindows);

typedef enum {
    LampUnknown = 0,
    LampRed,
    LampYellow,
    LampGreen
} LampState;

typedef enum {
    CountdownSourceUnknown = 0,
    CountdownSourceCar,
    CountdownSourceTravel,
    CountdownSourceCarInput
} CountdownSource;

static BOOL IsCarCountdownSource(CountdownSource source) {
    return source == CountdownSourceCar || source == CountdownSourceCarInput;
}

static SignalStatusSerializeFn gOriginalSignalStatusSerialize;
static SignalCountdownSerializeFn gOriginalSignalCountdownSerialize;
static DynamicTrafficSignalUpdateFn gOriginalDynamicTrafficSignalUpdate;
static ActiveTravelSignalRouteFn gOriginalActiveTravelSignalRoute;
static ActiveTrafficRecordsFn gOriginalActiveTrafficRecords;
static CarTrafficInputFn gOriginalCarTrafficInput;
static TravelLocationUpdateFn gOriginalTravelLocationUpdate;
static TravelRouteForTypeFn gTravelRouteForType;
static TravelNaviInfoSerializeFn gOriginalTravelNaviInfoSerialize;
static TravelRecommendSpeedFn gOriginalTravelRecommendSpeed;
static _Atomic int gNativeStatus = -1;
static _Atomic int gSerializedCarStatus = -1;
static _Atomic int64_t gSerializedCarRemainSeconds = -1;
static _Atomic double gSerializedCarCapturedAt;
static _Atomic double gSerializedCarUpdatedAt;
static _Atomic LampState gLampState = LampUnknown;
static _Atomic CountdownSource gCountdownSource = CountdownSourceUnknown;
static _Atomic double gPhaseEndMonotonic;
static _Atomic double gTimetableUpdatedAt;
static _Atomic double gCarUpdatedAt;
#define kMaxCarPhases 64
#define kCarTableBusy 0x8000000000000000ULL
static _Atomic uint64_t gCarTable[kMaxCarPhases * 3 + 1];
static atomic_flag gCarTableWriteLock = ATOMIC_FLAG_INIT;
static _Atomic double gCarTableCapturedAt;
static _Atomic uint64_t gCarTableSignalId;
static _Atomic int gCarTableYellowSeconds = -1;
// Diagnostic metadata only; never used to extend or select a cached light.
static _Atomic(const char *) gCarCaptureReason = "no-record";
static _Atomic uint64_t gCarCaptureSignalId;
static _Atomic int gCarCaptureCurrentStatus = -1;
static _Atomic double gCarCaptureAt;
// Main-thread publisher rejection reasons, included when the HUD becomes --.
static const char *gCarTableRejectReason = "not-evaluated";
static const char *gCarSerializedRejectReason = "not-evaluated";
static const char *gRawCarRejectReason = "not-evaluated";

// Native input before the car overlay's distance/lifecycle filter. The latest
// begun observation wins, including empty/unsupported input. Copy under a
// short lock so ARM64 readers cannot combine identity and phases from different
// callbacks. No pointers, coordinates, or simulated locations are retained.
typedef enum {
    RawCarNoInput = 0,
    RawCarInvalidInput,
    RawCarEmpty,
    RawCarNoUpcoming,
    RawCarAmbiguous,
    RawCarMissingIdentity,
    RawCarUnsupported,
    RawCarNoPhases,
    RawCarInvalidPhases,
    RawCarReady
} RawCarInputState;

typedef struct {
    double capturedAt;
    uint64_t observation;
    uint64_t signalId;
    RawCarInputState state;
    int distanceMeters;
    int displayLimit;
    int yellowSeconds;
    unsigned inputCount;
    int eligibleFlag;
    int currentOffset;
    int targetOffset;
    unsigned phaseCount;
    uint64_t phases[kMaxCarPhases * 3];
} RawCarInputSnapshot;

static BOOL LoadRawCarInput(RawCarInputSnapshot *snapshot);
static BOOL LoadCurrentCarTarget(uint64_t *signalId, const char **reason,
                                 RawCarInputSnapshot *snapshotOut);
static BOOL CommitIdentifiedCarDisplay(const RawCarInputSnapshot *snapshot,
                                      LampState state, double phaseEnd,
                                      unsigned expectedDisplayGeneration,
                                      CountdownSource source);

static RawCarInputSnapshot gRawCarInput;
static _Atomic uint64_t gRawCarObservationSequence;
static atomic_flag gRawCarInputLock = ATOMIC_FLAG_INIT;

typedef struct {
    const char *reason;
    int recordFlag;
    int currentStatus;
    int nextStatus;
    int64_t nativeRemaining;
    int phaseCode;
    unsigned phaseCount;
    double phaseRemaining;
    BOOL oldGateMismatch;
} CarCaptureDiagnostic;

static _Atomic unsigned gTrafficSignalGeneration;
static _Atomic unsigned gTrafficSignalOuterCount;
static _Atomic unsigned gTrafficSignalInnerCount;
static _Atomic unsigned gTrafficSignalPhaseCount;
static _Atomic unsigned gTrafficSignalPublishedCount;
static _Atomic uint64_t gTrafficSignalPhaseRows[12];
static _Atomic uint64_t gCyclingTableSignalId;
static _Atomic double gCyclingTableUpdatedAt;

static _Atomic unsigned gActiveSignalRouteGeneration;
static _Atomic unsigned gActiveSignalRouteCandidateCount;
static _Atomic int gActiveSignalRouteDistance = -1;
static _Atomic int gActiveSignalCurrentOffset = -1;
static _Atomic int gActiveSignalTargetOffset = -1;
static _Atomic int gActiveSignalRangeEnd = -1;
static _Atomic uint64_t gActiveSignalRouteId;
static _Atomic double gActiveSignalRouteUpdatedAt;
static _Atomic unsigned gTravelNaviInfoGeneration;
static _Atomic int gTravelCurrentSpeedKmh = -1;
static _Atomic int gTravelMode = -1;
static _Atomic int gTravelNavigationStatus = -1;
static _Atomic double gTravelNaviInfoUpdatedAt;
static _Atomic int gTravelAdviceDistanceMeters = -1;
static _Atomic int gTravelAverageSpeedKmh = -1;
static _Atomic int gTravelNativeRecommendedSpeedKmh = -1;
static atomic_flag gDisplayWriteLock = ATOMIC_FLAG_INIT;
static _Atomic unsigned gDisplayGeneration;
// Seqlock-protected snapshot of the native bicycle phase table written by
// HookTravelRecommendSpeed on the GNaviTravel thread and read by the HUD
// timer on the main thread. Header word: bit 63 is the busy flag, bits 8..62
// the generation, bits 0..7 the record count; payload is count triples of
// {code, startsAt, endsAt} in absolute epoch seconds.
#define kMaxCyclingPhases 32
#define kCyclingTableBusy 0x8000000000000000ULL
static _Atomic uint64_t gCyclingTable[kMaxCyclingPhases * 3 + 1];

#define kTravelAdviceSnapshotBusy 0x8000000000000000ULL
#define kTravelAdviceSnapshotRows 8
static _Atomic uint64_t gTravelAdviceSnapshot[
    kTravelAdviceSnapshotRows + kMaxCyclingPhases * 3];
static atomic_flag gTravelAdviceSnapshotWriteLock = ATOMIC_FLAG_INIT;

typedef struct {
    double capturedAt;
    uint64_t signalId;
    int distanceMeters;
    int averageSpeedKmh;
    int nativeRecommendedSpeedKmh;
    int maximumWindows;
    int64_t currentTimeSeconds;
    uint32_t phaseCount;
    uint64_t phaseRows[kMaxCyclingPhases * 3];
} TravelAdviceSnapshot;

typedef struct {
    unsigned candidateCount;
    int distanceMeters;
    int currentOffset;
    int targetOffset;
    int rangeEnd;
    uint64_t signalId;
    double updatedAt;
} ActiveSignalSnapshot;
static id gController;
static id gTimer;
static id gBall;
static id gBallLampLabel;
static id gBallSecondsLabel;
static id gBallDistanceLabel;
static id gFullView;
static id gFullLampLabel;
static id gFullSecondsLabel;
static id gFullUnitLabel;
static id gFullSpeedLabel;
static id gFullAdviceActionLabel;
static id gFullAdviceDetailLabel;
static id gFullDisclaimerLabel;
static double gPreferredAdviceWindowStart;
static uint64_t gAdviceSignalId;
static AdviceStabilizer gAdviceStabilizer;
static BOOL gExpanded;
static BOOL gBallPositioned;
static CGFloat gFullNumberLayoutWidth;
static CGFloat gFullNumberLayoutHeight;
static int gCurrentSeconds = -1;
static BOOL gStarted;
static BOOL gHooksInstalled;
static void UpdateOverlay(void);

static uintptr_t AMapMainImageBase(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t index = 0; index < count; index++) {
        const char *name = _dyld_get_image_name(index);
        if (!name) continue;
        const char *slash = strrchr(name, '/');
        const char *leaf = slash ? slash + 1 : name;
        if (strcmp(leaf, "AMapiPhone") == 0)
            return (uintptr_t)_dyld_get_image_header(index);
    }
    return 0;
}

static uint64_t DoubleToBits(double value) {
    uint64_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static double BitsToDouble(uint64_t bits) {
    double value = 0.0;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static BOOL LoadActiveSignalSnapshot(ActiveSignalSnapshot *snapshot) {
    if (!snapshot) return NO;
    for (unsigned attempt = 0; attempt < 8; ++attempt) {
        unsigned before = atomic_load_explicit(
            &gActiveSignalRouteGeneration, memory_order_acquire);
        if (before & 1U) continue;
        ActiveSignalSnapshot value = {
            .candidateCount = atomic_load_explicit(
                &gActiveSignalRouteCandidateCount, memory_order_relaxed),
            .distanceMeters = atomic_load_explicit(
                &gActiveSignalRouteDistance, memory_order_relaxed),
            .currentOffset = atomic_load_explicit(
                &gActiveSignalCurrentOffset, memory_order_relaxed),
            .targetOffset = atomic_load_explicit(
                &gActiveSignalTargetOffset, memory_order_relaxed),
            .rangeEnd = atomic_load_explicit(
                &gActiveSignalRangeEnd, memory_order_relaxed),
            .signalId = atomic_load_explicit(
                &gActiveSignalRouteId, memory_order_relaxed),
            .updatedAt = atomic_load_explicit(
                &gActiveSignalRouteUpdatedAt, memory_order_relaxed),
        };
        unsigned after = atomic_load_explicit(
            &gActiveSignalRouteGeneration, memory_order_acquire);
        if (before == after && !(after & 1U)) {
            *snapshot = value;
            return after != 0;
        }
    }
    return NO;
}

// Car-navigation model mappings verified on AMap 16.11.1.
static LampState LampForNativeStatus(int status, int phaseCode) {
    if (status == 4) return LampGreen;
    if (status == 5) return LampYellow;
    if (status == 2 || status == 3 || status == 8) return LampRed;
    if (phaseCode == 11) return LampGreen;
    if (phaseCode == 30 || phaseCode == 1) return LampRed;
    return LampUnknown;
}

static BOOL PhaseCodeMatchesNative(int phaseCode, int status) {
    if (status == 4 || status == 5) return phaseCode == 11;
    if (status == 8) return phaseCode == 30;
    if (status == 2 || status == 3) return phaseCode == 1;
    return YES;
}

// Bicycle-navigation phase codes verified from the native timetable.
static LampState LampForCyclingPhase(int code) {
    if (code == 1) return LampRed;
    if (code == 10 || code == 11) return LampGreen;
    if (code == 2 || code == 5) return LampYellow;
    return LampUnknown;
}

static void PublishDisplayState(LampState state, double phaseEnd,
                                double updatedAt, CountdownSource source) {
    while (atomic_flag_test_and_set_explicit(
               &gDisplayWriteLock, memory_order_acquire)) {}
    unsigned generation = atomic_load_explicit(
        &gDisplayGeneration, memory_order_relaxed);
    atomic_store_explicit(&gDisplayGeneration, generation + 1U, memory_order_release);
    atomic_store_explicit(&gLampState, state, memory_order_relaxed);
    atomic_store_explicit(&gCountdownSource, source, memory_order_relaxed);
    atomic_store_explicit(&gPhaseEndMonotonic, phaseEnd, memory_order_relaxed);
    atomic_store_explicit(&gTimetableUpdatedAt, updatedAt, memory_order_relaxed);
    atomic_store_explicit(&gDisplayGeneration, generation + 2U, memory_order_release);
    atomic_flag_clear_explicit(&gDisplayWriteLock, memory_order_release);
}

static BOOL LoadDisplayState(LampState *state, double *phaseEnd,
                             double *updatedAt, CountdownSource *source) {
    // Use the same short lock as publishers and source-conditional clearing;
    // the lamp, source, expiry, and capture time must be one ARM64 snapshot.
    while (atomic_flag_test_and_set_explicit(&gDisplayWriteLock,
                                             memory_order_acquire)) {}
    *state = atomic_load_explicit(&gLampState, memory_order_relaxed);
    *phaseEnd = atomic_load_explicit(&gPhaseEndMonotonic, memory_order_relaxed);
    *updatedAt = atomic_load_explicit(&gTimetableUpdatedAt, memory_order_relaxed);
    *source = atomic_load_explicit(&gCountdownSource, memory_order_relaxed);
    atomic_flag_clear_explicit(&gDisplayWriteLock, memory_order_release);
    return YES;
}

static BOOL LoadCyclingTable(uint64_t *out, uint32_t *outCount) {
    for (int attempt = 0; attempt < 4; attempt++) {
        uint64_t header = atomic_load_explicit(
            &gCyclingTable[0], memory_order_acquire);
        if (header & kCyclingTableBusy) continue;
        uint32_t count = (uint32_t)(header & 0xff);
        if (count > kMaxCyclingPhases) continue;
        for (uint32_t index = 0; index < count * 3; index++)
            out[index] = atomic_load_explicit(
                &gCyclingTable[1 + index], memory_order_relaxed);
        uint64_t check = atomic_load_explicit(
            &gCyclingTable[0], memory_order_acquire);
        if (check != header) continue;
        *outCount = count;
        return YES;
    }
    return NO;
}

static BOOL LoadTaggedCyclingTable(uint64_t *rows, uint32_t *count,
                                   uint64_t *signalId) {
    if (!rows || !count || !signalId) return NO;
    for (unsigned attempt = 0; attempt < 4; ++attempt) {
        unsigned before = atomic_load_explicit(
            &gTrafficSignalGeneration, memory_order_acquire);
        if (!before) return NO;
        unsigned outerCount = atomic_load_explicit(
            &gTrafficSignalOuterCount, memory_order_relaxed);
        unsigned innerCount = atomic_load_explicit(
            &gTrafficSignalInnerCount, memory_order_relaxed);
        uint64_t localSignalId = atomic_load_explicit(
            &gCyclingTableSignalId, memory_order_relaxed);
        uint32_t localCount = 0;
        if (outerCount != 1 || innerCount != 1 || !localSignalId ||
            !LoadCyclingTable(rows, &localCount) || !localCount)
            return NO;
        unsigned after = atomic_load_explicit(
            &gTrafficSignalGeneration, memory_order_acquire);
        if (before == after) {
            *count = localCount;
            *signalId = localSignalId;
            return YES;
        }
    }
    return NO;
}

#define kMaxAdviceGreenWindows 16

static size_t BuildAdviceGreenWindows(const uint64_t *rows,
                                      uint32_t count,
                                      double wallNow,
                                      AdviceGreenWindow *windows,
                                      size_t capacity) {
    if (!rows || !count || !windows || !capacity) return 0;
    size_t kept = 0;
    for (uint32_t index = 0; index < count; ++index) {
        int32_t code = (int32_t)(uint32_t)rows[index * 3];
        double startsAt = (double)(int64_t)rows[index * 3 + 1];
        double endsAt = (double)(int64_t)rows[index * 3 + 2];
        if (LampForCyclingPhase(code) != LampGreen || endsAt <= wallNow ||
            startsAt <= 0.0 || endsAt <= startsAt)
            continue;
        if (kept && startsAt <= windows[kept - 1].endEpochSeconds + 0.5) {
            if (endsAt > windows[kept - 1].endEpochSeconds)
                windows[kept - 1].endEpochSeconds = endsAt;
            continue;
        }
        if (kept == capacity) break;
        windows[kept++] = (AdviceGreenWindow){
            .startEpochSeconds = startsAt,
            .endEpochSeconds = endsAt,
        };
    }
    return kept;
}

static BOOL PublishLiveCyclingPhase(double wallNow, double monotonicNow) {
    ActiveSignalSnapshot active = {0};
    uint64_t rows[kMaxCyclingPhases * 3];
    uint32_t count = 0;
    uint64_t tableSignalId = 0;
    if (!LoadActiveSignalSnapshot(&active) || active.candidateCount != 1 ||
        !active.signalId || wallNow - active.updatedAt < 0.0 ||
        wallNow - active.updatedAt > 2.5 ||
        !LoadTaggedCyclingTable(rows, &count, &tableSignalId) ||
        tableSignalId != active.signalId)
        return NO;

    int64_t now = (int64_t)wallNow;
    LampState state = LampUnknown;
    int64_t endsAt = 0;
    for (uint32_t index = 0; index < count; index++) {
        int32_t code = (int32_t)(uint32_t)rows[index * 3];
        int64_t startsAt = (int64_t)rows[index * 3 + 1];
        int64_t recordEnd = (int64_t)rows[index * 3 + 2];
        LampState current = LampForCyclingPhase(code);
        if (current == LampUnknown || startsAt <= 0 || recordEnd <= startsAt)
            continue;

        // AMap omits the three-second yellow interval between green and red;
        // it appears as a short gap between the two records.
        if (state == LampUnknown && current == LampRed && index > 0) {
            int32_t previousCode = (int32_t)(uint32_t)rows[(index - 1) * 3];
            int64_t previousEnd = (int64_t)rows[(index - 1) * 3 + 2];
            if (LampForCyclingPhase(previousCode) == LampGreen &&
                previousEnd <= now && now < startsAt &&
                startsAt - previousEnd >= 1 && startsAt - previousEnd <= 5) {
                state = LampYellow;
                endsAt = startsAt;
                break;
            }
        }

        if (startsAt <= now && now < recordEnd) {
            state = current;
            endsAt = recordEnd;
            break;
        }
    }

    if (state == LampUnknown || endsAt <= now) {
        static _Atomic double lastWalkMiss;
        double wnow2 = WallSeconds();
        if (wnow2 - atomic_load_explicit(&lastWalkMiss,
                memory_order_relaxed) > 10.0) {
            atomic_store_explicit(&lastWalkMiss, wnow2,
                                  memory_order_relaxed);
            LogLine("walk miss now=%lld count=%u", (long long)now, count);
        }
        return NO;
    }
    double remaining = (double)(endsAt - now);
    if (remaining > 180.0) return NO;
    static _Atomic double lastWalkHit;
    double wnow = WallSeconds();
    if (wnow - atomic_load_explicit(&lastWalkHit,
            memory_order_relaxed) > 10.0) {
        atomic_store_explicit(&lastWalkHit, wnow, memory_order_relaxed);
        LogLine("walk hit state=%d remain=%.0f", (int)state, remaining);
    }
    PublishDisplayState(state, monotonicNow + remaining, monotonicNow,
                        CountdownSourceTravel);
    return YES;
}

static void *HookSignalStatusSerialize(void *model, void *serializer) {
    if (model) {
        int status = -1;
        memcpy(&status, (const unsigned char *)model + 12, sizeof(status));
        if (status >= 2 && status <= 8) {
            atomic_store_explicit(&gNativeStatus, status, memory_order_release);
            static _Atomic double lastLogged;
            double now = WallSeconds();
            if (now - atomic_load_explicit(&lastLogged, memory_order_relaxed) > 10.0) {
                atomic_store_explicit(&lastLogged, now, memory_order_relaxed);
                LogLine("signal status serializer status=%d", status);
            }
        }
    }
    return gOriginalSignalStatusSerialize
        ? gOriginalSignalStatusSerialize(model, serializer) : 0;
}

// Official drive/cruise countdown JSON model. This sibling serializer carries
// the exact status and remainTime already rendered by AMap's own map UI.
static void *HookSignalCountdownSerialize(void *model, void *serializer) {
    if (model) {
        int32_t status = -1;
        int64_t remainSeconds = -1;
        memcpy(&status, (const unsigned char *)model + 0x08,
               sizeof(status));
        memcpy(&remainSeconds, (const unsigned char *)model + 0x10,
               sizeof(remainSeconds));
        double wallNow = WallSeconds();
        if (status >= 0 && status <= 20 && remainSeconds >= 0 &&
            remainSeconds <= 999) {
            atomic_store_explicit(&gSerializedCarStatus, status,
                                  memory_order_relaxed);
            atomic_store_explicit(&gSerializedCarRemainSeconds,
                                  remainSeconds, memory_order_relaxed);
            atomic_store_explicit(&gSerializedCarCapturedAt,
                                  MonotonicSeconds(), memory_order_relaxed);
            atomic_store_explicit(&gSerializedCarUpdatedAt, wallNow,
                                  memory_order_release);
        }
        static _Atomic int lastStatus = -999;
        static _Atomic int64_t lastRemain = -999;
        int priorStatus = atomic_load_explicit(&lastStatus,
                                               memory_order_relaxed);
        int64_t priorRemain = atomic_load_explicit(&lastRemain,
                                                   memory_order_relaxed);
        if (status != priorStatus || remainSeconds != priorRemain) {
            atomic_store_explicit(&lastStatus, status, memory_order_relaxed);
            atomic_store_explicit(&lastRemain, remainSeconds,
                                  memory_order_relaxed);
            LogLine("signal countdown serializer status=%d remain=%lld",
                    status, (long long)remainSeconds);
        }
    }
    return gOriginalSignalCountdownSerialize
        ? gOriginalSignalCountdownSerialize(model, serializer) : 0;
}

static size_t PublishCarPhaseRange(uintptr_t begin, uintptr_t end,
                                   double capturedAt, uint64_t signalId,
                                   int yellowSeconds) {
    if (!PlausibleNativeRange(begin, end, kMaxCarPhases * 24, 8) ||
        end <= begin || (end - begin) % 24 != 0)
        return 0;
    size_t count = (size_t)(end - begin) / 24;
    uint64_t rows[kMaxCarPhases * 3];
    size_t kept = 0;
    for (size_t index = 0; index < count; ++index) {
        const unsigned char *phase =
            (const unsigned char *)(begin + index * 24);
        int32_t code = 0;
        int64_t startsAt = 0, endsAt = 0;
        memcpy(&code, phase, sizeof(code));
        memcpy(&startsAt, phase + 8, sizeof(startsAt));
        memcpy(&endsAt, phase + 16, sizeof(endsAt));
        if ((code != 1 && code != 11 && code != 30) || startsAt <= 0 ||
            endsAt <= startsAt || endsAt - startsAt > 999)
            continue;
        rows[kept * 3] = (uint32_t)code;
        rows[kept * 3 + 1] = (uint64_t)startsAt;
        rows[kept * 3 + 2] = (uint64_t)endsAt;
        kept++;
    }
    if (!kept) return 0;

    while (atomic_flag_test_and_set_explicit(
               &gCarTableWriteLock, memory_order_acquire)) {}
    uint64_t header = atomic_load_explicit(&gCarTable[0],
                                            memory_order_relaxed);
    atomic_store_explicit(&gCarTable[0], header | kCarTableBusy,
                          memory_order_relaxed);
    for (size_t index = 0; index < kept * 3; ++index)
        atomic_store_explicit(&gCarTable[1 + index], rows[index],
                              memory_order_relaxed);
    atomic_store_explicit(&gCarTableCapturedAt, capturedAt,
                          memory_order_relaxed);
    atomic_store_explicit(&gCarTableSignalId, signalId,
                          memory_order_relaxed);
    atomic_store_explicit(&gCarTableYellowSeconds, yellowSeconds,
                          memory_order_relaxed);
    atomic_store_explicit(
        &gCarTable[0],
        ((header + 0x100ULL) & ~(kCarTableBusy | 0xffULL)) | kept,
        memory_order_release);
    atomic_flag_clear_explicit(&gCarTableWriteLock, memory_order_release);
    return kept;
}

static BOOL LoadCarTable(uint64_t *rows, uint32_t *count,
                         double *capturedAt, uint64_t *signalId,
                         int *yellowSeconds) {
    if (!rows || !count || !capturedAt || !signalId || !yellowSeconds) return NO;
    for (unsigned attempt = 0; attempt < 4; ++attempt) {
        uint64_t header = atomic_load_explicit(&gCarTable[0],
                                               memory_order_acquire);
        if (header & kCarTableBusy) continue;
        uint32_t localCount = (uint32_t)(header & 0xffULL);
        if (!localCount || localCount > kMaxCarPhases) return NO;
        for (uint32_t index = 0; index < localCount * 3; ++index)
            rows[index] = atomic_load_explicit(&gCarTable[1 + index],
                                               memory_order_relaxed);
        double localCapturedAt = atomic_load_explicit(
            &gCarTableCapturedAt, memory_order_relaxed);
        uint64_t localSignalId = atomic_load_explicit(
            &gCarTableSignalId, memory_order_relaxed);
        int localYellowSeconds = atomic_load_explicit(
            &gCarTableYellowSeconds, memory_order_relaxed);
        uint64_t check = atomic_load_explicit(&gCarTable[0],
                                              memory_order_acquire);
        if (check == header) {
            *count = localCount;
            *capturedAt = localCapturedAt;
            *signalId = localSignalId;
            *yellowSeconds = localYellowSeconds;
            return YES;
        }
    }
    return NO;
}

static BOOL PublishSerializedCarCountdown(double wallNow,
                                             double monotonicNow) {
    (void)wallNow;
    (void)monotonicNow;
    // This model has no verified signal ID. Keep observing it for diagnostics,
    // but it must not overwrite a countdown selected for a known intersection.
    gCarSerializedRejectReason = atomic_load_explicit(
        &gSerializedCarUpdatedAt, memory_order_acquire) > 0.0
        ? "unidentified-serialized-signal" : "no-sample";
    return NO;
}

static BOOL PublishLiveCarPhase(double wallNow, double monotonicNow,
                                unsigned expectedDisplayGeneration) {
    gCarTableRejectReason = "cache-empty-or-busy";
    uint64_t rows[kMaxCarPhases * 3];
    uint32_t count = 0;
    double capturedAt = 0.0;
    uint64_t tableSignalId = 0;
    double tableAge = 0.0;
    int yellowSeconds = -1;
    RawCarInputSnapshot rawTarget = {0};
    if (!LoadCarTable(rows, &count, &capturedAt, &tableSignalId, &yellowSeconds))
        return NO;
    tableAge = monotonicNow - capturedAt;
    gCarTableRejectReason = "clock-invalid";
    if (!isfinite(tableAge) || tableAge < 0.0) return NO;

    ActiveSignalSnapshot active = {0};
    BOOL activeTravelSignal = LoadActiveSignalSnapshot(&active) &&
        active.candidateCount == 1 && active.signalId != 0 &&
        wallNow - active.updatedAt >= 0.0 &&
        wallNow - active.updatedAt <= 2.5;
    double travelAge = wallNow - atomic_load_explicit(
        &gTravelNaviInfoUpdatedAt, memory_order_relaxed);
    BOOL travelActive = travelAge >= 0.0 && travelAge <= 2.5;
    if (activeTravelSignal) {
        // A car timetable may bridge a mode switch only for the exact same
        // physical signal ID and only within a short prediction horizon.
        gCarTableRejectReason = "travel-id-mismatch";
        if (tableSignalId != active.signalId) return NO;
        gCarTableRejectReason = "bridge-age-120s";
        if (tableAge > 120.0) return NO;
    } else {
        // Keep the existing identity and age limits. Fix capture, rather than
        // allowing an unrefreshed previous light to survive these safeguards.
        gCarTableRejectReason = "travel-without-signal";
        if (travelActive) return NO;
        uint64_t currentCarSignalId = 0;
        if (!LoadCurrentCarTarget(&currentCarSignalId, &gCarTableRejectReason,
                                  &rawTarget)) return NO;
        gCarTableRejectReason = "current-car-id-mismatch";
        if (tableSignalId != currentCarSignalId) return NO;
        gCarTableRejectReason = "cache-age-15s";
        if (tableAge > 15.0) return NO;
    }

    gCarTableRejectReason = "no-current-phase";
    int64_t now = (int64_t)wallNow;
    for (uint32_t index = 0; index < count; ++index) {
        int32_t code = (int32_t)(uint32_t)rows[index * 3];
        int64_t startsAt = (int64_t)rows[index * 3 + 1];
        int64_t endsAt = (int64_t)rows[index * 3 + 2];
        if (startsAt > now || now >= endsAt) continue;
        // Color and yellow threshold belong to this identified signal, never
        // to the untagged global status serializer (which can describe another).
        LampState state = LampForNativeStatus(-1, code);
        if (state == LampUnknown) continue;
        double remaining = (double)endsAt - wallNow;
        if (state == LampGreen && yellowSeconds >= 0 && remaining <= yellowSeconds)
            state = LampYellow;
        if (activeTravelSignal) {
            PublishDisplayState(state, monotonicNow + remaining, monotonicNow,
                                CountdownSourceCar);
        } else if (!CommitIdentifiedCarDisplay(&rawTarget, state,
                    monotonicNow + remaining, expectedDisplayGeneration,
                    CountdownSourceCar)) {
            gCarTableRejectReason = "car-target-changed-at-commit";
            return NO;
        }
        gCarTableRejectReason = "ready";
        return YES;
    }
    return NO;
}

static BOOL PublishCurrentCarTimetable(const unsigned char *record,
                                       double wallNow, double monotonicNow,
                                       uint64_t signalId,
                                       CarCaptureDiagnostic *diagnostic) {
    diagnostic->reason = "invalid-record";
    if (!record || !PlausibleNativePointer((uintptr_t)record, 8)) return NO;
    memcpy(&diagnostic->recordFlag, record + 0x54, sizeof(int32_t));
    uintptr_t containerBegin = 0, containerEnd = 0;
    memcpy(&containerBegin, record + 0x28, sizeof(containerBegin));
    memcpy(&containerEnd, record + 0x30, sizeof(containerEnd));
    diagnostic->reason = "invalid-or-empty-lights";
    if (!PlausibleNativeRange(containerBegin, containerEnd, 4096, 8) ||
        containerEnd - containerBegin < 80 ||
        (containerEnd - containerBegin) % 80 != 0)
        return NO;

    // Native car HUD uses only lights.begin. 0x101200DDC updates CURRENT
    // status at +0x38 and remaining int64 seconds at +0x40 on every tick.
    // 0x101201398 starts at the NEXT phase row and writes +0x28/+0x30.
    // Comparing today's phase to +0x28 was rejecting valid current lights.
    uintptr_t container = containerBegin;
    int32_t engineStatus = -1, nextStatus = -1, yellowSeconds = -1;
    int64_t nativeRemaining = -1;
    memcpy(&yellowSeconds, (const void *)(container + 8), sizeof(yellowSeconds));
    memcpy(&engineStatus, (const void *)(container + 0x38), sizeof(engineStatus));
    memcpy(&nextStatus, (const void *)(container + 0x28), sizeof(nextStatus));
    memcpy(&nativeRemaining, (const void *)(container + 0x40),
           sizeof(nativeRemaining));
    diagnostic->currentStatus = engineStatus;
    diagnostic->nextStatus = nextStatus;
    diagnostic->nativeRemaining = nativeRemaining;
    diagnostic->reason = "first-light-inactive";
    if (engineStatus == 1) return NO;
    diagnostic->reason = "unsupported-current-status";
    LampState state = LampForNativeStatus(engineStatus, 0);
    if (state == LampUnknown) return NO;
    diagnostic->reason = "invalid-native-remaining";
    if (nativeRemaining < 0 || nativeRemaining > 999) return NO;

    uintptr_t phaseBegin = 0, phaseEnd = 0;
    memcpy(&phaseBegin, (const void *)(container + 0x10), sizeof(phaseBegin));
    memcpy(&phaseEnd, (const void *)(container + 0x18), sizeof(phaseEnd));
    diagnostic->reason = "invalid-or-empty-phases";
    if (!PlausibleNativeRange(phaseBegin, phaseEnd, kMaxCarPhases * 24, 8) ||
        phaseEnd - phaseBegin < 24 || (phaseEnd - phaseBegin) % 24 != 0)
        return NO;

    size_t phaseCount = (size_t)(phaseEnd - phaseBegin) / 24;
    diagnostic->phaseCount = (unsigned)phaseCount;
    diagnostic->reason = "no-current-phase";
    for (size_t phaseIndex = 0; phaseIndex < phaseCount; phaseIndex++) {
        const unsigned char *phase =
            (const unsigned char *)(phaseBegin + phaseIndex * 24);
        int32_t phaseCode = 0;
        int64_t startsAt = 0, endsAt = 0;
        memcpy(&phaseCode, phase, sizeof(phaseCode));
        memcpy(&startsAt, phase + 8, sizeof(startsAt));
        memcpy(&endsAt, phase + 16, sizeof(endsAt));
        if (startsAt <= 0 || endsAt <= startsAt ||
            endsAt - startsAt > 999 || wallNow < (double)startsAt ||
            wallNow >= (double)endsAt)
            continue;

        diagnostic->phaseCode = phaseCode;
        diagnostic->phaseRemaining = (double)endsAt - wallNow;
        diagnostic->oldGateMismatch = nextStatus >= 2 && nextStatus <= 8 &&
            !PhaseCodeMatchesNative(phaseCode, nextStatus);
        diagnostic->reason = "current-status-phase-mismatch";
        if (!PhaseCodeMatchesNative(phaseCode, engineStatus)) continue;
        diagnostic->reason = "phase-cache-rejected";
        if (!PublishCarPhaseRange(phaseBegin, phaseEnd, monotonicNow, signalId,
                                  yellowSeconds)) return NO;
        // Capture only. The HUD thread rechecks the current physical signal
        // before publishing; a record callback must not override that selection.
        atomic_store_explicit(&gCarUpdatedAt, monotonicNow, memory_order_release);
        diagnostic->reason = "ready";
        return YES;
    }
    return NO;
}

static void LogCarCapture(const CarCaptureDiagnostic *diagnostic,
                          uint64_t signalId, double monotonicNow) {
    const char *previousReason = atomic_exchange_explicit(
        &gCarCaptureReason, diagnostic->reason, memory_order_acq_rel);
    uint64_t previousId = atomic_exchange_explicit(
        &gCarCaptureSignalId, signalId, memory_order_relaxed);
    int previousStatus = atomic_exchange_explicit(
        &gCarCaptureCurrentStatus, diagnostic->currentStatus, memory_order_relaxed);
    atomic_store_explicit(&gCarCaptureAt, monotonicNow, memory_order_release);
    static _Atomic double lastLogged;
    if (previousReason != diagnostic->reason || previousId != signalId ||
        previousStatus != diagnostic->currentStatus ||
        monotonicNow - atomic_load_explicit(&lastLogged, memory_order_relaxed) >= 10.0) {
        atomic_store_explicit(&lastLogged, monotonicNow, memory_order_relaxed);
        LogLine("car capture reason=%s id=%llu flag=%d current=%d next=%d nativeRemain=%lld phaseCode=%d phaseRemain=%.1f phases=%u oldGateMismatch=%d",
                diagnostic->reason, (unsigned long long)signalId,
                diagnostic->recordFlag, diagnostic->currentStatus,
                diagnostic->nextStatus, (long long)diagnostic->nativeRemaining,
                diagnostic->phaseCode, diagnostic->phaseRemaining,
                diagnostic->phaseCount, diagnostic->oldGateMismatch ? 1 : 0);
    }
}

static int HookActiveTrafficRecords(void *records) {
    int result = gOriginalActiveTrafficRecords
        ? gOriginalActiveTrafficRecords(records) : 0;
    double monotonicNow = MonotonicSeconds();
    CarCaptureDiagnostic diagnostic = {
        .reason = "invalid-records-object",
        .recordFlag = -1,
        .currentStatus = -1,
        .nextStatus = -1,
        .nativeRemaining = -1,
        .phaseCode = -1,
        .phaseRemaining = -1.0,
    };
    if (!PlausibleNativePointer((uintptr_t)records, 8)) {
        LogCarCapture(&diagnostic, 0, monotonicNow);
        return result;
    }
    uintptr_t begin = 0, end = 0;
    memcpy(&begin, (const unsigned char *)records + 8, sizeof(begin));
    memcpy(&end, (const unsigned char *)records + 16, sizeof(end));
    if (!PlausibleNativeRange(begin, end, 216 * 64, 8) ||
        (end - begin) % 216 != 0) {
        diagnostic.reason = begin == end ? "records-empty" : "invalid-record-vector";
        LogCarCapture(&diagnostic, 0, monotonicNow);
        return result;
    }

    double wallNow = WallSeconds();
    int nativeStatus = atomic_load_explicit(
        &gNativeStatus, memory_order_acquire);
    size_t count = (size_t)(end - begin) / 216;

    uint64_t processorSyncId = 0;
    memcpy(&processorSyncId, (const unsigned char *)records + 0x20,
           sizeof(processorSyncId));
    if (processorSyncId == UINT64_MAX) processorSyncId = 0;
    ActiveSignalSnapshot active = {0};
    BOOL freshTravelSignal = LoadActiveSignalSnapshot(&active) &&
        active.candidateCount == 1 && active.signalId != 0 &&
        wallNow - active.updatedAt >= 0.0 &&
        wallNow - active.updatedAt <= 2.5;
    uint64_t desiredSignalId = freshTravelSignal ? active.signalId : 0;
    const char *targetReason = freshTravelSignal ? "travel-current-id" : "no-current-id";
    if (!freshTravelSignal)
        LoadCurrentCarTarget(&desiredSignalId, &targetReason, NULL);
    const unsigned char *exactRecord = NULL;
    size_t activeCount = 0, exactCount = 0;
    for (size_t index = 0; index < count; ++index) {
        const unsigned char *record =
            (const unsigned char *)(begin + index * 216);
        int32_t activeFlag = 0;
        uint64_t recordSignalId = 0;
        memcpy(&activeFlag, record + 0x54, sizeof(activeFlag));
        memcpy(&recordSignalId, record + 0x60, sizeof(recordSignalId));
        if (activeFlag == 1 && recordSignalId) activeCount++;
        if (desiredSignalId && recordSignalId == desiredSignalId) {
            exactCount++;
            exactRecord = record;
        }
    }

    // flag==1 may be the following intersection while the current one is 2/6.
    // Neither that flag nor an old processor sync ID proves current identity.
    const unsigned char *selectedRecord = exactCount == 1 ? exactRecord : NULL;
    uint64_t selectedSignalId = selectedRecord ? desiredSignalId : 0;
    int selectionReason = selectedRecord ? (freshTravelSignal ? 1 : 4) : 0;

    static _Atomic double lastLogged;
    if (monotonicNow - atomic_load_explicit(
            &lastLogged, memory_order_relaxed) > 10.0) {
        atomic_store_explicit(&lastLogged, monotonicNow, memory_order_relaxed);
        LogLine("active traffic records count=%zu active=%zu exact=%zu status=%d selectedId=%llu selection=%d travelId=%llu syncId=%llu targetId=%llu targetReason=%s",
                count, activeCount, exactCount, nativeStatus,
                (unsigned long long)selectedSignalId, selectionReason,
                (unsigned long long)(freshTravelSignal ? active.signalId : 0),
                (unsigned long long)processorSyncId,
                (unsigned long long)desiredSignalId, targetReason);
    }
    diagnostic.reason = count == 0 ? "records-empty" : "no-unique-selected-record";
    if (selectedRecord)
        PublishCurrentCarTimetable(selectedRecord, wallNow, monotonicNow,
                                   selectedSignalId, &diagnostic);
    LogCarCapture(&diagnostic, selectedSignalId, monotonicNow);

    return result;
}

// Bicycle timetable evaluation. The caller passes the same 24-byte phase
// vector the tiny 0x840548 leaf searches, but this wrapper has a standard
// prologue and ABI, so a plain C hook is safe here. The leaf itself stays
// unhooked: its entry begins with an early conditional branch that ElleKit's
// trampoline mis-relocates, which crashed GNaviTravel at every transition.
// The wrapper's time argument is a small relative value (probed as 34), so
// intervals are matched against the local wall clock instead; the vector's
// start/end fields are absolute epoch seconds matching it.
static size_t PublishCyclingPhaseRange(uint64_t begin, uint64_t end) {
    if (!PlausibleNativeRange(begin, end, kMaxCyclingPhases * 24, 8) ||
        end <= begin || (end - begin) % 24 != 0)
        return 0;

    size_t count = (size_t)(end - begin) / 24;
    uint64_t rows[kMaxCyclingPhases * 3];
    size_t kept = 0;
    for (size_t index = 0; index < count; index++) {
        const unsigned char *record =
            (const unsigned char *)(begin + index * 24);
        int32_t code = 0;
        int64_t startsAt = 0, endsAt = 0;
        memcpy(&code, record, sizeof(code));
        memcpy(&startsAt, record + 8, sizeof(startsAt));
        memcpy(&endsAt, record + 16, sizeof(endsAt));
        if (startsAt <= 0 || endsAt <= startsAt ||
            endsAt - startsAt > 180)
            continue;
        rows[kept * 3] = (uint32_t)code;
        rows[kept * 3 + 1] = (uint64_t)startsAt;
        rows[kept * 3 + 2] = (uint64_t)endsAt;
        kept++;
    }
    if (!kept) return 0;

    uint64_t header = atomic_load_explicit(
        &gCyclingTable[0], memory_order_relaxed);
    atomic_store_explicit(&gCyclingTable[0],
                          header | kCyclingTableBusy, memory_order_relaxed);
    for (size_t index = 0; index < kept * 3; index++)
        atomic_store_explicit(&gCyclingTable[1 + index], rows[index],
                              memory_order_relaxed);
    atomic_store_explicit(
        &gCyclingTable[0],
        ((header + 0x100ULL) & ~(kCyclingTableBusy | 0xffULL)) | kept,
        memory_order_release);
    return kept;
}

static void InvalidateTravelAdviceSnapshot(void) {
    if (atomic_flag_test_and_set_explicit(
            &gTravelAdviceSnapshotWriteLock, memory_order_acquire))
        return;
    uint64_t header = atomic_load_explicit(
        &gTravelAdviceSnapshot[0], memory_order_relaxed);
    atomic_store_explicit(&gTravelAdviceSnapshot[0],
                          header | kTravelAdviceSnapshotBusy,
                          memory_order_relaxed);
    atomic_store_explicit(&gTravelAdviceSnapshot[1], 0,
                          memory_order_relaxed);
    atomic_store_explicit(
        &gTravelAdviceSnapshot[0],
        (header + 0x100ULL) & ~(kTravelAdviceSnapshotBusy | 0xffULL),
        memory_order_release);
    atomic_flag_clear_explicit(&gTravelAdviceSnapshotWriteLock,
                               memory_order_release);
}

static BOOL PublishTravelAdviceSnapshot(void *phases,
                                        uint32_t distanceMeters,
                                        int64_t currentTimeSeconds,
                                        int32_t averageSpeedKmh,
                                        int32_t maximumWindows,
                                        int32_t nativeRecommendedSpeedKmh) {
    if (!PlausibleNativePointer((uintptr_t)phases, 8)) {
        InvalidateTravelAdviceSnapshot();
        return NO;
    }
    uint64_t begin = 0, end = 0;
    memcpy(&begin, phases, sizeof(begin));
    memcpy(&end, (const char *)phases + 8, sizeof(end));
    if (!PlausibleNativeRange(begin, end, kMaxCyclingPhases * 24, 8) ||
        end <= begin || (end - begin) % 24 != 0 ||
        distanceMeters > 10000 || averageSpeedKmh < 0 ||
        averageSpeedKmh > 100) {
        InvalidateTravelAdviceSnapshot();
        return NO;
    }

    size_t count = (size_t)(end - begin) / 24;
    uint64_t rows[kMaxCyclingPhases * 3];
    size_t kept = 0;
    for (size_t index = 0; index < count; ++index) {
        const unsigned char *record =
            (const unsigned char *)(begin + index * 24);
        int32_t code = 0;
        int64_t startsAt = 0, endsAt = 0;
        memcpy(&code, record, sizeof(code));
        memcpy(&startsAt, record + 8, sizeof(startsAt));
        memcpy(&endsAt, record + 16, sizeof(endsAt));
        if (startsAt <= 0 || endsAt <= startsAt ||
            endsAt - startsAt > 180)
            continue;
        rows[kept * 3] = (uint32_t)code;
        rows[kept * 3 + 1] = (uint64_t)startsAt;
        rows[kept * 3 + 2] = (uint64_t)endsAt;
        kept++;
    }
    if (!kept) {
        InvalidateTravelAdviceSnapshot();
        return NO;
    }
    if (atomic_flag_test_and_set_explicit(
            &gTravelAdviceSnapshotWriteLock, memory_order_acquire))
        return NO;

    ActiveSignalSnapshot active = {0};
    LoadActiveSignalSnapshot(&active);
    uint64_t header = atomic_load_explicit(
        &gTravelAdviceSnapshot[0], memory_order_relaxed);
    atomic_store_explicit(&gTravelAdviceSnapshot[0],
                          header | kTravelAdviceSnapshotBusy,
                          memory_order_relaxed);
    atomic_store_explicit(&gTravelAdviceSnapshot[1],
                          DoubleToBits(WallSeconds()), memory_order_relaxed);
    atomic_store_explicit(&gTravelAdviceSnapshot[2], active.signalId,
                          memory_order_relaxed);
    atomic_store_explicit(&gTravelAdviceSnapshot[3], distanceMeters,
                          memory_order_relaxed);
    atomic_store_explicit(&gTravelAdviceSnapshot[4],
                          (uint64_t)(int64_t)averageSpeedKmh,
                          memory_order_relaxed);
    atomic_store_explicit(&gTravelAdviceSnapshot[5],
                          (uint64_t)(int64_t)nativeRecommendedSpeedKmh,
                          memory_order_relaxed);
    atomic_store_explicit(&gTravelAdviceSnapshot[6],
                          (uint64_t)(int64_t)maximumWindows,
                          memory_order_relaxed);
    atomic_store_explicit(&gTravelAdviceSnapshot[7],
                          (uint64_t)currentTimeSeconds,
                          memory_order_relaxed);
    for (size_t index = 0; index < kept * 3; ++index)
        atomic_store_explicit(
            &gTravelAdviceSnapshot[kTravelAdviceSnapshotRows + index],
            rows[index], memory_order_relaxed);
    atomic_store_explicit(
        &gTravelAdviceSnapshot[0],
        ((header + 0x100ULL) &
         ~(kTravelAdviceSnapshotBusy | 0xffULL)) | kept,
        memory_order_release);
    atomic_flag_clear_explicit(&gTravelAdviceSnapshotWriteLock,
                               memory_order_release);
    return YES;
}

static BOOL LoadTravelAdviceSnapshot(TravelAdviceSnapshot *snapshot) {
    if (!snapshot) return NO;
    for (unsigned attempt = 0; attempt < 8; ++attempt) {
        uint64_t before = atomic_load_explicit(
            &gTravelAdviceSnapshot[0], memory_order_acquire);
        uint32_t count = (uint32_t)(before & 0xffULL);
        if ((before & kTravelAdviceSnapshotBusy) || !count ||
            count > kMaxCyclingPhases)
            continue;
        TravelAdviceSnapshot value = {
            .capturedAt = BitsToDouble(atomic_load_explicit(
                &gTravelAdviceSnapshot[1], memory_order_relaxed)),
            .signalId = atomic_load_explicit(
                &gTravelAdviceSnapshot[2], memory_order_relaxed),
            .distanceMeters = (int)(int64_t)atomic_load_explicit(
                &gTravelAdviceSnapshot[3], memory_order_relaxed),
            .averageSpeedKmh = (int)(int64_t)atomic_load_explicit(
                &gTravelAdviceSnapshot[4], memory_order_relaxed),
            .nativeRecommendedSpeedKmh =
                (int)(int64_t)atomic_load_explicit(
                    &gTravelAdviceSnapshot[5], memory_order_relaxed),
            .maximumWindows = (int)(int64_t)atomic_load_explicit(
                &gTravelAdviceSnapshot[6], memory_order_relaxed),
            .currentTimeSeconds = (int64_t)atomic_load_explicit(
                &gTravelAdviceSnapshot[7], memory_order_relaxed),
            .phaseCount = count,
        };
        for (size_t index = 0; index < count * 3; ++index)
            value.phaseRows[index] = atomic_load_explicit(
                &gTravelAdviceSnapshot[kTravelAdviceSnapshotRows + index],
                memory_order_relaxed);
        uint64_t after = atomic_load_explicit(
            &gTravelAdviceSnapshot[0], memory_order_acquire);
        if (before == after && !(after & kTravelAdviceSnapshotBusy)) {
            *snapshot = value;
            return YES;
        }
    }
    return NO;
}

static void ClearCyclingPhaseTable(void) {
    uint64_t header = atomic_load_explicit(
        &gCyclingTable[0], memory_order_relaxed);
    atomic_store_explicit(&gCyclingTable[0],
                          header | kCyclingTableBusy,
                          memory_order_relaxed);
    atomic_store_explicit(
        &gCyclingTable[0],
        (header + 0x100ULL) & ~(kCyclingTableBusy | 0xffULL),
        memory_order_release);
}

static void ObserveCyclingTimetable(void *phases) {
    double wallNow = WallSeconds();
    uint64_t now = (uint64_t)wallNow;
    static _Atomic double lastProbe;
    BOOL probeDue = wallNow - atomic_load_explicit(
        &lastProbe, memory_order_relaxed) > 10.0;
    if (probeDue)
        atomic_store_explicit(&lastProbe, wallNow, memory_order_relaxed);

    if (!PlausibleNativePointer((uintptr_t)phases, 8)) {
        if (probeDue)
            LogLine("cycling probe phases=%p rejected", phases);
        return;
    }
    uint64_t begin = 0, end = 0;
    memcpy(&begin, phases, sizeof(begin));
    memcpy(&end, (const unsigned char *)phases + 8, sizeof(end));
    if (!PlausibleNativeRange(begin, end, kMaxCyclingPhases * 24, 8) ||
        (end - begin) % 24 != 0 || end - begin < 24) {
        if (probeDue)
            LogLine("cycling probe now=%llu range=%llu..%llu rejected",
                    (unsigned long long)now,
                    (unsigned long long)begin, (unsigned long long)end);
        return;
    }

    size_t count = (size_t)(end - begin) / 24;
    if (probeDue) {
        LogLine("cycling probe now=%llu count=%zu", (unsigned long long)now,
                count);
        for (size_t index = 0; index < count && index < 3; index++) {
            const unsigned char *record =
                (const unsigned char *)(begin + index * 24);
            int32_t code = 0;
            int64_t startsAt = 0, endsAt = 0;
            memcpy(&code, record, sizeof(code));
            memcpy(&startsAt, record + 8, sizeof(startsAt));
            memcpy(&endsAt, record + 16, sizeof(endsAt));
            LogLine("cycling probe [%zu] code=%d start=%lld end=%lld", index,
                    code, (long long)startsAt, (long long)endsAt);
        }
    }

    size_t kept = PublishCyclingPhaseRange(begin, end);
    if (!kept && probeDue)
        LogLine("cycling probe kept=0 rejected");
}

// Every active travel location update refreshes the native route-state speed.
// Read only NaviService's active route object after AMap finishes the update;
// never inspect the PosLocInfo4Travel GPS/coordinate input argument.
static int64_t HookTravelLocationUpdate(void *service,
                                        const void *locationInfo,
                                        int32_t pointType) {
    int64_t result = gOriginalTravelLocationUpdate
        ? gOriginalTravelLocationUpdate(service, locationInfo, pointType) : 0;
    if (!gTravelRouteForType ||
        !PlausibleNativePointer((uintptr_t)service, 8))
        return result;

    uintptr_t routes = 0;
    memcpy(&routes, (const char *)service + 0x170, sizeof(routes));
    if (!PlausibleNativePointer(routes, 8)) return result;
    uintptr_t route = gTravelRouteForType((void *)routes, 1);
    if (!PlausibleNativePointer(route, 4)) return result;

    int32_t speedKmh = -1;
    memcpy(&speedKmh, (const void *)(route + 0x60), sizeof(speedKmh));
    if (speedKmh < 0 || speedKmh > 100) return result;
    atomic_store_explicit(&gTravelCurrentSpeedKmh, speedKmh,
                          memory_order_relaxed);
    atomic_store_explicit(&gTravelNaviInfoUpdatedAt, WallSeconds(),
                          memory_order_relaxed);
    atomic_fetch_add_explicit(&gTravelNaviInfoGeneration, 1,
                              memory_order_release);
    return result;
}

// Active TravelNaviInfo serializer. Its populated native message carries the
// current cycling speed in km/h plus travel-mode and navigation-state fields.
static int64_t HookTravelNaviInfoSerialize(const uint8_t *info, void *writer) {
    int64_t result = gOriginalTravelNaviInfoSerialize
        ? gOriginalTravelNaviInfoSerialize(info, writer) : 0;
    int32_t speedKmh = -1, travelMode = -1, navigationStatus = -1;
    if (PlausibleNativePointer((uintptr_t)info, 4)) {
        memcpy(&speedKmh, info + 0x68, sizeof(speedKmh));
        memcpy(&travelMode, info + 0x6c, sizeof(travelMode));
        memcpy(&navigationStatus, info + 0x70, sizeof(navigationStatus));
    }
    atomic_store_explicit(&gTravelCurrentSpeedKmh,
                          speedKmh >= 0 && speedKmh <= 100 ? speedKmh : -1,
                          memory_order_relaxed);
    atomic_store_explicit(&gTravelMode, travelMode, memory_order_relaxed);
    atomic_store_explicit(&gTravelNavigationStatus, navigationStatus,
                          memory_order_relaxed);
    atomic_store_explicit(&gTravelNaviInfoUpdatedAt, WallSeconds(),
                          memory_order_relaxed);
    atomic_fetch_add_explicit(&gTravelNaviInfoGeneration, 1,
                              memory_order_release);
    return result;
}

// Active dice::travel::DynamicFixedProvider::calcRecSpeed call. AMap passes a
// synchronized native signal distance, five-sample average cycling speed in
// km/h, absolute phase time, and the complete future light-state vector.
static int32_t HookTravelRecommendSpeed(void *provider, void *phases,
                                          uint32_t distanceMeters,
                                            int64_t currentTimeSeconds,
                                          int32_t averageSpeedKmh,
                                        int32_t maximumWindows) {
    int32_t result = gOriginalTravelRecommendSpeed
        ? gOriginalTravelRecommendSpeed(provider, phases, distanceMeters,
                                        currentTimeSeconds, averageSpeedKmh,
                                        maximumWindows) : 0;
    ObserveCyclingTimetable(phases);
    PublishTravelAdviceSnapshot(phases, distanceMeters, currentTimeSeconds,
                                averageSpeedKmh, maximumWindows, result);
    atomic_store_explicit(&gTravelAdviceDistanceMeters,
                          distanceMeters <= 10000 ? (int)distanceMeters : -1,
                          memory_order_relaxed);
    atomic_store_explicit(&gTravelAverageSpeedKmh,
                          averageSpeedKmh >= 0 && averageSpeedKmh <= 100
                              ? averageSpeedKmh : -1,
                          memory_order_relaxed);
    atomic_store_explicit(&gTravelNativeRecommendedSpeedKmh,
                          result >= 0 && result <= 100 ? result : -1,
                          memory_order_relaxed);
    return result;
}

static int ReadKnownInt32(const void *base, size_t offset) {
    if (!PlausibleNativePointer((uintptr_t)base, 4)) return -1;
    int32_t value = -1;
    memcpy(&value, (const char *)base + offset, sizeof(value));
    return value;
}

// Active travel-signal selector. AMap compares navigationState+0x0c against
// each signal's native route-offset interval at +0x44/+0x48. The difference
// currentOffset - signalOffset is the same route-distance formula used by the
// multiple-traffic-light path, but this function is active in bicycle mode.
static uintptr_t HookActiveTravelSignalRoute(void *processor, void *signals,
                                              void *navigationState) {
    uintptr_t result = gOriginalActiveTravelSignalRoute
        ? gOriginalActiveTravelSignalRoute(processor, signals,
                                           navigationState) : 0;
    int currentOffset = ReadKnownInt32(navigationState, 0x0c);
    int targetOffset = -1, rangeEnd = -1, distance = -1;
    uint64_t signalId = 0;
    unsigned candidateCount = 0;
    if (PlausibleNativePointer((uintptr_t)processor, 8) &&
        currentOffset >= 0) {
        uintptr_t begin = 0, end = 0;
        memcpy(&begin, (const char *)processor + 0x68, sizeof(begin));
        memcpy(&end, (const char *)processor + 0x70, sizeof(end));
        if (PlausibleNativeRange(begin, end, 112 * 64, 8) && end >= begin &&
            (end - begin) % 112 == 0) {
            unsigned count = (unsigned)((end - begin) / 112);
            for (unsigned index = 0; index < count; ++index) {
                uintptr_t item = begin + index * 112;
                int itemOffset = ReadKnownInt32((void *)item, 0x44);
                int itemRangeEnd = ReadKnownInt32((void *)item, 0x48);
                if (itemOffset < 0 || itemRangeEnd < itemOffset) continue;
                if (currentOffset <= itemRangeEnd &&
                    currentOffset > itemOffset) {
                    candidateCount++;
                    if (candidateCount == 1) {
                        memcpy(&signalId, (const void *)(item + 8),
                               sizeof(signalId));
                        targetOffset = itemOffset;
                        rangeEnd = itemRangeEnd;
                        distance = currentOffset - itemOffset;
                    }
                }
            }
        }
    }
    if (candidateCount != 1) {
        signalId = 0;
        targetOffset = -1;
        rangeEnd = -1;
        distance = -1;
    }
    atomic_fetch_add_explicit(&gActiveSignalRouteGeneration, 1,
                              memory_order_relaxed);
    atomic_store_explicit(&gActiveSignalRouteCandidateCount, candidateCount,
                          memory_order_relaxed);
    atomic_store_explicit(&gActiveSignalRouteDistance, distance,
                          memory_order_relaxed);
    atomic_store_explicit(&gActiveSignalCurrentOffset, currentOffset,
                          memory_order_relaxed);
    atomic_store_explicit(&gActiveSignalTargetOffset, targetOffset,
                          memory_order_relaxed);
    atomic_store_explicit(&gActiveSignalRangeEnd, rangeEnd,
                          memory_order_relaxed);
    atomic_store_explicit(&gActiveSignalRouteId, signalId,
                          memory_order_relaxed);
    atomic_store_explicit(&gActiveSignalRouteUpdatedAt, WallSeconds(),
                          memory_order_relaxed);
    atomic_fetch_add_explicit(&gActiveSignalRouteGeneration, 1,
                              memory_order_release);
    return result;
}

// Processes component.dynamicTravelTrafficSignalInfo into the exact native
// render-item vector used by travel navigation. Capture only primitive fields
// here; the main-thread tick performs all file logging.
static void HookDynamicTrafficSignalUpdate(void *processor, void *data,
                                           void *componentName) {
    if (gOriginalDynamicTrafficSignalUpdate)
        gOriginalDynamicTrafficSignalUpdate(processor, data, componentName);
    if (!PlausibleNativePointer((uintptr_t)processor, 8)) return;

    uint64_t begin = 0, end = 0;
    memcpy(&begin, (const char *)processor + 0x68, sizeof(begin));
    memcpy(&end, (const char *)processor + 0x70, sizeof(end));
    if (!PlausibleNativeRange(begin, end, 256 * 0x70, 8) || end < begin ||
        (end - begin) % 0x70 != 0)
        return;

    unsigned outerCount = (unsigned)((end - begin) / 0x70);
    unsigned innerCount = 0, phaseCount = 0, publishedCount = 0;
    uint64_t selectedSignalId = 0;
    for (unsigned i = 0; i < 12; ++i)
        atomic_store_explicit(&gTrafficSignalPhaseRows[i], 0,
                              memory_order_relaxed);

    BOOL selected = NO;
    for (unsigned outer = 0; outer < outerCount && outer < 8; ++outer) {
        uintptr_t item = (uintptr_t)begin + outer * 0x70;
        uint64_t innerBegin = 0, innerEnd = 0;
        memcpy(&innerBegin, (const void *)(item + 0x28), sizeof(innerBegin));
        memcpy(&innerEnd, (const void *)(item + 0x30), sizeof(innerEnd));
        if (!PlausibleNativeRange(innerBegin, innerEnd, 32 * 0x58, 8) ||
            innerEnd < innerBegin || (innerEnd - innerBegin) % 0x58 != 0)
            continue;
        unsigned localInnerCount =
            (unsigned)((innerEnd - innerBegin) / 0x58);
        innerCount += localInnerCount;
        for (unsigned inner = 0; inner < localInnerCount; ++inner) {
            uintptr_t light = (uintptr_t)innerBegin + inner * 0x58;
            uint64_t phaseBegin = 0, phaseEnd = 0;
            memcpy(&phaseBegin, (const void *)(light + 0x10),
                   sizeof(phaseBegin));
            memcpy(&phaseEnd, (const void *)(light + 0x18),
                   sizeof(phaseEnd));
            if (!PlausibleNativeRange(phaseBegin, phaseEnd,
                                      kMaxCyclingPhases * 24, 8) ||
                phaseEnd <= phaseBegin || (phaseEnd - phaseBegin) % 24 != 0)
                continue;

            unsigned localPhaseCount =
                (unsigned)((phaseEnd - phaseBegin) / 24);
            if (!selected) {
                selected = YES;
                memcpy(&selectedSignalId, (const void *)(item + 8),
                       sizeof(selectedSignalId));
                phaseCount = localPhaseCount;
                unsigned captured = localPhaseCount < 4 ? localPhaseCount : 4;
                for (unsigned phase = 0; phase < captured; ++phase) {
                    const unsigned char *record =
                        (const unsigned char *)(uintptr_t)(phaseBegin +
                                                          phase * 24);
                    int32_t code = 0;
                    int64_t startsAt = 0, endsAt = 0;
                    memcpy(&code, record, sizeof(code));
                    memcpy(&startsAt, record + 8, sizeof(startsAt));
                    memcpy(&endsAt, record + 16, sizeof(endsAt));
                    atomic_store_explicit(
                        &gTrafficSignalPhaseRows[phase * 3], (uint32_t)code,
                        memory_order_relaxed);
                    atomic_store_explicit(
                        &gTrafficSignalPhaseRows[phase * 3 + 1],
                        (uint64_t)startsAt, memory_order_relaxed);
                    atomic_store_explicit(
                        &gTrafficSignalPhaseRows[phase * 3 + 2],
                        (uint64_t)endsAt, memory_order_relaxed);
                }
                publishedCount =
                    (unsigned)PublishCyclingPhaseRange(phaseBegin, phaseEnd);
            }
        }
    }

    if (!publishedCount) {
        ClearCyclingPhaseTable();
        selectedSignalId = 0;
        double monotonicNow = MonotonicSeconds();
        if (monotonicNow - atomic_load_explicit(
                &gCarUpdatedAt, memory_order_acquire) > 2.5)
            PublishDisplayState(LampUnknown, 0, 0,
                                CountdownSourceUnknown);
    }
    atomic_store_explicit(&gCyclingTableSignalId, selectedSignalId,
                          memory_order_relaxed);
    atomic_store_explicit(&gCyclingTableUpdatedAt,
                          publishedCount ? WallSeconds() : 0.0,
                          memory_order_relaxed);

    atomic_store_explicit(&gTrafficSignalOuterCount, outerCount,
                          memory_order_relaxed);
    atomic_store_explicit(&gTrafficSignalInnerCount, innerCount,
                          memory_order_relaxed);
    atomic_store_explicit(&gTrafficSignalPhaseCount, phaseCount,
                          memory_order_relaxed);
    atomic_store_explicit(&gTrafficSignalPublishedCount, publishedCount,
                          memory_order_relaxed);
    atomic_fetch_add_explicit(&gTrafficSignalGeneration, 1,
                              memory_order_release);
}

static const char *RawCarStateName(RawCarInputState state) {
    switch (state) {
        case RawCarNoInput: return "no-input";
        case RawCarInvalidInput: return "invalid-input";
        case RawCarEmpty: return "empty";
        case RawCarNoUpcoming: return "no-upcoming-signal";
        case RawCarAmbiguous: return "ambiguous-nearest-signal";
        case RawCarMissingIdentity: return "missing-signal-id";
        case RawCarUnsupported: return "nearest-signal-unsupported";
        case RawCarNoPhases: return "nearest-signal-no-phases";
        case RawCarInvalidPhases: return "invalid-phases";
        case RawCarReady: return "ready";
    }
    return "invalid-state";
}

static BOOL StoreRawCarInput(const RawCarInputSnapshot *snapshot) {
    // Nothing that can call the native engine or log runs while this is held.
    while (atomic_flag_test_and_set_explicit(&gRawCarInputLock,
                                             memory_order_acquire)) {}
    BOOL newer = snapshot->observation > gRawCarInput.observation;
    if (newer) gRawCarInput = *snapshot;
    atomic_flag_clear_explicit(&gRawCarInputLock, memory_order_release);
    return newer;
}

static BOOL LoadRawCarInput(RawCarInputSnapshot *snapshot) {
    while (atomic_flag_test_and_set_explicit(&gRawCarInputLock,
                                             memory_order_acquire)) {}
    *snapshot = gRawCarInput;
    atomic_flag_clear_explicit(&gRawCarInputLock, memory_order_release);
    return snapshot->observation != 0;
}

static BOOL LoadCurrentCarTarget(uint64_t *signalId, const char **reason,
                                 RawCarInputSnapshot *snapshotOut) {
    *signalId = 0;
    *reason = "no-current-car-input";
    RawCarInputSnapshot snapshot = {0};
    if (!LoadRawCarInput(&snapshot)) return NO;
    *reason = "current-car-input-stale";
    double age = MonotonicSeconds() - snapshot.capturedAt;
    if (!isfinite(age) || age < 0.0 || age > 2.5) return NO;
    *reason = "no-valid-current-car-target";
    if ((snapshot.state != RawCarReady && snapshot.state != RawCarNoPhases) ||
        snapshot.eligibleFlag != 1 || snapshot.distanceMeters < 0 ||
        !snapshot.signalId || snapshot.signalId == UINT64_MAX) return NO;
    *signalId = snapshot.signalId;
    if (snapshotOut) *snapshotOut = snapshot;
    *reason = "raw-current-id";
    return YES;
}

static void ObserveRawCarTrafficInput(void *processor, const void *feed,
                                      const void *navigationState) {
    uint64_t observation = atomic_fetch_add_explicit(
        &gRawCarObservationSequence, 1, memory_order_relaxed) + 1;
    RawCarInputSnapshot snapshot = {
        .capturedAt = MonotonicSeconds(), .observation = observation,
        .state = RawCarInvalidInput,
        .distanceMeters = -1, .displayLimit = -1, .yellowSeconds = -1,
        .eligibleFlag = -1, .currentOffset = -1, .targetOffset = -1,
    };
    do {
        if (!PlausibleNativePointer((uintptr_t)processor, 8) ||
            !PlausibleNativePointer((uintptr_t)feed, 8) ||
            !PlausibleNativePointer((uintptr_t)navigationState, 4)) break;
        snapshot.currentOffset = ReadKnownInt32(navigationState, 0x0c);
        snapshot.displayLimit = ReadKnownInt32(processor, 0x54);
        if (snapshot.currentOffset < 0) break;
        uintptr_t begin = 0, end = 0;
        memcpy(&begin, (const unsigned char *)feed + 296, sizeof(begin));
        memcpy(&end, (const unsigned char *)feed + 304, sizeof(end));
        if (begin == end) { snapshot.state = RawCarEmpty; break; }
        if (!PlausibleNativeRange(begin, end, 232 * 512, 8) ||
            (end - begin) % 232 != 0) break;
        snapshot.inputCount = (unsigned)((end - begin) / 232);
        uintptr_t nearest = 0;
        int64_t nearestDistance = INT64_MAX;
        unsigned nearestCount = 0;
        for (unsigned i = 0; i < snapshot.inputCount; ++i) {
            uintptr_t item = begin + i * 232;
            int target = ReadKnownInt32((const void *)item, 0x4c);
            if (target < 0) continue;
            int64_t distance = (int64_t)snapshot.currentOffset - target;
            if (distance < 0) continue; // At zero we are at the light, not past it.
            if (distance < nearestDistance) {
                nearest = item;
                nearestDistance = distance;
                nearestCount = 1;
            } else if (distance == nearestDistance) {
                nearestCount++;
            }
        }
        snapshot.state = RawCarNoUpcoming;
        if (!nearest) break;
        snapshot.state = RawCarAmbiguous;
        if (nearestCount != 1) break;
        snapshot.distanceMeters = (int)nearestDistance;
        snapshot.targetOffset = ReadKnownInt32((const void *)nearest, 0x4c);
        memcpy(&snapshot.signalId, (const void *)(nearest + 0x60),
               sizeof(snapshot.signalId));
        snapshot.state = RawCarMissingIdentity;
        if (!snapshot.signalId || snapshot.signalId == UINT64_MAX) break;
        snapshot.eligibleFlag = ReadKnownInt32((const void *)nearest, 8);
        snapshot.state = RawCarUnsupported;
        // Do not skip an unsupported nearest light to show a farther one.
        if (snapshot.eligibleFlag != 1) break;
        snapshot.yellowSeconds = ReadKnownInt32((const void *)nearest, 224);
        uintptr_t phaseBegin = 0, phaseEnd = 0;
        // The native converter copies the primary light at source+120:
        // vector<Phase24> is at +16/+24, NOT any of the coordinate fields.
        memcpy(&phaseBegin, (const void *)(nearest + 136), sizeof(phaseBegin));
        memcpy(&phaseEnd, (const void *)(nearest + 144), sizeof(phaseEnd));
        snapshot.state = RawCarNoPhases;
        if (phaseBegin == phaseEnd) break;
        snapshot.state = RawCarInvalidPhases;
        if (!PlausibleNativeRange(phaseBegin, phaseEnd, kMaxCarPhases * 24, 8) ||
            (phaseEnd - phaseBegin) % 24 != 0) break;
        unsigned count = (unsigned)((phaseEnd - phaseBegin) / 24);
        int64_t previousEnd = 0;
        BOOL valid = YES;
        for (unsigned i = 0; i < count; ++i) {
            const unsigned char *phase = (const unsigned char *)(phaseBegin + i * 24);
            int32_t code = 0;
            int64_t startsAt = 0, endsAt = 0;
            memcpy(&code, phase, sizeof(code));
            memcpy(&startsAt, phase + 8, sizeof(startsAt));
            memcpy(&endsAt, phase + 16, sizeof(endsAt));
            if (startsAt <= 0 || endsAt <= startsAt || endsAt - startsAt > 999 ||
                (i && startsAt < previousEnd)) { valid = NO; break; }
            snapshot.phases[i * 3] = (uint32_t)code;
            snapshot.phases[i * 3 + 1] = (uint64_t)startsAt;
            snapshot.phases[i * 3 + 2] = (uint64_t)endsAt;
            previousEnd = endsAt;
        }
        if (!valid) break;
        snapshot.phaseCount = count;
        snapshot.state = count ? RawCarReady : RawCarNoPhases;
    } while (0);
    if (!StoreRawCarInput(&snapshot)) return; // A newer callback already won.

    static _Atomic int lastState = -1;
    static _Atomic uint64_t lastId;
    static _Atomic double lastLogged;
    if (atomic_exchange_explicit(&lastState, snapshot.state, memory_order_relaxed) !=
            (int)snapshot.state ||
        atomic_load_explicit(&lastId, memory_order_relaxed) != snapshot.signalId ||
        snapshot.capturedAt - atomic_load_explicit(&lastLogged, memory_order_relaxed) >= 10.0) {
        atomic_store_explicit(&lastId, snapshot.signalId, memory_order_relaxed);
        atomic_store_explicit(&lastLogged, snapshot.capturedAt, memory_order_relaxed);
        LogLine("raw car input reason=%s count=%u id=%llu eligible=%d current=%d target=%d distance=%d displayLimit=%d phases=%u outsideDisplayWindow=%d",
                RawCarStateName(snapshot.state), snapshot.inputCount,
                (unsigned long long)snapshot.signalId, snapshot.eligibleFlag,
                snapshot.currentOffset, snapshot.targetOffset, snapshot.distanceMeters,
                snapshot.displayLimit, snapshot.phaseCount,
                snapshot.displayLimit > 0 && snapshot.distanceMeters > snapshot.displayLimit);
    }
}

// Standard X0/X1/X2 entry with a full stack prologue. Observe the incoming
// native vector before local distance/lifecycle filtering. Forward all inputs
// and the return register unchanged; do not move the user's location.
static uintptr_t HookCarTrafficInput(void *processor, const void *feed,
                                     const void *navigationState) {
    ObserveRawCarTrafficInput(processor, feed, navigationState);
    return gOriginalCarTrafficInput
        ? gOriginalCarTrafficInput(processor, feed, navigationState) : 0;
}

static BOOL CommitIdentifiedCarDisplay(const RawCarInputSnapshot *snapshot,
                                      LampState state, double phaseEnd,
                                      unsigned expectedDisplayGeneration,
                                      CountdownSource source) {
    BOOL committed = NO;
    // Lock order is raw -> display. No path holds display while acquiring raw.
    while (atomic_flag_test_and_set_explicit(&gRawCarInputLock,
                                             memory_order_acquire)) {}
    gRawCarRejectReason = "newer-raw-input";
    if (gRawCarInput.observation == snapshot->observation &&
        gRawCarInput.signalId == snapshot->signalId &&
        (gRawCarInput.state == RawCarReady ||
         (source == CountdownSourceCar && gRawCarInput.state == RawCarNoPhases))) {
        while (atomic_flag_test_and_set_explicit(&gDisplayWriteLock,
                                                 memory_order_acquire)) {}
        unsigned generation = atomic_load_explicit(&gDisplayGeneration,
                                                    memory_order_relaxed);
        gRawCarRejectReason = "newer-display-publication";
        if (!(expectedDisplayGeneration & 1U) &&
            generation == expectedDisplayGeneration) {
            atomic_store_explicit(&gDisplayGeneration, generation + 1U,
                                  memory_order_release);
            atomic_store_explicit(&gLampState, state, memory_order_relaxed);
            atomic_store_explicit(&gCountdownSource, source, memory_order_relaxed);
            atomic_store_explicit(&gPhaseEndMonotonic, phaseEnd, memory_order_relaxed);
            atomic_store_explicit(&gTimetableUpdatedAt, snapshot->capturedAt,
                                  memory_order_relaxed);
            atomic_store_explicit(&gDisplayGeneration, generation + 2U,
                                  memory_order_release);
            committed = YES;
        }
        atomic_flag_clear_explicit(&gDisplayWriteLock, memory_order_release);
    }
    atomic_flag_clear_explicit(&gRawCarInputLock, memory_order_release);
    return committed;
}

static BOOL PublishRawCarCountdown(double wallNow, double monotonicNow,
                                   unsigned expectedDisplayGeneration) {
    gRawCarRejectReason = "no-input";
    RawCarInputSnapshot snapshot = {0};
    if (!LoadRawCarInput(&snapshot)) return NO;
    gRawCarRejectReason = RawCarStateName(snapshot.state);
    if (snapshot.state != RawCarReady || !snapshot.signalId ||
        snapshot.distanceMeters < 0 || !snapshot.phaseCount) return NO;
    gRawCarRejectReason = "input-age-2.5s";
    double age = monotonicNow - snapshot.capturedAt;
    if (!isfinite(age) || age < 0.0 || age > 2.5) return NO;
    double travelAge = wallNow - atomic_load_explicit(
        &gTravelNaviInfoUpdatedAt, memory_order_relaxed);
    if (travelAge >= 0.0 && travelAge <= 2.5) {
        ActiveSignalSnapshot active = {0};
        gRawCarRejectReason = "unmatched-travel-signal";
        if (!LoadActiveSignalSnapshot(&active) || active.candidateCount != 1 ||
            active.signalId != snapshot.signalId || wallNow - active.updatedAt < 0.0 ||
            wallNow - active.updatedAt > 2.5) return NO;
    }
    gRawCarRejectReason = "no-current-phase";
    for (unsigned i = 0; i < snapshot.phaseCount; ++i) {
        int code = (int32_t)(uint32_t)snapshot.phases[i * 3];
        double start = (double)(int64_t)snapshot.phases[i * 3 + 1];
        double end = (double)(int64_t)snapshot.phases[i * 3 + 2];
        if (wallNow < start || wallNow >= end) continue;
        LampState state = LampForNativeStatus(-1, code);
        gRawCarRejectReason = "unsupported-current-phase";
        if (state == LampUnknown) return NO;
        double remaining = end - wallNow;
        // Match 0x101200E78..EA4: negative explicitly disables native yellow;
        // otherwise compare against the full nonnegative threshold (no guessed cap).
        if (state == LampGreen && snapshot.yellowSeconds >= 0 &&
            remaining <= snapshot.yellowSeconds)
            state = LampYellow;
        // Preserve original input freshness and any intervening native source.
        if (!CommitIdentifiedCarDisplay(&snapshot, state, monotonicNow + remaining,
                expectedDisplayGeneration, CountdownSourceCarInput)) return NO;
        gRawCarRejectReason = "ready";
        return YES;
    }
    return NO;
}

static void InvalidateUnselectedCarDisplay(void) {
    BOOL cleared = NO;
    while (atomic_flag_test_and_set_explicit(&gDisplayWriteLock,
                                             memory_order_acquire)) {}
    // All car publishers have failed current-ID/freshness checks this tick.
    // Clear either car source immediately instead of retaining a passed light;
    // a valid travel display must remain untouched.
    if (IsCarCountdownSource(atomic_load_explicit(
            &gCountdownSource, memory_order_relaxed))) {
        unsigned generation = atomic_load_explicit(&gDisplayGeneration,
                                                    memory_order_relaxed);
        atomic_store_explicit(&gDisplayGeneration, generation + 1U,
                              memory_order_release);
        atomic_store_explicit(&gLampState, LampUnknown, memory_order_relaxed);
        atomic_store_explicit(&gCountdownSource, CountdownSourceUnknown,
                              memory_order_relaxed);
        atomic_store_explicit(&gPhaseEndMonotonic, 0.0, memory_order_relaxed);
        atomic_store_explicit(&gTimetableUpdatedAt, 0.0, memory_order_relaxed);
        atomic_store_explicit(&gDisplayGeneration, generation + 2U,
                              memory_order_release);
        cleared = YES;
    }
    atomic_flag_clear_explicit(&gDisplayWriteLock, memory_order_release);
    if (cleared) LogLine("car countdown invalidated table=%s raw=%s",
                         gCarTableRejectReason, gRawCarRejectReason);
}

static void InstallNativeHooks(void) {
    if (gHooksInstalled) return;
    gHooksInstalled = YES;

    void *library = dlopen("/var/jb/usr/lib/libellekit.dylib", RTLD_LAZY | RTLD_GLOBAL);
    if (!library)
        library = dlopen("/var/jb/usr/lib/libsubstrate.dylib", RTLD_LAZY | RTLD_GLOBAL);
    MSHookFunctionFn hook = (MSHookFunctionFn)dlsym(
        library ? library : RTLD_DEFAULT, "MSHookFunction");
    uintptr_t base = AMapMainImageBase();
    if (!hook || !base) {
        LogLine("hook installation failed hook=%p base=%p", hook, (void *)base);
        return;
    }

    // Version-specific unslid offsets verified against AMapiPhone 16.11.1.
    gTravelRouteForType = (TravelRouteForTypeFn)(base + 0x00836194ULL);
    hook((void *)(base + 0x00788410ULL), (void *)HookSignalStatusSerialize,
         (void **)&gOriginalSignalStatusSerialize);
    hook((void *)(base + 0x00788474ULL),
         (void *)HookSignalCountdownSerialize,
         (void **)&gOriginalSignalCountdownSerialize);
    // Active travel-signal selector. The navigation snapshot and 0x70-byte
    // signal items carry current/target native route offsets.
    hook((void *)(base + 0x0120EF04ULL),
         (void *)HookActiveTravelSignalRoute,
         (void **)&gOriginalActiveTravelSignalRoute);
    // Standard-ABI dynamicTravelTrafficSignalInfo processor. It materializes
    // the 0x70-byte render items consumed by travel navigation.
    hook((void *)(base + 0x0120F380ULL),
         (void *)HookDynamicTrafficSignalUpdate,
         (void **)&gOriginalDynamicTrafficSignalUpdate);
    {
        uint32_t prologue[4] = {0};
        memcpy(prologue, (const void *)(base + 0x011FE7D4ULL),
               sizeof(prologue));
        LogLine("prologue car-input %08x %08x %08x %08x",
                prologue[0], prologue[1], prologue[2], prologue[3]);
        memcpy(prologue, (const void *)(base + 0x00788474ULL),
               sizeof(prologue));
        LogLine("prologue signal-countdown %08x %08x %08x %08x",
                prologue[0], prologue[1], prologue[2], prologue[3]);
        memcpy(prologue, (const void *)(base + 0x0120EF04ULL),
               sizeof(prologue));
        LogLine("prologue active-signal-route %08x %08x %08x %08x",
                prologue[0], prologue[1], prologue[2], prologue[3]);
        memcpy(prologue, (const void *)(base + 0x0120F380ULL),
               sizeof(prologue));
        LogLine("prologue dynamic-signal %08x %08x %08x %08x",
                prologue[0], prologue[1], prologue[2], prologue[3]);
        memcpy(prologue, (const void *)(base + 0x0082AF88ULL),
               sizeof(prologue));
        LogLine("prologue travel-location-update %08x %08x %08x %08x",
                prologue[0], prologue[1], prologue[2], prologue[3]);
        memcpy(prologue, (const void *)(base + 0x00830760ULL),
               sizeof(prologue));
        LogLine("prologue travel-navi-info %08x %08x %08x %08x",
                prologue[0], prologue[1], prologue[2], prologue[3]);
        memcpy(prologue, (const void *)(base + 0x00840490ULL),
               sizeof(prologue));
        LogLine("prologue travel-rec-speed %08x %08x %08x %08x",
                prologue[0], prologue[1], prologue[2], prologue[3]);
    }
    hook((void *)(base + 0x011FF8C0ULL), (void *)HookActiveTrafficRecords,
         (void **)&gOriginalActiveTrafficRecords);
    // Read-only native car input, before the overlay's route-distance filter.
    // Full standard-ABI entry; never hook the custom-register conversion thunk.
    hook((void *)(base + 0x011FE7D4ULL), (void *)HookCarTrafficInput,
         (void **)&gOriginalCarTrafficInput);
    // Active location updates continuously expose route-state speed without
    // reading the PosLocInfo4Travel input object.
    hook((void *)(base + 0x0082AF88ULL),
         (void *)HookTravelLocationUpdate,
         (void **)&gOriginalTravelLocationUpdate);
    // Active TravelNaviInfo serializer: current cycling speed, travel mode,
    // and navigation state in a conventional X0/X1 ABI.
    hook((void *)(base + 0x00830760ULL),
         (void *)HookTravelNaviInfoSerialize,
         (void **)&gOriginalTravelNaviInfoSerialize);
    // Active travel recommended-speed wrapper. It carries synchronized phase,
    // distance, and five-sample average speed inputs; the custom-register leaf
    // at 0x840548 remains unhooked.
    hook((void *)(base + 0x00840490ULL), (void *)HookTravelRecommendSpeed,
         (void **)&gOriginalTravelRecommendSpeed);
    LogLine("native countdown hooks installed base=%p version=%s",
            (void *)base, DSH_PLUGIN_VERSION);
}

static id KeyWindow(void) {
    Class applicationClass = C("UIApplication");
    id application = applicationClass ? MsgId((id)applicationClass, "sharedApplication") : (id)0;
    id windows = application ? MsgId(application, "windows") : (id)0;
    NSUInteger count = Count(windows);
    id fallback = count ? At(windows, 0) : (id)0;
    for (NSUInteger index = 0; index < count; index++) {
        id window = At(windows, index);
        if (Responds(window, "isKeyWindow") && MsgBool(window, "isKeyWindow"))
            return window;
    }
    return fallback;
}

static id RGBA(CGFloat red, CGFloat green, CGFloat blue, CGFloat alpha) {
    Class colorClass = C("UIColor");
    return colorClass
        ? ((id (*)(id, SEL, CGFloat, CGFloat, CGFloat, CGFloat))objc_msgSend)(
              (id)colorClass, S("colorWithRed:green:blue:alpha:"), red,
              green, blue, alpha)
        : (id)0;
}

static id LampBackground(LampState state, BOOL fullscreen) {
    if (state == LampRed)
        return fullscreen ? RGBA(0.43, 0.03, 0.07, 1.0)
                          : RGBA(0.82, 0.10, 0.16, 0.97);
    if (state == LampYellow)
        return fullscreen ? RGBA(0.93, 0.58, 0.04, 1.0)
                          : RGBA(0.96, 0.68, 0.08, 0.98);
    if (state == LampGreen)
        return fullscreen ? RGBA(0.01, 0.31, 0.15, 1.0)
                          : RGBA(0.03, 0.60, 0.29, 0.97);
    return fullscreen ? RGBA(0.035, 0.045, 0.055, 1.0)
                      : RGBA(0.15, 0.17, 0.19, 0.94);
}

static id LampTextColor(LampState state) {
    Class colorClass = C("UIColor");
    if (!colorClass) return (id)0;
    return MsgId((id)colorClass,
                 state == LampYellow ? "blackColor" : "whiteColor");
}

static const char *LampName(LampState state) {
    if (state == LampRed) return "红灯";
    if (state == LampYellow) return "黄灯";
    if (state == LampGreen) return "绿灯";
    return "等待数据";
}

static id CreateLabel(CGRect frame, CGFloat fontSize, NSInteger lines) {
    Class labelClass = C("UILabel");
    if (!labelClass) return (id)0;
    id allocated = ((id (*)(id, SEL))objc_msgSend)((id)labelClass, S("alloc"));
    id label = ((id (*)(id, SEL, CGRect))objc_msgSend)(
        allocated, S("initWithFrame:"), frame);
    if (!label) return (id)0;
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(
        label, S("setTextAlignment:"), 1);
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(
        label, S("setNumberOfLines:"), lines);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(
        label, S("setUserInteractionEnabled:"), NO);
    Class fontClass = C("UIFont");
    if (fontClass) {
        id font = ((id (*)(id, SEL, CGFloat))objc_msgSend)(
            (id)fontClass, S("boldSystemFontOfSize:"), fontSize);
        MsgVoidObj(label, "setFont:", font);
    }
    ((void (*)(id, SEL, BOOL))objc_msgSend)(
        label, S("setAdjustsFontSizeToFitWidth:"), YES);
    ((void (*)(id, SEL, CGFloat))objc_msgSend)(
        label, S("setMinimumScaleFactor:"), 0.35);
    return label;
}

static void FitFullscreenNumberFont(CGFloat width, CGFloat height) {
    if (!gFullSecondsLabel || width <= 0 || height <= 0) return;
    if (fabs(width - gFullNumberLayoutWidth) < 0.5 &&
        fabs(height - gFullNumberLayoutHeight) < 0.5)
        return;
    Class fontClass = C("UIFont");
    if (!fontClass) return;

    // Fit the largest possible three-digit countdown once per layout. The
    // resulting font remains fixed as the value falls to two or one digits.
    MsgVoidObj(gFullSecondsLabel, "setText:", NSStr("180"));
    ((void (*)(id, SEL, BOOL))objc_msgSend)(
        gFullSecondsLabel, S("setAdjustsFontSizeToFitWidth:"), NO);
    CGFloat low = 24.0, high = 420.0;
    CGSize unconstrained = {10000.0, 10000.0};
    for (unsigned iteration = 0; iteration < 12; ++iteration) {
        CGFloat candidate = (low + high) / 2.0;
        id font = ((id (*)(id, SEL, CGFloat))objc_msgSend)(
            (id)fontClass, S("boldSystemFontOfSize:"), candidate);
        MsgVoidObj(gFullSecondsLabel, "setFont:", font);
        CGSize measured = MsgSize(
            gFullSecondsLabel, "sizeThatFits:", unconstrained);
        if (measured.width <= width && measured.height <= height)
            low = candidate;
        else
            high = candidate;
    }
    CGFloat fontSize = floor(low);
    id font = ((id (*)(id, SEL, CGFloat))objc_msgSend)(
        (id)fontClass, S("boldSystemFontOfSize:"), fontSize);
    MsgVoidObj(gFullSecondsLabel, "setFont:", font);
    gFullNumberLayoutWidth = width;
    gFullNumberLayoutHeight = height;
    LogLine("fullscreen number font=%.0f area=%.0fx%.0f", fontSize,
            width, height);
}

static void ApplyOverlayLayout(id window) {
    if (!window || !gBall) return;
    CGRect bounds = MsgRect(window, "bounds");
    CGFloat width = bounds.size.width;
    CGFloat height = bounds.size.height;
    if (width < 88 || height < 120) return;

    if (gFullView) SetRect(gFullView, "setFrame:", bounds);
    BOOL portraitLayout = height > 600.0;
    BOOL compactLayout = height < 352.0;
    CGFloat lampTop = portraitLayout ? 92.0 : (compactLayout ? 8.0 : 24.0);
    CGFloat lampHeight = portraitLayout ? 56.0 : (compactLayout ? 32.0 : 38.0);
    CGFloat numberTop = lampTop + lampHeight + (portraitLayout ? 14.0 : 4.0);
    CGFloat disclaimerHeight = compactLayout ? 24.0 : 30.0;
    CGFloat bottomMargin = compactLayout ? 8.0 : 42.0;
    CGFloat disclaimerTop = height - bottomMargin - disclaimerHeight;
    CGFloat actionHeight = portraitLayout ? 40.0 : 32.0;
    CGFloat detailHeight = portraitLayout ? 44.0 : 30.0;
    CGFloat detailTop = compactLayout
        ? disclaimerTop
        : disclaimerTop - 4.0 - detailHeight;
    CGFloat actionTop = (compactLayout ? disclaimerTop : detailTop) -
                        4.0 - actionHeight;
    CGFloat speedHeight = portraitLayout ? 34.0 : 28.0;
    CGFloat speedTop = actionTop - 4.0 - speedHeight;
    CGFloat unitHeight = compactLayout ? 28.0 : 42.0;
    CGFloat unitTop = speedTop - 4.0 - unitHeight;
    CGFloat numberHeight = unitTop - numberTop;
    if (numberHeight < 40.0) numberHeight = 40.0;

    SetRect(gFullLampLabel, "setFrame:",
            (CGRect){{24, lampTop}, {width - 48, lampHeight}});
    SetRect(gFullSecondsLabel, "setFrame:",
            (CGRect){{20, numberTop}, {width - 40, numberHeight}});
    FitFullscreenNumberFont(width - 40, numberHeight);
    SetRect(gFullUnitLabel, "setFrame:",
            (CGRect){{20, unitTop}, {width - 40, unitHeight}});
    SetRect(gFullSpeedLabel, "setFrame:",
            (CGRect){{20, speedTop}, {width - 40, speedHeight}});
    SetRect(gFullAdviceActionLabel, "setFrame:",
            (CGRect){{20, actionTop}, {width - 40, actionHeight}});
    SetRect(gFullAdviceDetailLabel, "setFrame:",
            (CGRect){{20, detailTop}, {width - 40, detailHeight}});
    ((void (*)(id, SEL, BOOL))objc_msgSend)(
        gFullAdviceDetailLabel, S("setHidden:"), compactLayout);
    SetRect(gFullDisclaimerLabel, "setFrame:",
            (CGRect){{20, disclaimerTop},
                     {width - 40, disclaimerHeight}});

    CGPoint center = ((CGPoint (*)(id, SEL))objc_msgSend)(gBall, S("center"));
    if (!gBallPositioned) {
        center.x = width - 48.0;
        center.y = 136.0;
        gBallPositioned = YES;
    }
    if (center.x < 44.0) center.x = 44.0;
    if (center.x > width - 44.0) center.x = width - 44.0;
    if (center.y < 74.0) center.y = 74.0;
    if (center.y > height - 44.0) center.y = height - 44.0;
    ((void (*)(id, SEL, CGPoint))objc_msgSend)(
        gBall, S("setCenter:"), center);
}

static void OpenFullscreen(id self, SEL command, id gesture) {
    (void)self;
    (void)command;
    (void)gesture;
    if (!gBall || !gFullView || gExpanded) return;
    gExpanded = YES;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(gBall, S("setHidden:"), YES);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(gFullView, S("setHidden:"), NO);
    id window = KeyWindow();
    if (window) {
        if (MsgId(gFullView, "window") != window)
            MsgVoidObj(window, "addSubview:", gFullView);
        ApplyOverlayLayout(window);
        if (Responds(window, "bringSubviewToFront:"))
            MsgVoidObj(window, "bringSubviewToFront:", gFullView);
    }
    UpdateOverlay();
    LogLine("hud fullscreen opened seconds=%d", gCurrentSeconds);
}

static void CloseFullscreen(id self, SEL command, id gesture) {
    (void)self;
    (void)command;
    (void)gesture;
    if (!gBall || !gFullView || !gExpanded) return;
    gExpanded = NO;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(gFullView, S("setHidden:"), YES);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(gBall, S("setHidden:"), NO);
    id window = KeyWindow();
    if (window && Responds(window, "bringSubviewToFront:"))
        MsgVoidObj(window, "bringSubviewToFront:", gBall);
    LogLine("hud fullscreen closed");
}

static void HandleBallPan(id self, SEL command, id gesture) {
    (void)self;
    (void)command;
    if (!gBall || !gesture || gExpanded) return;
    NSInteger state = (NSInteger)((long (*)(id, SEL))objc_msgSend)(
        gesture, S("state"));
    id window = MsgId(gBall, "window");
    if (!window) window = KeyWindow();
    CGPoint translation = ((CGPoint (*)(id, SEL, id))objc_msgSend)(
        gesture, S("translationInView:"), window);
    CGPoint center = ((CGPoint (*)(id, SEL))objc_msgSend)(gBall, S("center"));
    center.x += translation.x;
    center.y += translation.y;
    CGPoint zero = {0, 0};
    ((void (*)(id, SEL, CGPoint, id))objc_msgSend)(
        gesture, S("setTranslation:inView:"), zero, window);
    if (state == 1 || state == 2 || state == 3 || state == 4) {
        ((void (*)(id, SEL, CGPoint))objc_msgSend)(
            gBall, S("setCenter:"), center);
        gBallPositioned = YES;
        ApplyOverlayLayout(window);
    }
    if (state == 3 || state == 4) {
        CGRect bounds = MsgRect(window, "bounds");
        center = ((CGPoint (*)(id, SEL))objc_msgSend)(gBall, S("center"));
        center.x = center.x < bounds.size.width / 2.0
            ? 44.0 : bounds.size.width - 44.0;
        ((void (*)(id, SEL, CGPoint))objc_msgSend)(
            gBall, S("setCenter:"), center);
    }
}

static void EnsureOverlay(id window) {
    if (!window) return;
    if (!gBall) {
        Class viewClass = C("UIView");
        if (!viewClass || !C("UILabel")) return;
        CGRect ballFrame = {{0, 0}, {72, 72}};
        id ballAllocated = ((id (*)(id, SEL))objc_msgSend)(
            (id)viewClass, S("alloc"));
        gBall = ((id (*)(id, SEL, CGRect))objc_msgSend)(
            ballAllocated, S("initWithFrame:"), ballFrame);
        if (!gBall) return;
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            gBall, S("setUserInteractionEnabled:"), YES);

        gBallLampLabel = CreateLabel((CGRect){{4, 4}, {64, 17}}, 11.0, 1);
        gBallSecondsLabel = CreateLabel((CGRect){{4, 19}, {64, 32}}, 25.0, 1);
        gBallDistanceLabel = CreateLabel((CGRect){{4, 51}, {64, 16}}, 11.0, 1);
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            gBallSecondsLabel, S("setAdjustsFontSizeToFitWidth:"), NO);
        if (gBallLampLabel) MsgVoidObj(gBall, "addSubview:", gBallLampLabel);
        if (gBallSecondsLabel) MsgVoidObj(gBall, "addSubview:", gBallSecondsLabel);
        if (gBallDistanceLabel)
            MsgVoidObj(gBall, "addSubview:", gBallDistanceLabel);

        id layer = MsgId(gBall, "layer");
        if (layer) {
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(
                layer, S("setCornerRadius:"), 36.0);
            ((void (*)(id, SEL, BOOL))objc_msgSend)(
                layer, S("setMasksToBounds:"), YES);
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(
                layer, S("setBorderWidth:"), 2.0);
            id borderColor = RGBA(1.0, 1.0, 1.0, 0.46);
            id cgColor = MsgId(borderColor, "CGColor");
            if (cgColor) MsgVoidObj(layer, "setBorderColor:", cgColor);
        }

        Class panClass = C("UIPanGestureRecognizer");
        if (panClass && gController) {
            id allocated = ((id (*)(id, SEL))objc_msgSend)(
                (id)panClass, S("alloc"));
            id pan = ((id (*)(id, SEL, id, SEL))objc_msgSend)(
                allocated, S("initWithTarget:action:"),
                gController, S("dsh_pan_ball:"));
            if (pan) MsgVoidObj(gBall, "addGestureRecognizer:", pan);
        }
        Class tapClass = C("UITapGestureRecognizer");
        if (tapClass && gController) {
            id allocated = ((id (*)(id, SEL))objc_msgSend)(
                (id)tapClass, S("alloc"));
            id tap = ((id (*)(id, SEL, id, SEL))objc_msgSend)(
                allocated, S("initWithTarget:action:"),
                gController, S("dsh_open_fullscreen:"));
            if (tap) MsgVoidObj(gBall, "addGestureRecognizer:", tap);
        }

        CGRect fullFrame = {{0, 0}, {1, 1}};
        id fullAllocated = ((id (*)(id, SEL))objc_msgSend)(
            (id)viewClass, S("alloc"));
        gFullView = ((id (*)(id, SEL, CGRect))objc_msgSend)(
            fullAllocated, S("initWithFrame:"), fullFrame);
        if (gFullView) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(
                gFullView, S("setUserInteractionEnabled:"), YES);
            gFullLampLabel = CreateLabel(fullFrame, 36.0, 1);
            gFullSecondsLabel = CreateLabel(fullFrame, 180.0, 1);
            gFullUnitLabel = CreateLabel(fullFrame, 24.0, 1);
            gFullSpeedLabel = CreateLabel(fullFrame, 22.0, 1);
            gFullAdviceActionLabel = CreateLabel(fullFrame, 28.0, 1);
            gFullAdviceDetailLabel = CreateLabel(fullFrame, 15.0, 2);
            gFullDisclaimerLabel = CreateLabel(fullFrame, 15.0, 1);
            if (gFullLampLabel)
                MsgVoidObj(gFullView, "addSubview:", gFullLampLabel);
            if (gFullSecondsLabel)
                MsgVoidObj(gFullView, "addSubview:", gFullSecondsLabel);
            if (gFullUnitLabel)
                MsgVoidObj(gFullView, "addSubview:", gFullUnitLabel);
            if (gFullSpeedLabel)
                MsgVoidObj(gFullView, "addSubview:", gFullSpeedLabel);
            if (gFullAdviceActionLabel)
                MsgVoidObj(gFullView, "addSubview:", gFullAdviceActionLabel);
            if (gFullAdviceDetailLabel)
                MsgVoidObj(gFullView, "addSubview:", gFullAdviceDetailLabel);
            if (gFullDisclaimerLabel)
                MsgVoidObj(gFullView, "addSubview:", gFullDisclaimerLabel);
            MsgVoidObj(gFullUnitLabel, "setText:",
                       NSStr("秒 · 距路口 --米"));
            MsgVoidObj(gFullSpeedLabel, "setText:",
                       NSStr("当前速度 -- km/h"));
            MsgVoidObj(gFullAdviceActionLabel, "setText:",
                       NSStr("等待骑行速度"));
            MsgVoidObj(gFullAdviceDetailLabel, "setText:",
                       NSStr("速度和相位有效后自动计算"));
            MsgVoidObj(gFullDisclaimerLabel, "setText:",
                       NSStr("仅供参考，以现场信号灯为准"));
            ((void (*)(id, SEL, BOOL))objc_msgSend)(
                gFullView, S("setHidden:"), YES);

            if (tapClass && gController) {
                id allocated = ((id (*)(id, SEL))objc_msgSend)(
                    (id)tapClass, S("alloc"));
                id doubleTap = ((id (*)(id, SEL, id, SEL))objc_msgSend)(
                    allocated, S("initWithTarget:action:"),
                    gController, S("dsh_close_fullscreen:"));
                if (doubleTap) {
                    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(
                        doubleTap, S("setNumberOfTapsRequired:"), 2);
                    MsgVoidObj(gFullView, "addGestureRecognizer:", doubleTap);
                }
            }
        }
    }

    if (gFullView && MsgId(gFullView, "window") != window)
        MsgVoidObj(window, "addSubview:", gFullView);
    if (MsgId(gBall, "window") != window)
        MsgVoidObj(window, "addSubview:", gBall);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(
        gFullView, S("setHidden:"), gExpanded ? NO : YES);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(
        gBall, S("setHidden:"), gExpanded ? YES : NO);
    ApplyOverlayLayout(window);
    if (Responds(window, "bringSubviewToFront:"))
        MsgVoidObj(window, "bringSubviewToFront:",
                   gExpanded ? gFullView : gBall);
}

typedef struct {
    AdviceResult result;
    double strategySpeedKmh;
    int nativeRecommendedSpeedKmh;
    BOOL validInput;
} LiveAdviceSnapshot;

static LiveAdviceSnapshot ComputeLiveAdvice(
    LampState state, const ActiveSignalSnapshot *active) {
    LiveAdviceSnapshot snapshot = {0};
    snapshot.result.action = AdviceUnavailable;
    if (!active || active->candidateCount != 1 || active->signalId == 0 ||
        active->distanceMeters < 0)
        return snapshot;

    double wallNow = WallSeconds();
    int travelMode = atomic_load_explicit(&gTravelMode, memory_order_relaxed);
    uint64_t phaseRows[kMaxCyclingPhases * 3];
    uint32_t phaseCount = 0;
    double adviceNow = wallNow;
    double strategySpeedKmh = -1.0;
    int sourceDistance = active->distanceMeters;
    int nativeRecommendedSpeedKmh = -1;

    TravelAdviceSnapshot native = {0};
    BOOL synchronized = LoadTravelAdviceSnapshot(&native) &&
        wallNow - native.capturedAt >= 0.0 &&
        wallNow - native.capturedAt <= 2.5 &&
        native.signalId == active->signalId &&
        abs(native.distanceMeters - active->distanceMeters) <= 6 &&
        native.averageSpeedKmh >= 2 && native.averageSpeedKmh <= 40 &&
        native.maximumWindows >= 1 && native.maximumWindows <= 5;
    if (synchronized) {
        phaseCount = native.phaseCount;
        memcpy(phaseRows, native.phaseRows,
               phaseCount * 3 * sizeof(uint64_t));
        strategySpeedKmh = native.averageSpeedKmh;
        sourceDistance = native.distanceMeters;
        nativeRecommendedSpeedKmh = native.nativeRecommendedSpeedKmh;
        adviceNow = (double)native.currentTimeSeconds;
        if (!isfinite(adviceNow) || fabs(adviceNow - wallNow) > 5.0)
            adviceNow = wallNow;
    } else {
        int currentSpeedKmh = atomic_load_explicit(
            &gTravelCurrentSpeedKmh, memory_order_relaxed);
        double speedUpdatedAt = atomic_load_explicit(
            &gTravelNaviInfoUpdatedAt, memory_order_relaxed);
        uint64_t tableSignalId = 0;
        if (currentSpeedKmh < 2 || currentSpeedKmh > 40 ||
            wallNow - speedUpdatedAt < 0.0 ||
            wallNow - speedUpdatedAt > 2.5 ||
            !LoadTaggedCyclingTable(phaseRows, &phaseCount,
                                    &tableSignalId) ||
            tableSignalId != active->signalId)
            return snapshot;
        strategySpeedKmh = currentSpeedKmh;
    }

    AdviceGreenWindow windows[kMaxAdviceGreenWindows];
    size_t windowCount = BuildAdviceGreenWindows(
        phaseRows, phaseCount, adviceNow, windows, kMaxAdviceGreenWindows);
    if (!windowCount) return snapshot;

    if (active->signalId != gAdviceSignalId) {
        gAdviceSignalId = active->signalId;
        gPreferredAdviceWindowStart = 0.0;
    }
    AdviceConfig config = AdviceDefaultConfig();
    config.minimumRollingSpeedMps = 5.0 / 3.6;
    config.minimumCurrentSpeedMps = 0.5;
    config.maximumSpeedMps = (travelMode == 4 ? 25.0 : 20.0) / 3.6;
    AdviceInput input = {
        .nowEpochSeconds = adviceNow,
        .distanceMeters = (double)sourceDistance,
        .currentSpeedMps = strategySpeedKmh / 3.6,
        .greenWindows = windows,
        .greenWindowCount = windowCount,
        .allowAcceleration = state != LampYellow,
        .preferredWindowStartEpochSeconds = gPreferredAdviceWindowStart,
        .windowSwitchImprovementMps = 0.5,
    };
    snapshot.result = AdviceCompute(&input, &config);
    snapshot.strategySpeedKmh = strategySpeedKmh;
    snapshot.nativeRecommendedSpeedKmh = nativeRecommendedSpeedKmh;
    snapshot.validInput = YES;
    if (snapshot.result.available &&
        snapshot.result.action != AdvicePrepareStop &&
        snapshot.result.action != AdviceUnavailable)
        gPreferredAdviceWindowStart =
            snapshot.result.windowStartEpochSeconds;
    else if (snapshot.result.action == AdvicePrepareStop)
        gPreferredAdviceWindowStart = 0.0;
    return snapshot;
}

static int DisplaySpeedKmh(BOOL *usesAverage) {
    if (usesAverage) *usesAverage = NO;
    double wallNow = WallSeconds();
    int currentSpeed = atomic_load_explicit(
        &gTravelCurrentSpeedKmh, memory_order_relaxed);
    double currentUpdatedAt = atomic_load_explicit(
        &gTravelNaviInfoUpdatedAt, memory_order_relaxed);
    if (currentSpeed >= 0 && currentSpeed <= 40 &&
        wallNow - currentUpdatedAt >= 0.0 &&
        wallNow - currentUpdatedAt <= 10.0)
        return currentSpeed;

    TravelAdviceSnapshot native = {0};
    if (LoadTravelAdviceSnapshot(&native) &&
        native.averageSpeedKmh >= 0 && native.averageSpeedKmh <= 40 &&
        wallNow - native.capturedAt >= 0.0 &&
        wallNow - native.capturedAt <= 2.5) {
        if (usesAverage) *usesAverage = YES;
        return native.averageSpeedKmh;
    }
    return -1;
}

static void UpdateOverlay(void) {
    if (!gBall) return;
    double now = MonotonicSeconds();
    LampState state = LampUnknown;
    CountdownSource countdownSource = CountdownSourceUnknown;
    double phaseEnd = 0, updatedAt = 0;
    BOOL snapshotReady = LoadDisplayState(
        &state, &phaseEnd, &updatedAt, &countdownSource);
    double remaining = phaseEnd - now;
    double displayAge = now - updatedAt;
    double maximumRemaining = IsCarCountdownSource(countdownSource) ? 999.0 : 180.0;
    int seconds = -1;
    const char *hiddenReason = "none";
    if (!snapshotReady) hiddenReason = "snapshot-unavailable";
    else if (updatedAt <= 0.0) hiddenReason = "no-display-sample";
    else if (!isfinite(displayAge) || displayAge < 0.0 || displayAge > 2.5)
        hiddenReason = "display-age-2.5s";
    else if (!isfinite(remaining) || remaining < -0.2)
        hiddenReason = "phase-ended";
    else if (remaining > maximumRemaining) hiddenReason = "remaining-out-of-range";
    else if (state == LampUnknown) hiddenReason = "unknown-lamp";
    else seconds = remaining > 0 ? (int)ceil(remaining) : 0;
    if (seconds < 0) {
        if (gCurrentSeconds >= 0) {
            double carCapturedAt = atomic_load_explicit(
                &gCarTableCapturedAt, memory_order_relaxed);
            double carCaptureAt = atomic_load_explicit(
                &gCarCaptureAt, memory_order_acquire);
            LogLine("countdown hidden reason=%s previous=%d rawSource=%d remaining=%.1f displayAge=%.1f carTable=%s carTableAge=%.1f carTableId=%llu carCapture=%s carCaptureAge=%.1f carCaptureId=%llu serialized=%s rawInput=%s",
                    hiddenReason, gCurrentSeconds, (int)countdownSource,
                    remaining, displayAge, gCarTableRejectReason,
                    carCapturedAt > 0.0 ? now - carCapturedAt : -1.0,
                    (unsigned long long)atomic_load_explicit(
                        &gCarTableSignalId, memory_order_relaxed),
                    atomic_load_explicit(&gCarCaptureReason, memory_order_acquire),
                    carCaptureAt > 0.0 ? now - carCaptureAt : -1.0,
                    (unsigned long long)atomic_load_explicit(
                        &gCarCaptureSignalId, memory_order_relaxed),
                    gCarSerializedRejectReason, gRawCarRejectReason);
        }
        state = LampUnknown;
        countdownSource = CountdownSourceUnknown;
    }
    gCurrentSeconds = seconds;
    static CountdownSource lastLoggedCountdownSource = CountdownSourceUnknown;
    if (countdownSource != lastLoggedCountdownSource) {
        lastLoggedCountdownSource = countdownSource;
        LogLine("countdown source=%d seconds=%d", (int)countdownSource,
                seconds);
    }

    ActiveSignalSnapshot active = {0};
    BOOL activeReady = LoadActiveSignalSnapshot(&active);
    int distance = active.distanceMeters;
    double distanceAge = WallSeconds() - active.updatedAt;
    if (countdownSource != CountdownSourceTravel || !activeReady ||
        seconds < 0 || active.candidateCount != 1 ||
        active.signalId == 0 || distance < 0 || distance > 2000 ||
        distanceAge < 0 || distanceAge > 2.5)
        distance = -1;

    BOOL speedUsesAverage = NO;
    int displaySpeedKmh = DisplaySpeedKmh(&speedUsesAverage);
    char secondsText[16];
    char distanceText[32];
    char unitText[64];
    char speedText[64];
    snprintf(secondsText, sizeof(secondsText), seconds >= 0 ? "%d" : "--",
             seconds);
    if (countdownSource == CountdownSourceCarInput) {
        snprintf(distanceText, sizeof(distanceText), "原始取数");
    } else if (IsCarCountdownSource(countdownSource)) {
        snprintf(distanceText, sizeof(distanceText), "汽车参考");
    } else if (distance < 0) {
        snprintf(distanceText, sizeof(distanceText), "--米");
    } else if (distance < 1000) {
        snprintf(distanceText, sizeof(distanceText), "%d米", distance);
    } else {
        snprintf(distanceText, sizeof(distanceText), "%.1f公里",
                 (double)distance / 1000.0);
    }
    if (countdownSource == CountdownSourceCarInput)
        snprintf(unitText, sizeof(unitText), "秒 · 原始汽车信号参考");
    else if (IsCarCountdownSource(countdownSource))
        snprintf(unitText, sizeof(unitText), "秒 · 汽车信号参考");
    else
        snprintf(unitText, sizeof(unitText), "秒 · 距路口 %s", distanceText);
    if (countdownSource == CountdownSourceCarInput) {
        snprintf(speedText, sizeof(speedText), "取数模式 · 速度与距离暂不显示");
    } else if (displaySpeedKmh < 0) {
        snprintf(speedText, sizeof(speedText), "当前速度 -- km/h");
    } else if (speedUsesAverage) {
        snprintf(speedText, sizeof(speedText), "平均速度 %d km/h",
                 displaySpeedKmh);
    } else {
        snprintf(speedText, sizeof(speedText), "当前速度 %d km/h",
                 displaySpeedKmh);
    }

    LiveAdviceSnapshot advice = {0};
    advice.result.action = AdviceUnavailable;
    if (seconds >= 0 && distance >= 0)
        advice = ComputeLiveAdvice(state, &active);
    advice.result = AdviceStabilize(
        &gAdviceStabilizer, advice.result,
        distance >= 0 ? active.signalId : 0, WallSeconds(),
        advice.strategySpeedKmh / 3.6, 2.0, 0.15);
    char adviceActionText[96];
    char adviceDetailText[128];
    AdviceResult decision = advice.result;
    double targetKmh = decision.targetSpeedMps * 3.6;
    double deltaKmh = decision.speedDeltaMps * 3.6;
    unsigned arrivalSeconds = isfinite(decision.predictedArrivalSeconds)
        ? (unsigned)ceil(decision.predictedArrivalSeconds) : 0;
    unsigned greenRound = decision.windowIndex + 1;
    switch (decision.action) {
        case AdviceMaintain:
            snprintf(adviceActionText, sizeof(adviceActionText),
                     "保持当前速度");
            snprintf(adviceDetailText, sizeof(adviceDetailText),
                     "计算均速 %.0f km/h · 预计%u秒后第%u轮绿灯通过",
                     advice.strategySpeedKmh, arrivalSeconds, greenRound);
            break;
        case AdviceAccelerate:
            snprintf(adviceActionText, sizeof(adviceActionText),
                     "缓慢提速至 %.1f km/h", targetKmh);
            snprintf(adviceDetailText, sizeof(adviceDetailText),
                     "计算均速 %.0f · 提速 %.1f km/h · 预计%u秒后到达",
                     advice.strategySpeedKmh, fabs(deltaKmh), arrivalSeconds);
            break;
        case AdviceDecelerate:
            snprintf(adviceActionText, sizeof(adviceActionText),
                     "缓慢减速至 %.1f km/h", targetKmh);
            snprintf(adviceDetailText, sizeof(adviceDetailText),
                     "计算均速 %.0f · 减速 %.1f km/h · 预计%u秒后到达",
                     advice.strategySpeedKmh, fabs(deltaKmh), arrivalSeconds);
            break;
        case AdviceReduceToLimit:
            snprintf(adviceActionText, sizeof(adviceActionText),
                     "请减速至 %.0f km/h", targetKmh);
            snprintf(adviceDetailText, sizeof(adviceDetailText),
                     "当前 %.0f km/h · 已超过当前骑行模式建议上限",
                     advice.strategySpeedKmh);
            break;
        case AdvicePrepareStop:
            snprintf(adviceActionText, sizeof(adviceActionText),
                     "本轮不建议追赶");
            snprintf(adviceDetailText, sizeof(adviceDetailText),
                     "提前减速并准备停车");
            break;
        case AdviceUnavailable:
        default: {
            if (countdownSource == CountdownSourceCarInput) {
                snprintf(adviceActionText, sizeof(adviceActionText),
                         "取数优先：仅显示倒计时");
                snprintf(adviceDetailText, sizeof(adviceDetailText),
                         "未修改定位 · 暂不计算速度建议");
                break;
            }
            const char *waitingText = distance < 0
                ? "等待路口距离"
                : (displaySpeedKmh < 2 ? "等待骑行速度"
                                       : "等待同步相位数据");
            snprintf(adviceActionText, sizeof(adviceActionText), "%s",
                     waitingText);
            snprintf(adviceDetailText, sizeof(adviceDetailText),
                     "速度、距离和相位有效后自动计算");
            break;
        }
    }
    static AdviceAction lastLoggedAdviceAction = AdviceUnavailable;
    static int lastLoggedTargetTenths = -1;
    static double lastAdviceLogAt;
    int targetTenths = (int)llround(targetKmh * 10.0);
    double adviceLogNow = WallSeconds();
    if (decision.action != lastLoggedAdviceAction ||
        targetTenths != lastLoggedTargetTenths ||
        adviceLogNow - lastAdviceLogAt >= 10.0) {
        lastLoggedAdviceAction = decision.action;
        lastLoggedTargetTenths = targetTenths;
        lastAdviceLogAt = adviceLogNow;
        LogLine("strategy action=%d distance=%d current=%d average=%.1f target=%.1f delta=%.1f arrival=%u green=%u nativeRec=%d",
                (int)decision.action, distance, displaySpeedKmh,
                advice.strategySpeedKmh, targetKmh, deltaKmh,
                arrivalSeconds, greenRound,
                advice.nativeRecommendedSpeedKmh);
    }
    id textColor = LampTextColor(state);
    MsgVoidObj(gBall, "setBackgroundColor:", LampBackground(state, NO));
    MsgVoidObj(gBallLampLabel, "setTextColor:", textColor);
    MsgVoidObj(gBallSecondsLabel, "setTextColor:", textColor);
    MsgVoidObj(gBallDistanceLabel, "setTextColor:", textColor);
    MsgVoidObj(gBallLampLabel, "setText:", NSStr(LampName(state)));
    MsgVoidObj(gBallSecondsLabel, "setText:", NSStr(secondsText));
    MsgVoidObj(gBallDistanceLabel, "setText:", NSStr(distanceText));

    if (gFullView) {
        MsgVoidObj(gFullView, "setBackgroundColor:", LampBackground(state, YES));
        MsgVoidObj(gFullLampLabel, "setTextColor:", textColor);
        MsgVoidObj(gFullSecondsLabel, "setTextColor:", textColor);
        MsgVoidObj(gFullUnitLabel, "setTextColor:", textColor);
        MsgVoidObj(gFullSpeedLabel, "setTextColor:", textColor);
        MsgVoidObj(gFullAdviceActionLabel, "setTextColor:", textColor);
        MsgVoidObj(gFullAdviceDetailLabel, "setTextColor:", textColor);
        MsgVoidObj(gFullDisclaimerLabel, "setTextColor:", textColor);
        MsgVoidObj(gFullLampLabel, "setText:", NSStr(LampName(state)));
        MsgVoidObj(gFullSecondsLabel, "setText:", NSStr(secondsText));
        MsgVoidObj(gFullUnitLabel, "setText:", NSStr(unitText));
        MsgVoidObj(gFullSpeedLabel, "setText:", NSStr(speedText));
        MsgVoidObj(gFullAdviceActionLabel, "setText:",
                   NSStr(adviceActionText));
        MsgVoidObj(gFullAdviceDetailLabel, "setText:",
                   NSStr(adviceDetailText));
    }
}

// scheduledTimerWithTimeInterval attaches to the CALLING thread's runloop;
// navigation-start callbacks can arrive on an engine thread whose runloop
// never runs, silently killing the HUD tick. Always create the timer on the
// main thread instead.
static void CreateTickTimer(id self, SEL command, id argument) {
    (void)self;
    (void)command;
    (void)argument;
    if (gTimer || !gController) return;
    Class timerClass = C("NSTimer");
    if (!timerClass) return;
    gTimer = ((id (*)(id, SEL, double, id, SEL, id, BOOL))objc_msgSend)(
        (id)timerClass,
        S("scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:"),
        1.0, gController, S("dsh_tick:"), 0, YES);
}

static void ScheduleTimer(void) {
    if (gTimer || !gController) return;
    ((void (*)(id, SEL, SEL, id, BOOL))objc_msgSend)(
        gController, S("performSelectorOnMainThread:withObject:waitUntilDone:"),
        S("dsh_create_tick_timer:"), 0, NO);
}

static void Tick(id self, SEL command, id timer) {
    (void)self;
    (void)command;
    (void)timer;
    static _Atomic double lastAlive;
    static unsigned lastTrafficSignalGeneration;
    static unsigned lastActiveSignalRouteGeneration;
    static int lastLoggedActiveSignalDistance = -2;
    static double lastActiveSignalRouteLogAt;
    static unsigned lastTravelNaviInfoGeneration;
    static int lastLoggedTravelSpeed = -2;
    static double lastTravelSpeedLogAt;
    unsigned travelNaviInfoGeneration = atomic_load_explicit(
        &gTravelNaviInfoGeneration, memory_order_acquire);
    if (travelNaviInfoGeneration != lastTravelNaviInfoGeneration) {
        lastTravelNaviInfoGeneration = travelNaviInfoGeneration;
        int currentSpeed = atomic_load_explicit(
            &gTravelCurrentSpeedKmh, memory_order_relaxed);
        double logNow = WallSeconds();
        if (currentSpeed != lastLoggedTravelSpeed ||
            logNow - lastTravelSpeedLogAt >= 10.0) {
            lastLoggedTravelSpeed = currentSpeed;
            lastTravelSpeedLogAt = logNow;
            LogLine("travel speed current=%d average=%d nativeRec=%d distance=%d mode=%d navStatus=%d age=%.1f gen=%u",
                    currentSpeed,
                    atomic_load_explicit(&gTravelAverageSpeedKmh,
                                         memory_order_relaxed),
                    atomic_load_explicit(&gTravelNativeRecommendedSpeedKmh,
                                         memory_order_relaxed),
                    atomic_load_explicit(&gTravelAdviceDistanceMeters,
                                         memory_order_relaxed),
                    atomic_load_explicit(&gTravelMode,
                                         memory_order_relaxed),
                    atomic_load_explicit(&gTravelNavigationStatus,
                                         memory_order_relaxed),
                    logNow - atomic_load_explicit(
                        &gTravelNaviInfoUpdatedAt, memory_order_relaxed),
                    travelNaviInfoGeneration);
        }
    }
    unsigned trafficSignalGeneration = atomic_load_explicit(
        &gTrafficSignalGeneration, memory_order_acquire);
    if (trafficSignalGeneration != lastTrafficSignalGeneration) {
        lastTrafficSignalGeneration = trafficSignalGeneration;
        unsigned outerCount = atomic_load_explicit(
            &gTrafficSignalOuterCount, memory_order_relaxed);
        unsigned innerCount = atomic_load_explicit(
            &gTrafficSignalInnerCount, memory_order_relaxed);
        unsigned phaseCount = atomic_load_explicit(
            &gTrafficSignalPhaseCount, memory_order_relaxed);
        unsigned publishedCount = atomic_load_explicit(
            &gTrafficSignalPublishedCount, memory_order_relaxed);
        uint32_t tableCount = (uint32_t)(atomic_load_explicit(
            &gCyclingTable[0], memory_order_acquire) & 0xffULL);
        LogLine("dynamic signal outer=%u inner=%u phases=%u published=%u table=%u gen=%u",
                outerCount, innerCount, phaseCount, publishedCount,
                tableCount, trafficSignalGeneration);
    }
    unsigned activeSignalRouteGeneration = atomic_load_explicit(
        &gActiveSignalRouteGeneration, memory_order_acquire);
    if (activeSignalRouteGeneration != lastActiveSignalRouteGeneration) {
        lastActiveSignalRouteGeneration = activeSignalRouteGeneration;
        int activeDistance = atomic_load_explicit(
            &gActiveSignalRouteDistance, memory_order_relaxed);
        double logNow = WallSeconds();
        if (activeDistance != lastLoggedActiveSignalDistance ||
            logNow - lastActiveSignalRouteLogAt >= 10.0) {
            lastLoggedActiveSignalDistance = activeDistance;
            lastActiveSignalRouteLogAt = logNow;
            LogLine("active signal route distance=%d current=%d target=%d end=%d id=%llu candidates=%u age=%.1f gen=%u",
                    activeDistance,
                    atomic_load_explicit(&gActiveSignalCurrentOffset,
                                         memory_order_relaxed),
                    atomic_load_explicit(&gActiveSignalTargetOffset,
                                         memory_order_relaxed),
                    atomic_load_explicit(&gActiveSignalRangeEnd,
                                         memory_order_relaxed),
                    (unsigned long long)atomic_load_explicit(
                        &gActiveSignalRouteId, memory_order_relaxed),
                    atomic_load_explicit(&gActiveSignalRouteCandidateCount,
                                         memory_order_relaxed),
                    logNow - atomic_load_explicit(
                        &gActiveSignalRouteUpdatedAt, memory_order_relaxed),
                    activeSignalRouteGeneration);
        }
    }
    double anow = WallSeconds();
    if (anow - atomic_load_explicit(&lastAlive, memory_order_relaxed) > 15.0) {
        atomic_store_explicit(&lastAlive, anow, memory_order_relaxed);
        LogLine("tick alive ball=%p expanded=%d", gBall,
                gExpanded ? 1 : 0);
    }
    EnsureOverlay(KeyWindow());
    double monotonicNow = MonotonicSeconds();
    double wallNow = WallSeconds();
    unsigned displayGenerationBeforeSources = atomic_load_explicit(
        &gDisplayGeneration, memory_order_acquire);
    gCarTableRejectReason = "higher-priority-source";
    gCarSerializedRejectReason = "higher-priority-source";
    gRawCarRejectReason = "higher-priority-source";
    if (!PublishLiveCyclingPhase(wallNow, monotonicNow) &&
        !PublishSerializedCarCountdown(wallNow, monotonicNow) &&
        !PublishLiveCarPhase(wallNow, monotonicNow, displayGenerationBeforeSources)) {
        if (!PublishRawCarCountdown(wallNow, monotonicNow,
                                    displayGenerationBeforeSources))
            InvalidateUnselectedCarDisplay();
    }
    UpdateOverlay();
}

static void EnterBackground(id self, SEL command, id notification) {
    (void)self;
    (void)command;
    (void)notification;
    if (gTimer) MsgVoid(gTimer, "invalidate");
    gTimer = 0;
}

static void EnterForeground(id self, SEL command, id notification) {
    (void)self;
    (void)command;
    (void)notification;
    ScheduleTimer();
}

static void Start(id self, SEL command, id argument) {
    (void)self;
    (void)command;
    (void)argument;
    if (gStarted) return;
    gStarted = YES;
    ScheduleTimer();

    Class centerClass = C("NSNotificationCenter");
    id center = centerClass ? MsgId((id)centerClass, "defaultCenter") : (id)0;
    if (center) {
        ((void (*)(id, SEL, id, SEL, id, id))objc_msgSend)(
            center, S("addObserver:selector:name:object:"), gController,
            S("dsh_background:"), NSStr("UIApplicationDidEnterBackgroundNotification"), 0);
        ((void (*)(id, SEL, id, SEL, id, id))objc_msgSend)(
            center, S("addObserver:selector:name:object:"), gController,
            S("dsh_foreground:"), NSStr("UIApplicationWillEnterForegroundNotification"), 0);
    }
    LogLine("countdown HUD started; native travel speed advice enabled; no OCR, network, GPS/Core Location collection, or geospatial distance inference");
}

__attribute__((constructor)) static void AMapSignalCountdownInit(void) {
    InstallNativeHooks();

    Class objectClass = C("NSObject");
    if (!objectClass) return;
    Class controllerClass = C("DSHAMapSignalCountdownController");
    if (!controllerClass) {
        controllerClass = objc_allocateClassPair(
            objectClass, "DSHAMapSignalCountdownController", 0);
        if (!controllerClass) return;
        objc_registerClassPair(controllerClass);
    }
    class_addMethod(controllerClass, S("dsh_start:"), (IMP)Start, "v@:@");
    class_addMethod(controllerClass, S("dsh_tick:"), (IMP)Tick, "v@:@");
    class_addMethod(controllerClass, S("dsh_create_tick_timer:"),
                    (IMP)CreateTickTimer, "v@:@");
    class_addMethod(controllerClass, S("dsh_background:"), (IMP)EnterBackground, "v@:@");
    class_addMethod(controllerClass, S("dsh_foreground:"), (IMP)EnterForeground, "v@:@");
    class_addMethod(controllerClass, S("dsh_open_fullscreen:"),
                    (IMP)OpenFullscreen, "v@:@");
    class_addMethod(controllerClass, S("dsh_close_fullscreen:"),
                    (IMP)CloseFullscreen, "v@:@");
    class_addMethod(controllerClass, S("dsh_pan_ball:"),
                    (IMP)HandleBallPan, "v@:@");
    gController = MsgId((id)controllerClass, "new");
    if (gController && Responds(gController, "performSelector:withObject:afterDelay:")) {
        ((void (*)(id, SEL, SEL, id, double))objc_msgSend)(
            gController, S("performSelector:withObject:afterDelay:"),
            S("dsh_start:"), 0, 0.5);
    }
}
