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
typedef void *(*PublishCountdownFn)(void *bus, void *event);
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
static PublishCountdownFn gOriginalPublishCountdown;
static ActiveTrafficRecordsFn gOriginalActiveTrafficRecords;
static CyclingTimetableEvaluateFn gOriginalCyclingTimetableEvaluate;
static _Atomic int gNativeStatus = -1;
static _Atomic LampState gLampState = LampUnknown;
static _Atomic double gPhaseEndMonotonic;
static _Atomic double gTimetableUpdatedAt;
static _Atomic double gCarUpdatedAt;
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
static id gOverlay;
static BOOL gStarted;
static BOOL gHooksInstalled;

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
    if (count > kMaxCyclingPhases) count = kMaxCyclingPhases;
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

    // Validate every record first, then publish the whole table under the
    // seqlock so the HUD timer can walk intervals locally and follow every
    // transition (green -> yellow gap -> red -> green) from a single push.
    uint64_t rows[kMaxCyclingPhases * 3];
    size_t kept = 0;
    for (size_t index = 0; index < count; index++) {
        const unsigned char *record = (const unsigned char *)(begin + index * 24);
        int32_t code = 0, padding = 0;
        int64_t startsAt = 0, endsAt = 0;
        memcpy(&code, record, sizeof(code));
        memcpy(&padding, record + 4, sizeof(padding));
        memcpy(&startsAt, record + 8, sizeof(startsAt));
        memcpy(&endsAt, record + 16, sizeof(endsAt));
        if (padding != 0 || startsAt <= 0 || endsAt <= startsAt ||
            endsAt - startsAt > 180)
            continue;
        rows[kept * 3] = (uint32_t)code;
        rows[kept * 3 + 1] = (uint64_t)startsAt;
        rows[kept * 3 + 2] = (uint64_t)endsAt;
        kept++;
    }
    if (!kept) {
        if (probeDue)
            LogLine("cycling probe kept=0 rejected");
        return;
    }

    uint64_t header = atomic_load_explicit(
        &gCyclingTable[0], memory_order_relaxed);
    atomic_store_explicit(&gCyclingTable[0],
                          header | kCyclingTableBusy, memory_order_relaxed);
    for (size_t index = 0; index < kept * 3; index++)
        atomic_store_explicit(&gCyclingTable[1 + index], rows[index],
                              memory_order_relaxed);
    atomic_store_explicit(&gCyclingTable[0],
                          ((header + 0x100ULL) & ~kCyclingTableBusy) | kept,
                          memory_order_release);
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

// Cruise signal countdown publisher tap: dumps the raw event payload so the
// field layout can be decoded against the visible bubble.
static void *HookPublishCountdown(void *bus, void *event) {
    static _Atomic double lastLogged;
    double now = WallSeconds();
    if (now - atomic_load_explicit(&lastLogged, memory_order_relaxed) > 1.0 &&
        PlausibleNativePointer((uintptr_t)event, 4)) {
        atomic_store_explicit(&lastLogged, now, memory_order_relaxed);
        uint64_t w[3] = {0};
        memcpy(w, event, sizeof(w));
        LogLine("cruise countdown evt %016llx %016llx %016llx",
                (unsigned long long)w[0], (unsigned long long)w[1],
                (unsigned long long)w[2]);
    }
    return gOriginalPublishCountdown
        ? gOriginalPublishCountdown(bus, event) : 0;
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
    // Standard-ABI travel event publisher. Unlike the shared JSON/event-bus
    // helpers, this function establishes its own x0/x1 frame and is safe for
    // a plain C hook.
    hook((void *)(base + 0x010FE0FCULL), (void *)HookPublishCountdown,
         (void **)&gOriginalPublishCountdown);
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
        memcpy(prologue, (const void *)(base + 0x010FE0FCULL),
               sizeof(prologue));
        LogLine("prologue countdown-publish %08x %08x %08x %08x",
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

static void EnsureOverlay(id window) {
    if (!window) return;
    if (!gOverlay) {
        Class labelClass = C("UILabel");
        if (!labelClass) return;
        CGRect initial = {{10, 52}, {300, 44}};
        id allocated = ((id (*)(id, SEL))objc_msgSend)((id)labelClass, S("alloc"));
        gOverlay = ((id (*)(id, SEL, CGRect))objc_msgSend)(
            allocated, S("initWithFrame:"), initial);
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(
            gOverlay, S("setTextAlignment:"), 1);
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(
            gOverlay, S("setNumberOfLines:"), 2);
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            gOverlay, S("setUserInteractionEnabled:"), NO);

        Class colorClass = C("UIColor");
        if (colorClass) {
            MsgVoidObj(gOverlay, "setTextColor:", MsgId((id)colorClass, "whiteColor"));
            id background = ((id (*)(id, SEL, CGFloat, CGFloat))objc_msgSend)(
                (id)colorClass, S("colorWithWhite:alpha:"), 0.05, 0.78);
            MsgVoidObj(gOverlay, "setBackgroundColor:", background);
        }
        Class fontClass = C("UIFont");
        if (fontClass) {
            id font = ((id (*)(id, SEL, CGFloat))objc_msgSend)(
                (id)fontClass, S("boldSystemFontOfSize:"), 14.0);
            MsgVoidObj(gOverlay, "setFont:", font);
        }
        id layer = MsgId(gOverlay, "layer");
        if (layer) {
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(
                layer, S("setCornerRadius:"), 10.0);
            ((void (*)(id, SEL, BOOL))objc_msgSend)(
                layer, S("setMasksToBounds:"), YES);
        }
    }

    CGRect bounds = MsgRect(window, "bounds");
    CGFloat width = bounds.size.width > 40 ? bounds.size.width - 20 : 300;
    SetRect(gOverlay, "setFrame:", (CGRect){{10, 52}, {width, 44}});
    id currentWindow = MsgId(gOverlay, "window");
    if (currentWindow != window) MsgVoidObj(window, "addSubview:", gOverlay);
    if (Responds(window, "bringSubviewToFront:"))
        MsgVoidObj(window, "bringSubviewToFront:", gOverlay);
}

static const char *LampName(LampState state) {
    if (state == LampRed) return "红灯";
    if (state == LampYellow) return "黄灯";
    if (state == LampGreen) return "绿灯";
    return "未知";
}

static void UpdateOverlay(void) {
    if (!gOverlay) return;
    double now = MonotonicSeconds();
    LampState state = LampUnknown;
    double phaseEnd = 0, updatedAt = 0;
    BOOL snapshotReady = LoadDisplayState(&state, &phaseEnd, &updatedAt);
    double remaining = phaseEnd - now;
    char text[256];
    if (snapshotReady && updatedAt > 0 && now - updatedAt <= 2.5 &&
        remaining >= -0.2 && remaining <= 180.0 && state != LampUnknown) {
        int seconds = remaining > 0 ? (int)ceil(remaining) : 0;
        snprintf(text, sizeof(text),
                 "信号灯倒计时｜%s %d秒\n仅供参考，以现场信号灯为准",
                 LampName(state), seconds);
    } else {
        snprintf(text, sizeof(text),
                 "信号灯倒计时｜等待高德数据…\n仅供参考，以现场信号灯为准");
    }
    MsgVoidObj(gOverlay, "setText:", NSStr(text));
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
    double anow = WallSeconds();
    if (anow - atomic_load_explicit(&lastAlive, memory_order_relaxed) > 15.0) {
        atomic_store_explicit(&lastAlive, anow, memory_order_relaxed);
        LogLine("tick alive overlay=%p", gOverlay);
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
    LogLine("countdown HUD started; no OCR, network, location, distance inference, speed, or advice");
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
    gController = MsgId((id)controllerClass, "new");
    if (gController && Responds(gController, "performSelector:withObject:afterDelay:")) {
        ((void (*)(id, SEL, SEL, id, double))objc_msgSend)(
            gController, S("performSelector:withObject:afterDelay:"),
            S("dsh_start:"), 0, 0.5);
    }
}
