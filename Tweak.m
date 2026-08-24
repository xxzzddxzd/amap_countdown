// AMap Signal Countdown — personal rootless tweak for AMap 16.11.1.
// Reads only AMap's in-process native traffic-light state/countdown outputs.
// No OCR, network interception, location/speed collection, distance inference,
// or riding advice.

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
typedef void *(*TravelStatusSerializeFn)(void *model, void *serializer);
typedef void *(*TravelStatusArrayFn)(void *writer, void *unused,
                                     void *vector);
typedef void (*DynamicTrafficSignalUpdateFn)(void *processor, void *data,
                                             void *componentName);
typedef void *(*TrafficSignalRenderUpdateFn)(void *controller,
                                             void *trafficData,
                                             void *navigationState);
typedef uintptr_t (*RouteDistanceEnvelopeFn)(void *context, void *previous,
                                             void *current, void *extra);
typedef uintptr_t (*RouteDistanceContextFn)(void *context);
typedef uintptr_t (*GuideLightDistanceBuildFn)(void *formatter, void *route,
                                               uintptr_t index);
typedef uintptr_t (*GuideLightDistanceFormatFn)(void *formatter);
typedef uintptr_t (*FirstLightStatsSerializeFn)(uint32_t *stats,
                                                void *serializer);
typedef uintptr_t (*RouteSummarySerializeFn)(void *summary,
                                             void *serializer);
typedef uintptr_t (*ActiveTravelSignalRouteFn)(void *processor, void *signals,
                                               void *navigationState);
typedef int (*ActiveTrafficRecordsFn)(void *records);
typedef void *(*CyclingTimetableEvaluateFn)(void *context, void *phases,
                                            uint64_t currentTime, void *outA,
                                            void *outB, int32_t mode);

typedef enum {
    LampUnknown = 0,
    LampRed,
    LampYellow,
    LampGreen
} LampState;

static SignalStatusSerializeFn gOriginalSignalStatusSerialize;
static TravelStatusSerializeFn gOriginalTravelStatusSerialize;
static TravelStatusArrayFn gOriginalTravelStatusArray;
static DynamicTrafficSignalUpdateFn gOriginalDynamicTrafficSignalUpdate;
static TrafficSignalRenderUpdateFn gOriginalTrafficSignalRenderUpdate;
static RouteDistanceEnvelopeFn gOriginalRouteDistanceEnvelope;
static RouteDistanceContextFn gOriginalRouteDistanceContext;
static GuideLightDistanceBuildFn gOriginalGuideLightDistanceBuild;
static GuideLightDistanceFormatFn gOriginalGuideLightDistanceFormatA;
static GuideLightDistanceFormatFn gOriginalGuideLightDistanceFormatB;
static FirstLightStatsSerializeFn gOriginalFirstLightStatsSerialize;
static RouteSummarySerializeFn gOriginalRouteSummarySerializeA;
static RouteSummarySerializeFn gOriginalRouteSummarySerializeB;
static ActiveTravelSignalRouteFn gOriginalActiveTravelSignalRoute;
static ActiveTrafficRecordsFn gOriginalActiveTrafficRecords;
static CyclingTimetableEvaluateFn gOriginalCyclingTimetableEvaluate;
static _Atomic int gNativeStatus = -1;
static _Atomic LampState gLampState = LampUnknown;
static _Atomic double gPhaseEndMonotonic;
static _Atomic double gTimetableUpdatedAt;
static _Atomic double gCarUpdatedAt;
static _Atomic unsigned gTrafficSignalGeneration;
static _Atomic unsigned gTrafficSignalOuterCount;
static _Atomic unsigned gTrafficSignalInnerCount;
static _Atomic unsigned gTrafficSignalPhaseCount;
static _Atomic unsigned gTrafficSignalPublishedCount;
static _Atomic uint64_t gTrafficSignalPhaseRows[12];
static _Atomic unsigned gSignalDistanceGeneration;
static _Atomic unsigned gSignalDistanceCandidateCount;
static _Atomic int gSignalDistanceMeters = -1;
static _Atomic int gSignalDistanceCurrentOffset;
static _Atomic int gSignalDistanceTargetOffset;
static _Atomic uint64_t gSignalDistanceLinkId;
static _Atomic uint32_t gSignalDistanceCurrentLink;
static _Atomic double gSignalDistanceUpdatedAt;
static _Atomic unsigned gRouteDistanceGeneration;
static _Atomic int gRouteDistanceEnvelopeMeters = -1;
static _Atomic int gRouteDistanceContextMeters = -1;
static _Atomic uintptr_t gRouteDistanceEnvelopeObject;
static _Atomic uintptr_t gRouteDistanceContextObject;
static _Atomic double gRouteDistanceUpdatedAt;
static _Atomic unsigned gGuideLightBuildGeneration;
static _Atomic unsigned gGuideLightFormatGeneration;
static _Atomic int gGuideLightDistanceMeters = -1;
static _Atomic int gGuideLightDistanceBefore = -1;
static _Atomic int gGuideLightRouteBase = -1;
static _Atomic int gGuideLightRouteMode = -1;
static _Atomic uintptr_t gGuideLightRouteIndex;
static _Atomic double gGuideLightUpdatedAt;
static _Atomic unsigned gFirstLightStatsGeneration;
static _Atomic int gFirstLightTotalCount = -1;
static _Atomic int gFirstLightDistanceMeters = -1;
static _Atomic int gFirstLightTimeSeconds = -1;
static _Atomic unsigned gRouteSummaryGeneration;
static _Atomic int gRouteSummaryEtaDistance = -1;
static _Atomic int gRouteSummaryEtaTime = -1;
static _Atomic int gRouteSummaryRemainingLights = -1;
static _Atomic unsigned gActiveSignalRouteGeneration;
static _Atomic unsigned gActiveSignalRouteCandidateCount;
static _Atomic int gActiveSignalRouteDistance = -1;
static _Atomic int gActiveSignalCurrentOffset = -1;
static _Atomic int gActiveSignalTargetOffset = -1;
static _Atomic int gActiveSignalRangeEnd = -1;
static _Atomic uint64_t gActiveSignalRouteId;
static _Atomic double gActiveSignalRouteUpdatedAt;
static atomic_flag gDisplayWriteLock = ATOMIC_FLAG_INIT;
static _Atomic unsigned gDisplayGeneration;
// Seqlock-protected snapshot of the native bicycle phase table written by
// HookCyclingTimetableEvaluate on the GNaviTravel thread and read by the HUD
// timer on the main thread. Header word: bit 63 is the busy flag, bits 8..62
// the generation, bits 0..7 the record count; payload is count triples of
// {code, startsAt, endsAt} in absolute epoch seconds.
#define kMaxCyclingPhases 32
#define kCyclingTableBusy 0x8000000000000000ULL
static _Atomic uint64_t gCyclingTable[kMaxCyclingPhases * 3 + 1];
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
static id gFullDisclaimerLabel;
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

static void PublishDisplayState(LampState state, double phaseEnd, double updatedAt) {
    while (atomic_flag_test_and_set_explicit(
               &gDisplayWriteLock, memory_order_acquire)) {}
    unsigned generation = atomic_load_explicit(
        &gDisplayGeneration, memory_order_relaxed);
    atomic_store_explicit(&gDisplayGeneration, generation + 1U, memory_order_release);
    atomic_store_explicit(&gLampState, state, memory_order_relaxed);
    atomic_store_explicit(&gPhaseEndMonotonic, phaseEnd, memory_order_relaxed);
    atomic_store_explicit(&gTimetableUpdatedAt, updatedAt, memory_order_relaxed);
    atomic_store_explicit(&gDisplayGeneration, generation + 2U, memory_order_release);
    atomic_flag_clear_explicit(&gDisplayWriteLock, memory_order_release);
}

static BOOL LoadDisplayState(LampState *state, double *phaseEnd, double *updatedAt) {
    for (unsigned attempt = 0; attempt < 3; attempt++) {
        unsigned generationBefore = atomic_load_explicit(
            &gDisplayGeneration, memory_order_acquire);
        if (generationBefore & 1U) continue;
        LampState localState = atomic_load_explicit(&gLampState, memory_order_relaxed);
        double localEnd = atomic_load_explicit(
            &gPhaseEndMonotonic, memory_order_relaxed);
        double localUpdated = atomic_load_explicit(
            &gTimetableUpdatedAt, memory_order_relaxed);
        unsigned generationAfter = atomic_load_explicit(
            &gDisplayGeneration, memory_order_acquire);
        if (generationBefore != generationAfter || (generationAfter & 1U)) continue;
        *state = localState;
        *phaseEnd = localEnd;
        *updatedAt = localUpdated;
        return YES;
    }
    return NO;
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

static BOOL PublishLiveCyclingPhase(double wallNow, double monotonicNow) {
    uint64_t rows[kMaxCyclingPhases * 3];
    uint32_t count = 0;
    if (!LoadCyclingTable(rows, &count) || !count) return NO;

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
    PublishDisplayState(state, monotonicNow + remaining, monotonicNow);
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

static BOOL PublishCurrentCarTimetable(const unsigned char *record,
                                       double wallNow, double monotonicNow,
                                       int nativeStatus,
                                       int64_t *publishedEnd) {
    if (!record || !PlausibleNativePointer((uintptr_t)record, 8)) return NO;
    uintptr_t containerBegin = 0, containerEnd = 0;
    memcpy(&containerBegin, record + 0x28, sizeof(containerBegin));
    memcpy(&containerEnd, record + 0x30, sizeof(containerEnd));
    if (!PlausibleNativeRange(containerBegin, containerEnd, 4096, 8) ||
        containerEnd - containerBegin < 0x20)
        return NO;

    for (uintptr_t container = containerBegin;
         container <= containerEnd - 0x20; container += 80) {
        uintptr_t phaseBegin = 0, phaseEnd = 0;
        memcpy(&phaseBegin, (const void *)(container + 0x10), sizeof(phaseBegin));
        memcpy(&phaseEnd, (const void *)(container + 0x18), sizeof(phaseEnd));
        if (!PlausibleNativeRange(phaseBegin, phaseEnd, 24 * 64, 8) ||
            phaseEnd - phaseBegin < 24 ||
            (phaseEnd - phaseBegin) % 24 != 0)
            continue;

        size_t phaseCount = (size_t)(phaseEnd - phaseBegin) / 24;
        for (size_t phaseIndex = 0; phaseIndex < phaseCount; phaseIndex++) {
            const unsigned char *phase =
                (const unsigned char *)(phaseBegin + phaseIndex * 24);
            int32_t phaseCode = 0;
            int64_t startsAt = 0, endsAt = 0;
            memcpy(&phaseCode, phase, sizeof(phaseCode));
            memcpy(&startsAt, phase + 8, sizeof(startsAt));
            memcpy(&endsAt, phase + 16, sizeof(endsAt));
            if (startsAt < 0 || endsAt <= startsAt ||
                endsAt - startsAt > 180 || wallNow < (double)startsAt ||
                wallNow >= (double)endsAt ||
                !PhaseCodeMatchesNative(phaseCode, nativeStatus))
                continue;

            LampState state = LampForNativeStatus(nativeStatus, phaseCode);
            if (state == LampUnknown) continue;
            PublishDisplayState(
                state, monotonicNow + ((double)endsAt - wallNow),
                monotonicNow);
            atomic_store_explicit(
                &gCarUpdatedAt, monotonicNow, memory_order_release);
            if (publishedEnd) *publishedEnd = endsAt;
            return YES;
        }
    }
    return NO;
}

static int HookActiveTrafficRecords(void *records) {
    int result = gOriginalActiveTrafficRecords
        ? gOriginalActiveTrafficRecords(records) : 0;

    if (!PlausibleNativePointer((uintptr_t)records, 8)) return result;
    uintptr_t begin = 0, end = 0;
    memcpy(&begin, (const unsigned char *)records + 8, sizeof(begin));
    memcpy(&end, (const unsigned char *)records + 16, sizeof(end));
    if (!PlausibleNativeRange(begin, end, 216 * 64, 8) ||
        (end - begin) % 216 != 0)
        return result;

    double wallNow = WallSeconds();
    double monotonicNow = MonotonicSeconds();
    int nativeStatus = atomic_load_explicit(
        &gNativeStatus, memory_order_acquire);
    size_t count = (size_t)(end - begin) / 216;
    static _Atomic double lastLogged;
    if (monotonicNow - atomic_load_explicit(
            &lastLogged, memory_order_relaxed) > 10.0) {
        atomic_store_explicit(&lastLogged, monotonicNow, memory_order_relaxed);
        LogLine("active traffic records count=%zu status=%d", count,
                nativeStatus);
    }
    int64_t phaseEnd = 0;
    BOOL published = NO;
    for (size_t index = 0; index < count && !published; index++) {
        const unsigned char *record = (const unsigned char *)(begin + index * 216);
        published = PublishCurrentCarTimetable(
            record, wallNow, monotonicNow, nativeStatus, &phaseEnd);
    }

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

static void *HookCyclingTimetableEvaluate(void *context, void *phases,
                                          uint64_t currentTime, void *outA,
                                          void *outB, int32_t mode) {
    void *result = gOriginalCyclingTimetableEvaluate
        ? gOriginalCyclingTimetableEvaluate(context, phases, currentTime,
                                            outA, outB, mode) : 0;
    ObserveCyclingTimetable(phases);
    return result;
}

// Travel/bike signal status serializer (unslid 0x788474): serializes the
// model {status @0x8, remainTime @0x10, mainAction @0x18, showType @0x1c}
// that feeds the bike route bubble. Same reliable production pattern as the
// car signal serializer.
static void *HookTravelStatusSerialize(void *model, void *serializer) {
    void *result = gOriginalTravelStatusSerialize
        ? gOriginalTravelStatusSerialize(model, serializer) : 0;
    static _Atomic double lastLogged;
    double now = WallSeconds();
    if (now - atomic_load_explicit(&lastLogged, memory_order_relaxed) > 5.0) {
        atomic_store_explicit(&lastLogged, now, memory_order_relaxed);
        int32_t status = -1, mainAction = -1, showType = -1;
        int64_t remainTime = -1;
        if (PlausibleNativePointer((uintptr_t)model, 4)) {
            memcpy(&status, (const char *)model + 0x08, sizeof(status));
            memcpy(&remainTime, (const char *)model + 0x10, sizeof(remainTime));
            memcpy(&mainAction, (const char *)model + 0x18, sizeof(mainAction));
            memcpy(&showType, (const char *)model + 0x1c, sizeof(showType));
        }
        LogLine("travel status st=%d remain=%lld action=%d show=%d",
                status, (long long)remainTime, mainAction, showType);
    }
    return result;
}

// Array variant (unslid 0x788568): fires whenever the travel signal list
// serializes, even when empty; distinguishes a dormant path from an empty
// list.
static void *HookTravelStatusArray(void *writer, void *unused, void *vector) {
    void *result = gOriginalTravelStatusArray
        ? gOriginalTravelStatusArray(writer, unused, vector) : 0;
    static _Atomic double lastLogged;
    double now = WallSeconds();
    if (now - atomic_load_explicit(&lastLogged, memory_order_relaxed) > 10.0) {
        atomic_store_explicit(&lastLogged, now, memory_order_relaxed);
        uint64_t begin = 0, end = 0;
        size_t count = 0;
        if (PlausibleNativePointer((uintptr_t)vector, 8)) {
            memcpy(&begin, vector, sizeof(begin));
            memcpy(&end, (const char *)vector + 8, sizeof(end));
            if (PlausibleNativeRange(begin, end, 32 * 1024, 8) && end >= begin)
                count = (size_t)((end - begin) >> 5);
            else
                count = (size_t)-1;
        }
        LogLine("travel array count=%zu", count);
    }
    return result;
}

static int ReadKnownInt32(const void *base, size_t offset) {
    if (!PlausibleNativePointer((uintptr_t)base, 4)) return -1;
    int32_t value = -1;
    memcpy(&value, (const char *)base + offset, sizeof(value));
    return value;
}

// Native route-guide builder for the @lightdistance@ placeholder. This is a
// normal virtual method with a standard ABI; AMap computes and writes +0x474.
static uintptr_t HookGuideLightDistanceBuild(void *formatter, void *route,
                                              uintptr_t index) {
    int before = ReadKnownInt32(formatter, 0x474);
    uintptr_t result = gOriginalGuideLightDistanceBuild
        ? gOriginalGuideLightDistanceBuild(formatter, route, index) : 0;
    int after = ReadKnownInt32(formatter, 0x474);
    int routeBase = ReadKnownInt32(route, 0x180);
    int routeMode = ReadKnownInt32(route, 0x370);
    atomic_store_explicit(&gGuideLightDistanceBefore, before,
                          memory_order_relaxed);
    atomic_store_explicit(&gGuideLightDistanceMeters, after,
                          memory_order_relaxed);
    atomic_store_explicit(&gGuideLightRouteBase, routeBase,
                          memory_order_relaxed);
    atomic_store_explicit(&gGuideLightRouteMode, routeMode,
                          memory_order_relaxed);
    atomic_store_explicit(&gGuideLightRouteIndex, index,
                          memory_order_relaxed);
    atomic_store_explicit(&gGuideLightUpdatedAt, WallSeconds(),
                          memory_order_relaxed);
    atomic_fetch_add_explicit(&gGuideLightBuildGeneration, 1,
                              memory_order_release);
    return result;
}

static void CaptureGuideLightFormat(void *formatter) {
    atomic_store_explicit(&gGuideLightDistanceMeters,
                          ReadKnownInt32(formatter, 0x474),
                          memory_order_relaxed);
    atomic_store_explicit(&gGuideLightUpdatedAt, WallSeconds(),
                          memory_order_relaxed);
    atomic_fetch_add_explicit(&gGuideLightFormatGeneration, 1,
                              memory_order_release);
}

static uintptr_t HookGuideLightDistanceFormatA(void *formatter) {
    CaptureGuideLightFormat(formatter);
    return gOriginalGuideLightDistanceFormatA
        ? gOriginalGuideLightDistanceFormatA(formatter) : 0;
}

static uintptr_t HookGuideLightDistanceFormatB(void *formatter) {
    CaptureGuideLightFormat(formatter);
    return gOriginalGuideLightDistanceFormatB
        ? gOriginalGuideLightDistanceFormatB(formatter) : 0;
}

static uintptr_t HookFirstLightStatsSerialize(uint32_t *stats,
                                               void *serializer) {
    if (PlausibleNativePointer((uintptr_t)stats, 4)) {
        uint32_t values[3] = {0};
        memcpy(values, stats, sizeof(values));
        atomic_store_explicit(&gFirstLightTotalCount, (int)values[0],
                              memory_order_relaxed);
        atomic_store_explicit(&gFirstLightDistanceMeters, (int)values[1],
                              memory_order_relaxed);
        atomic_store_explicit(&gFirstLightTimeSeconds, (int)values[2],
                              memory_order_relaxed);
        atomic_fetch_add_explicit(&gFirstLightStatsGeneration, 1,
                                  memory_order_release);
    }
    return gOriginalFirstLightStatsSerialize
        ? gOriginalFirstLightStatsSerialize(stats, serializer) : 0;
}

static void CaptureRouteSummary(void *summary) {
    if (!PlausibleNativePointer((uintptr_t)summary, 4)) return;
    atomic_store_explicit(&gRouteSummaryEtaDistance,
                          ReadKnownInt32(summary, 0xdc),
                          memory_order_relaxed);
    atomic_store_explicit(&gRouteSummaryEtaTime,
                          ReadKnownInt32(summary, 0xe0),
                          memory_order_relaxed);
    atomic_store_explicit(&gRouteSummaryRemainingLights,
                          ReadKnownInt32(summary, 0xe8),
                          memory_order_relaxed);
    atomic_fetch_add_explicit(&gRouteSummaryGeneration, 1,
                              memory_order_release);
}

static uintptr_t HookRouteSummarySerializeA(void *summary, void *serializer) {
    CaptureRouteSummary(summary);
    return gOriginalRouteSummarySerializeA
        ? gOriginalRouteSummarySerializeA(summary, serializer) : 0;
}

static uintptr_t HookRouteSummarySerializeB(void *summary, void *serializer) {
    CaptureRouteSummary(summary);
    return gOriginalRouteSummarySerializeB
        ? gOriginalRouteSummarySerializeB(summary, serializer) : 0;
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
                candidateCount++;
                if (currentOffset <= itemRangeEnd &&
                    currentOffset > itemOffset) {
                    memcpy(&signalId, (const void *)(item + 8),
                           sizeof(signalId));
                    targetOffset = itemOffset;
                    rangeEnd = itemRangeEnd;
                    distance = currentOffset - itemOffset;
                    break;
                }
            }
        }
    }
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

static int ReadKnownDistanceObject(void *pair, uintptr_t *objectOut) {
    if (objectOut) *objectOut = 0;
    if (!PlausibleNativePointer((uintptr_t)pair, 8)) return -1;
    uintptr_t object = 0;
    memcpy(&object, pair, sizeof(object));
    if (!PlausibleNativePointer(object, 4)) return -1;
    int32_t value = -1;
    memcpy(&value, (const void *)(object + 0x1c), sizeof(value));
    if (value < -1000 || value > 1000000) return -1;
    if (objectOut) *objectOut = object;
    return value;
}

// Standard-ABI envelope around the custom-register distancetolight formatter.
// Its third argument is the native current-object pair consumed by the inner
// function; +0x1c is passed directly as the distancetolight value.
static uintptr_t HookRouteDistanceEnvelope(void *context, void *previous,
                                            void *current, void *extra) {
    uintptr_t result = gOriginalRouteDistanceEnvelope
        ? gOriginalRouteDistanceEnvelope(context, previous, current, extra)
        : 0;
    uintptr_t object = 0;
    int distance = ReadKnownDistanceObject(current, &object);
    atomic_store_explicit(&gRouteDistanceEnvelopeMeters, distance,
                          memory_order_relaxed);
    atomic_store_explicit(&gRouteDistanceEnvelopeObject, object,
                          memory_order_relaxed);
    atomic_store_explicit(&gRouteDistanceUpdatedAt, WallSeconds(),
                          memory_order_relaxed);
    atomic_fetch_add_explicit(&gRouteDistanceGeneration, 1,
                              memory_order_release);
    return result;
}

// A second standard-ABI producer builds current/next object pairs at +0xc0 and
// +0xd0 before invoking its custom-register distance formatter.
static uintptr_t HookRouteDistanceContext(void *context) {
    uintptr_t result = gOriginalRouteDistanceContext
        ? gOriginalRouteDistanceContext(context) : 0;
    uintptr_t firstObject = 0, secondObject = 0;
    int first = -1, second = -1;
    if (PlausibleNativePointer((uintptr_t)context, 8)) {
        first = ReadKnownDistanceObject((char *)context + 0xc0,
                                        &firstObject);
        second = ReadKnownDistanceObject((char *)context + 0xd0,
                                         &secondObject);
    }
    int distance = first >= 0 ? first : second;
    uintptr_t object = first >= 0 ? firstObject : secondObject;
    atomic_store_explicit(&gRouteDistanceContextMeters, distance,
                          memory_order_relaxed);
    atomic_store_explicit(&gRouteDistanceContextObject, object,
                          memory_order_relaxed);
    atomic_store_explicit(&gRouteDistanceUpdatedAt, WallSeconds(),
                          memory_order_relaxed);
    atomic_fetch_add_explicit(&gRouteDistanceGeneration, 1,
                              memory_order_release);
    return result;
}

// Native multiple-traffic-light selector (unslid 0x11FE7D4). AMap itself
// computes currentRouteOffset - trafficLightRouteOffset and compares the result
// with trafficlight_display_distance (default 500 m). Observe the same primitive
// route fields at this standard-ABI boundary; do not read GPS or coordinates.
static void *HookTrafficSignalRenderUpdate(void *controller, void *trafficData,
                                            void *navigationState) {
    int bestDistance = -1;
    int currentOffset = 0;
    int targetOffset = 0;
    uint64_t selectedLinkId = 0;
    uint32_t currentLink = 0;
    unsigned candidateCount = 0;

    if (PlausibleNativePointer((uintptr_t)controller, 4) &&
        PlausibleNativePointer((uintptr_t)trafficData, 8) &&
        PlausibleNativePointer((uintptr_t)navigationState, 4)) {
        uint64_t begin = 0, end = 0;
        int32_t displayLimit = 0;
        memcpy(&begin, (const char *)trafficData + 0x128, sizeof(begin));
        memcpy(&end, (const char *)trafficData + 0x130, sizeof(end));
        memcpy(&displayLimit, (const char *)controller + 0x54,
               sizeof(displayLimit));
        memcpy(&currentOffset, (const char *)navigationState + 0x0c,
               sizeof(currentOffset));
        memcpy(&currentLink, (const char *)navigationState + 0x28,
               sizeof(currentLink));

        if (displayLimit > 0 && displayLimit <= 5000 &&
            PlausibleNativeRange(begin, end, 128 * 0xe8, 8) && end >= begin &&
            (end - begin) % 0xe8 == 0) {
            unsigned count = (unsigned)((end - begin) / 0xe8);
            for (unsigned index = 0; index < count; ++index) {
                uintptr_t item = (uintptr_t)begin + index * 0xe8;
                int32_t active = 0, signalOffset = 0;
                uint32_t signalLink = 0;
                uint64_t linkId = 0;
                memcpy(&active, (const void *)(item + 0x08), sizeof(active));
                memcpy(&signalOffset, (const void *)(item + 0x4c),
                       sizeof(signalOffset));
                memcpy(&linkId, (const void *)(item + 0x60), sizeof(linkId));
                memcpy(&signalLink, (const void *)(item + 0x68),
                       sizeof(signalLink));
                if (active != 1) continue;

                int distance = currentOffset - signalOffset;
                BOOL sameLink = signalLink == currentLink;
                if (!sameLink && (distance < 1 || distance > displayLimit))
                    continue;
                candidateCount++;
                if (bestDistance < 0 ||
                    (distance >= 0 && distance < bestDistance)) {
                    bestDistance = distance;
                    targetOffset = signalOffset;
                    selectedLinkId = linkId;
                }
            }
        }
    }

    atomic_store_explicit(&gSignalDistanceCandidateCount, candidateCount,
                          memory_order_relaxed);
    atomic_store_explicit(&gSignalDistanceMeters, bestDistance,
                          memory_order_relaxed);
    atomic_store_explicit(&gSignalDistanceCurrentOffset, currentOffset,
                          memory_order_relaxed);
    atomic_store_explicit(&gSignalDistanceTargetOffset, targetOffset,
                          memory_order_relaxed);
    atomic_store_explicit(&gSignalDistanceLinkId, selectedLinkId,
                          memory_order_relaxed);
    atomic_store_explicit(&gSignalDistanceCurrentLink, currentLink,
                          memory_order_relaxed);
    atomic_store_explicit(&gSignalDistanceUpdatedAt, WallSeconds(),
                          memory_order_relaxed);
    atomic_fetch_add_explicit(&gSignalDistanceGeneration, 1,
                              memory_order_release);

    return gOriginalTrafficSignalRenderUpdate
        ? gOriginalTrafficSignalRenderUpdate(controller, trafficData,
                                             navigationState)
        : 0;
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
        double monotonicNow = MonotonicSeconds();
        if (monotonicNow - atomic_load_explicit(
                &gCarUpdatedAt, memory_order_acquire) > 2.5)
            PublishDisplayState(LampUnknown, 0, 0);
    }

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
    hook((void *)(base + 0x00788410ULL), (void *)HookSignalStatusSerialize,
         (void **)&gOriginalSignalStatusSerialize);
    // Travel/bike signal status model serializer.
    hook((void *)(base + 0x00788474ULL), (void *)HookTravelStatusSerialize,
         (void **)&gOriginalTravelStatusSerialize);
    hook((void *)(base + 0x0078856CULL), (void *)HookTravelStatusArray,
         (void **)&gOriginalTravelStatusArray);
    // Native route-guide traffic-light distance and route-summary models.
    // These are standard-ABI functions; custom-register leaf fragments stay
    // unhooked.
    hook((void *)(base + 0x0003367CULL),
         (void *)HookGuideLightDistanceBuild,
         (void **)&gOriginalGuideLightDistanceBuild);
    hook((void *)(base + 0x00033BCCULL),
         (void *)HookGuideLightDistanceFormatA,
         (void **)&gOriginalGuideLightDistanceFormatA);
    hook((void *)(base + 0x00034E54ULL),
         (void *)HookGuideLightDistanceFormatB,
         (void **)&gOriginalGuideLightDistanceFormatB);
    hook((void *)(base + 0x00729DF4ULL),
         (void *)HookFirstLightStatsSerialize,
         (void **)&gOriginalFirstLightStatsSerialize);
    hook((void *)(base + 0x007B626CULL),
         (void *)HookRouteSummarySerializeA,
         (void **)&gOriginalRouteSummarySerializeA);
    hook((void *)(base + 0x007B6B64ULL),
         (void *)HookRouteSummarySerializeB,
         (void **)&gOriginalRouteSummarySerializeB);
    // Standard-ABI envelopes around native distancetolight producers. The
    // custom-register formatting fragments themselves remain unhooked.
    hook((void *)(base + 0x0013E2A4ULL),
         (void *)HookRouteDistanceEnvelope,
         (void **)&gOriginalRouteDistanceEnvelope);
    hook((void *)(base + 0x001CF300ULL),
         (void *)HookRouteDistanceContext,
         (void **)&gOriginalRouteDistanceContext);
    // Standard-ABI native route-distance selector for traffic-light render
    // groups. Diagnostic only; it does not read GPS or alter the HUD.
    hook((void *)(base + 0x011FE7D4ULL),
         (void *)HookTrafficSignalRenderUpdate,
         (void **)&gOriginalTrafficSignalRenderUpdate);
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
        memcpy(prologue, (const void *)(base + 0x00788474ULL),
               sizeof(prologue));
        LogLine("prologue travel-status %08x %08x %08x %08x",
                prologue[0], prologue[1], prologue[2], prologue[3]);
        memcpy(prologue, (const void *)(base + 0x0078856CULL),
               sizeof(prologue));
        LogLine("prologue travel-array %08x %08x %08x %08x",
                prologue[0], prologue[1], prologue[2], prologue[3]);
        memcpy(prologue, (const void *)(base + 0x0003367CULL),
               sizeof(prologue));
        LogLine("prologue guide-light-build %08x %08x %08x %08x",
                prologue[0], prologue[1], prologue[2], prologue[3]);
        memcpy(prologue, (const void *)(base + 0x00033BCCULL),
               sizeof(prologue));
        LogLine("prologue guide-light-format-a %08x %08x %08x %08x",
                prologue[0], prologue[1], prologue[2], prologue[3]);
        memcpy(prologue, (const void *)(base + 0x00034E54ULL),
               sizeof(prologue));
        LogLine("prologue guide-light-format-b %08x %08x %08x %08x",
                prologue[0], prologue[1], prologue[2], prologue[3]);
        memcpy(prologue, (const void *)(base + 0x00729DF4ULL),
               sizeof(prologue));
        LogLine("prologue first-light-stats %08x %08x %08x %08x",
                prologue[0], prologue[1], prologue[2], prologue[3]);
        memcpy(prologue, (const void *)(base + 0x007B626CULL),
               sizeof(prologue));
        LogLine("prologue route-summary-a %08x %08x %08x %08x",
                prologue[0], prologue[1], prologue[2], prologue[3]);
        memcpy(prologue, (const void *)(base + 0x007B6B64ULL),
               sizeof(prologue));
        LogLine("prologue route-summary-b %08x %08x %08x %08x",
                prologue[0], prologue[1], prologue[2], prologue[3]);
        memcpy(prologue, (const void *)(base + 0x0013E2A4ULL),
               sizeof(prologue));
        LogLine("prologue distance-envelope %08x %08x %08x %08x",
                prologue[0], prologue[1], prologue[2], prologue[3]);
        memcpy(prologue, (const void *)(base + 0x001CF300ULL),
               sizeof(prologue));
        LogLine("prologue distance-context %08x %08x %08x %08x",
                prologue[0], prologue[1], prologue[2], prologue[3]);
        memcpy(prologue, (const void *)(base + 0x011FE7D4ULL),
               sizeof(prologue));
        LogLine("prologue signal-distance %08x %08x %08x %08x",
                prologue[0], prologue[1], prologue[2], prologue[3]);
        memcpy(prologue, (const void *)(base + 0x0120EF04ULL),
               sizeof(prologue));
        LogLine("prologue active-signal-route %08x %08x %08x %08x",
                prologue[0], prologue[1], prologue[2], prologue[3]);
        memcpy(prologue, (const void *)(base + 0x0120F380ULL),
               sizeof(prologue));
        LogLine("prologue dynamic-signal %08x %08x %08x %08x",
                prologue[0], prologue[1], prologue[2], prologue[3]);
    }
    hook((void *)(base + 0x011FF8C0ULL), (void *)HookActiveTrafficRecords,
         (void **)&gOriginalActiveTrafficRecords);
    // Bicycle observation goes through the standard-ABI wrapper, never the
    // fragile 0x840548 leaf (see ObserveCyclingTimetable).
    hook((void *)(base + 0x00840490ULL), (void *)HookCyclingTimetableEvaluate,
         (void **)&gOriginalCyclingTimetableEvaluate);
    LogLine("native countdown hooks installed base=%p", (void *)base);
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
    CGFloat lampTop = height > 500 ? 92.0 : 54.0;
    CGFloat numberTop = lampTop + 70.0;
    CGFloat numberHeight = height - numberTop - 190.0;
    if (numberHeight < 160.0) numberHeight = 160.0;
    SetRect(gFullLampLabel, "setFrame:",
            (CGRect){{24, lampTop}, {width - 48, 56}});
    SetRect(gFullSecondsLabel, "setFrame:",
            (CGRect){{20, numberTop}, {width - 40, numberHeight}});
    FitFullscreenNumberFont(width - 40, numberHeight);
    SetRect(gFullUnitLabel, "setFrame:",
            (CGRect){{20, numberTop + numberHeight}, {width - 40, 42}});
    SetRect(gFullDisclaimerLabel, "setFrame:",
            (CGRect){{20, height - 72}, {width - 40, 30}});

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
            gFullDisclaimerLabel = CreateLabel(fullFrame, 15.0, 1);
            if (gFullLampLabel)
                MsgVoidObj(gFullView, "addSubview:", gFullLampLabel);
            if (gFullSecondsLabel)
                MsgVoidObj(gFullView, "addSubview:", gFullSecondsLabel);
            if (gFullUnitLabel)
                MsgVoidObj(gFullView, "addSubview:", gFullUnitLabel);
            if (gFullDisclaimerLabel)
                MsgVoidObj(gFullView, "addSubview:", gFullDisclaimerLabel);
            MsgVoidObj(gFullUnitLabel, "setText:",
                       NSStr("秒 · 距路口 --米"));
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

static void UpdateOverlay(void) {
    if (!gBall) return;
    double now = MonotonicSeconds();
    LampState state = LampUnknown;
    double phaseEnd = 0, updatedAt = 0;
    BOOL snapshotReady = LoadDisplayState(&state, &phaseEnd, &updatedAt);
    double remaining = phaseEnd - now;
    int seconds = -1;
    if (snapshotReady && updatedAt > 0 && now - updatedAt <= 2.5 &&
        remaining >= -0.2 && remaining <= 180.0 && state != LampUnknown)
        seconds = remaining > 0 ? (int)ceil(remaining) : 0;
    if (seconds < 0) state = LampUnknown;
    gCurrentSeconds = seconds;

    int distance = atomic_load_explicit(&gActiveSignalRouteDistance,
                                        memory_order_relaxed);
    unsigned distanceCandidates = atomic_load_explicit(
        &gActiveSignalRouteCandidateCount, memory_order_relaxed);
    double distanceUpdatedAt = atomic_load_explicit(
        &gActiveSignalRouteUpdatedAt, memory_order_relaxed);
    double distanceAge = WallSeconds() - distanceUpdatedAt;
    if (seconds < 0 || distanceCandidates != 1 || distance < 0 ||
        distance > 2000 || distanceAge < 0 || distanceAge > 2.5)
        distance = -1;

    char secondsText[16];
    char distanceText[32];
    char unitText[64];
    snprintf(secondsText, sizeof(secondsText), seconds >= 0 ? "%d" : "--",
             seconds);
    if (distance < 0) {
        snprintf(distanceText, sizeof(distanceText), "--米");
    } else if (distance < 1000) {
        snprintf(distanceText, sizeof(distanceText), "%d米", distance);
    } else {
        snprintf(distanceText, sizeof(distanceText), "%.1f公里",
                 (double)distance / 1000.0);
    }
    snprintf(unitText, sizeof(unitText), "秒 · 距路口 %s", distanceText);
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
        MsgVoidObj(gFullDisclaimerLabel, "setTextColor:", textColor);
        MsgVoidObj(gFullLampLabel, "setText:", NSStr(LampName(state)));
        MsgVoidObj(gFullSecondsLabel, "setText:", NSStr(secondsText));
        MsgVoidObj(gFullUnitLabel, "setText:", NSStr(unitText));
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
    static unsigned lastSignalDistanceGeneration;
    static unsigned lastRouteDistanceGeneration;
    static unsigned lastGuideLightBuildGeneration;
    static unsigned lastGuideLightFormatGeneration;
    static unsigned lastFirstLightStatsGeneration;
    static unsigned lastRouteSummaryGeneration;
    static unsigned lastActiveSignalRouteGeneration;
    static int lastLoggedActiveSignalDistance = -2;
    static double lastActiveSignalRouteLogAt;
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
        unsigned captured = phaseCount < 4 ? phaseCount : 4;
        for (unsigned i = 0; i < captured; ++i) {
            int32_t code = (int32_t)atomic_load_explicit(
                &gTrafficSignalPhaseRows[i * 3], memory_order_relaxed);
            int64_t startsAt = (int64_t)atomic_load_explicit(
                &gTrafficSignalPhaseRows[i * 3 + 1], memory_order_relaxed);
            int64_t endsAt = (int64_t)atomic_load_explicit(
                &gTrafficSignalPhaseRows[i * 3 + 2], memory_order_relaxed);
            LogLine("dynamic phase[%u] code=%d start=%lld end=%lld", i,
                    code, (long long)startsAt, (long long)endsAt);
        }
    }
    unsigned signalDistanceGeneration = atomic_load_explicit(
        &gSignalDistanceGeneration, memory_order_acquire);
    if (signalDistanceGeneration != lastSignalDistanceGeneration) {
        lastSignalDistanceGeneration = signalDistanceGeneration;
        int distance = atomic_load_explicit(
            &gSignalDistanceMeters, memory_order_relaxed);
        unsigned candidates = atomic_load_explicit(
            &gSignalDistanceCandidateCount, memory_order_relaxed);
        int currentOffset = atomic_load_explicit(
            &gSignalDistanceCurrentOffset, memory_order_relaxed);
        int targetOffset = atomic_load_explicit(
            &gSignalDistanceTargetOffset, memory_order_relaxed);
        uint64_t linkId = atomic_load_explicit(
            &gSignalDistanceLinkId, memory_order_relaxed);
        uint32_t currentLink = atomic_load_explicit(
            &gSignalDistanceCurrentLink, memory_order_relaxed);
        double updatedAt = atomic_load_explicit(
            &gSignalDistanceUpdatedAt, memory_order_relaxed);
        LogLine("native signal distance=%d candidates=%u current=%d target=%d link=%llu navlink=%u age=%.1f gen=%u",
                distance, candidates, currentOffset, targetOffset,
                (unsigned long long)linkId, currentLink,
                WallSeconds() - updatedAt, signalDistanceGeneration);
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
    unsigned guideBuildGeneration = atomic_load_explicit(
        &gGuideLightBuildGeneration, memory_order_acquire);
    unsigned guideFormatGeneration = atomic_load_explicit(
        &gGuideLightFormatGeneration, memory_order_acquire);
    if (guideBuildGeneration != lastGuideLightBuildGeneration ||
        guideFormatGeneration != lastGuideLightFormatGeneration) {
        lastGuideLightBuildGeneration = guideBuildGeneration;
        lastGuideLightFormatGeneration = guideFormatGeneration;
        LogLine("guide light distance=%d before=%d base=%d mode=%d index=%llu build=%u format=%u age=%.1f",
                atomic_load_explicit(&gGuideLightDistanceMeters,
                                     memory_order_relaxed),
                atomic_load_explicit(&gGuideLightDistanceBefore,
                                     memory_order_relaxed),
                atomic_load_explicit(&gGuideLightRouteBase,
                                     memory_order_relaxed),
                atomic_load_explicit(&gGuideLightRouteMode,
                                     memory_order_relaxed),
                (unsigned long long)atomic_load_explicit(
                    &gGuideLightRouteIndex, memory_order_relaxed),
                guideBuildGeneration, guideFormatGeneration,
                WallSeconds() - atomic_load_explicit(
                    &gGuideLightUpdatedAt, memory_order_relaxed));
    }
    unsigned firstLightStatsGeneration = atomic_load_explicit(
        &gFirstLightStatsGeneration, memory_order_acquire);
    if (firstLightStatsGeneration != lastFirstLightStatsGeneration) {
        lastFirstLightStatsGeneration = firstLightStatsGeneration;
        LogLine("first light stats count=%d distance=%d time=%d gen=%u",
                atomic_load_explicit(&gFirstLightTotalCount,
                                     memory_order_relaxed),
                atomic_load_explicit(&gFirstLightDistanceMeters,
                                     memory_order_relaxed),
                atomic_load_explicit(&gFirstLightTimeSeconds,
                                     memory_order_relaxed),
                firstLightStatsGeneration);
    }
    unsigned routeSummaryGeneration = atomic_load_explicit(
        &gRouteSummaryGeneration, memory_order_acquire);
    if (routeSummaryGeneration != lastRouteSummaryGeneration) {
        lastRouteSummaryGeneration = routeSummaryGeneration;
        LogLine("route summary etaDistance=%d etaTime=%d remainingLights=%d gen=%u",
                atomic_load_explicit(&gRouteSummaryEtaDistance,
                                     memory_order_relaxed),
                atomic_load_explicit(&gRouteSummaryEtaTime,
                                     memory_order_relaxed),
                atomic_load_explicit(&gRouteSummaryRemainingLights,
                                     memory_order_relaxed),
                routeSummaryGeneration);
    }
    unsigned routeDistanceGeneration = atomic_load_explicit(
        &gRouteDistanceGeneration, memory_order_acquire);
    if (routeDistanceGeneration != lastRouteDistanceGeneration) {
        lastRouteDistanceGeneration = routeDistanceGeneration;
        int envelopeDistance = atomic_load_explicit(
            &gRouteDistanceEnvelopeMeters, memory_order_relaxed);
        int contextDistance = atomic_load_explicit(
            &gRouteDistanceContextMeters, memory_order_relaxed);
        uintptr_t envelopeObject = atomic_load_explicit(
            &gRouteDistanceEnvelopeObject, memory_order_relaxed);
        uintptr_t contextObject = atomic_load_explicit(
            &gRouteDistanceContextObject, memory_order_relaxed);
        double updatedAt = atomic_load_explicit(
            &gRouteDistanceUpdatedAt, memory_order_relaxed);
        LogLine("route distance envelope=%d object=%p context=%d object=%p age=%.1f gen=%u",
                envelopeDistance, (void *)envelopeObject, contextDistance,
                (void *)contextObject, WallSeconds() - updatedAt,
                routeDistanceGeneration);
    }
    double anow = WallSeconds();
    if (anow - atomic_load_explicit(&lastAlive, memory_order_relaxed) > 15.0) {
        atomic_store_explicit(&lastAlive, anow, memory_order_relaxed);
        LogLine("tick alive ball=%p expanded=%d", gBall,
                gExpanded ? 1 : 0);
    }
    EnsureOverlay(KeyWindow());
    double monotonicNow = MonotonicSeconds();
    if (monotonicNow - atomic_load_explicit(
            &gCarUpdatedAt, memory_order_acquire) > 2.5)
        PublishLiveCyclingPhase(WallSeconds(), monotonicNow);
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
    LogLine("countdown HUD started; no OCR, network, GPS collection, geospatial distance inference, speed, or advice");
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
