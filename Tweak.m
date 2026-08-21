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
// Floating-ball HUD: a round ball that tints with the lamp color and shows
// the remaining seconds; tapping it expands a fullscreen countdown sign.
static id gBall;
static id gBallLabel;
static id gFullLabel;
static id gFullTap;
static id gBallTap;
static BOOL gExpanded;
static BOOL gBallPositioned;
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

    if (state == LampUnknown || endsAt <= now) return NO;
    double remaining = (double)(endsAt - now);
    if (remaining > 180.0) return NO;
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

static id LampColor(LampState state) {
    Class colorClass = C("UIColor");
    if (!colorClass) return (id)0;
    CGFloat red = 0.25, green = 0.25, blue = 0.28, alpha = 0.92;
    if (state == LampRed) {
        red = 0.88; green = 0.16; blue = 0.16; alpha = 1.0;
    } else if (state == LampYellow) {
        red = 0.96; green = 0.72; blue = 0.06; alpha = 1.0;
    } else if (state == LampGreen) {
        red = 0.14; green = 0.70; blue = 0.30; alpha = 1.0;
    }
    return ((id (*)(id, SEL, CGFloat, CGFloat, CGFloat, CGFloat))objc_msgSend)(
        (id)colorClass, S("colorWithRed:green:blue:alpha:"),
        red, green, blue, alpha);
}

static void ApplyLayout(id window) {
    if (!gBall || !window) return;
    CGRect bounds = MsgRect(window, "bounds");
    CGFloat width = bounds.size.width, height = bounds.size.height;
    if (width < 60 || height < 60) return;
    if (gExpanded && gFullLabel)
        SetRect(gFullLabel, "setFrame:", (CGRect){{0, 0}, {width, height}});
    CGPoint center = ((CGPoint (*)(id, SEL))objc_msgSend)(gBall, S("center"));
    if (!gBallPositioned) {
        center.x = width - 54;
        center.y = 120;
        gBallPositioned = YES;
    }
    if (center.x < 36) center.x = 36;
    if (center.y < 36) center.y = 36;
    if (center.x > width - 36) center.x = width - 36;
    if (center.y > height - 36) center.y = height - 36;
    ((void (*)(id, SEL, CGPoint))objc_msgSend)(gBall, S("setCenter:"), center);
}

static void ToggleExpanded(id self, SEL command, id gesture) {
    (void)self;
    (void)command;
    (void)gesture;
    if (!gBall || !gFullLabel) return;
    // Fullscreen sign only makes sense with a live countdown; ignore taps
    // while the ball has no data.
    if (!gExpanded && gCurrentSeconds < 0) {
        LogLine("hud toggle ignored: no countdown data");
        return;
    }
    gExpanded = !gExpanded;
    LogLine("hud toggle expanded=%d seconds=%d", gExpanded ? 1 : 0,
            gCurrentSeconds);
    id window = KeyWindow();
    if (gExpanded) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            gFullLabel, S("setHidden:"), NO);
        if (window) {
            MsgVoidObj(window, "addSubview:", gFullLabel);
            if (Responds(window, "bringSubviewToFront:"))
                MsgVoidObj(window, "bringSubviewToFront:", gFullLabel);
        }
    } else {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            gFullLabel, S("setHidden:"), YES);
        MsgVoid(gFullLabel, "removeFromSuperview");
    }
    ApplyLayout(window ? window : KeyWindow());
    UpdateOverlay();
}

// Pan on the ball drags it; a separate tap gesture toggles the fullscreen
// countdown sign (see dsh_toggle:).
static void HandlePan(id self, SEL command, id gesture) {
    (void)self;
    (void)command;
    if (!gBall || !gesture) return;
    NSInteger state = (NSInteger)((long (*)(id, SEL))objc_msgSend)(
        gesture, S("state"));
    id superview = MsgId(gBall, "superview");
    CGPoint translation =
        ((CGPoint (*)(id, SEL, id))objc_msgSend)(
            gesture, S("translationInView:"), superview);
    if (state == 1 || state == 2) {
        CGPoint center = ((CGPoint (*)(id, SEL))objc_msgSend)(gBall, S("center"));
        center.x += translation.x;
        center.y += translation.y;
        ((void (*)(id, SEL, CGPoint))objc_msgSend)(gBall, S("setCenter:"), center);
        CGPoint zeroTranslation = {0, 0};
        ((void (*)(id, SEL, CGPoint, id))objc_msgSend)(
            gesture, S("setTranslation:inView:"), zeroTranslation, superview);
        ApplyLayout(MsgId(gBall, "window"));
    }
}

static void EnsureOverlay(id window) {
    if (!window) return;
    if (!gBall) {
        Class viewClass = C("UIView");
        Class labelClass = C("UILabel");
        if (!viewClass || !labelClass) return;

        CGRect ballFrame = {{0, 0}, {68, 68}};
        id ballAllocated = ((id (*)(id, SEL))objc_msgSend)((id)viewClass, S("alloc"));
        gBall = ((id (*)(id, SEL, CGRect))objc_msgSend)(
            ballAllocated, S("initWithFrame:"), ballFrame);
        if (!gBall) return;
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            gBall, S("setUserInteractionEnabled:"), YES);

        id labelAllocated = ((id (*)(id, SEL))objc_msgSend)((id)labelClass, S("alloc"));
        gBallLabel = ((id (*)(id, SEL, CGRect))objc_msgSend)(
            labelAllocated, S("initWithFrame:"), ballFrame);
        if (gBallLabel) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(
                gBallLabel, S("setTextAlignment:"), 1);
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(
                gBallLabel, S("setNumberOfLines:"), 1);
            ((void (*)(id, SEL, BOOL))objc_msgSend)(
                gBallLabel, S("setUserInteractionEnabled:"), NO);
            MsgVoidObj(gBallLabel, "setTextColor:",
                       MsgId((id)C("UIColor"), "whiteColor"));
            id font = ((id (*)(id, SEL, CGFloat))objc_msgSend)(
                (id)C("UIFont"), S("boldSystemFontOfSize:"), 24.0);
            MsgVoidObj(gBallLabel, "setFont:", font);
            ((void (*)(id, SEL, BOOL))objc_msgSend)(
                gBallLabel, S("setAdjustsFontSizeToFitWidth:"), YES);
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(
                gBallLabel, S("setMinimumScaleFactor:"), 0.4);
            MsgVoidObj(gBall, "addSubview:", gBallLabel);
        }

        id layer = MsgId(gBall, "layer");
        if (layer) {
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(
                layer, S("setCornerRadius:"), 34.0);
            ((void (*)(id, SEL, BOOL))objc_msgSend)(
                layer, S("setMasksToBounds:"), YES);
        }

        Class panClass = C("UIPanGestureRecognizer");
        if (panClass && gController) {
            id panAllocated = ((id (*)(id, SEL))objc_msgSend)(
                (id)panClass, S("alloc"));
            id pan = ((id (*)(id, SEL, id, SEL))objc_msgSend)(
                panAllocated, S("initWithTarget:action:"),
                gController, S("dsh_pan:"));
            if (pan) MsgVoidObj(gBall, "addGestureRecognizer:", pan);
        }
        Class ballTapClass = C("UITapGestureRecognizer");
        if (ballTapClass && gController) {
            id tapAllocated = ((id (*)(id, SEL))objc_msgSend)(
                (id)ballTapClass, S("alloc"));
            gBallTap = ((id (*)(id, SEL, id, SEL))objc_msgSend)(
                tapAllocated, S("initWithTarget:action:"),
                gController, S("dsh_toggle:"));
            if (gBallTap)
                MsgVoidObj(gBall, "addGestureRecognizer:", gBallTap);
        }

        CGRect fullFrame = {{0, 0}, {1, 1}};
        id fullAllocated = ((id (*)(id, SEL))objc_msgSend)((id)labelClass, S("alloc"));
        gFullLabel = ((id (*)(id, SEL, CGRect))objc_msgSend)(
            fullAllocated, S("initWithFrame:"), fullFrame);
        if (gFullLabel) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(
                gFullLabel, S("setTextAlignment:"), 1);
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(
                gFullLabel, S("setNumberOfLines:"), 1);
            ((void (*)(id, SEL, BOOL))objc_msgSend)(
                gFullLabel, S("setUserInteractionEnabled:"), YES);
            MsgVoidObj(gFullLabel, "setBackgroundColor:",
                       MsgId((id)C("UIColor"), "blackColor"));
            MsgVoidObj(gFullLabel, "setTextColor:",
                       MsgId((id)C("UIColor"), "lightGrayColor"));
            ((void (*)(id, SEL, BOOL))objc_msgSend)(
                gFullLabel, S("setAdjustsFontSizeToFitWidth:"), YES);
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(
                gFullLabel, S("setMinimumScaleFactor:"), 0.05);
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(
                gFullLabel, S("setAutoresizingMask:"), (NSUInteger)6);
            ((void (*)(id, SEL, BOOL))objc_msgSend)(
                gFullLabel, S("setHidden:"), YES);

            Class tapClass = C("UITapGestureRecognizer");
            if (tapClass && gController) {
                id tapAllocated = ((id (*)(id, SEL))objc_msgSend)(
                    (id)tapClass, S("alloc"));
                gFullTap = ((id (*)(id, SEL, id, SEL))objc_msgSend)(
                    tapAllocated, S("initWithTarget:action:"),
                    gController, S("dsh_toggle:"));
                if (gFullTap)
                    MsgVoidObj(gFullLabel, "addGestureRecognizer:", gFullTap);
            }
        }
    }

    id currentWindow = MsgId(gBall, "window");
    if (currentWindow != window) MsgVoidObj(window, "addSubview:", gBall);
    if (Responds(window, "bringSubviewToFront:"))
        MsgVoidObj(window, "bringSubviewToFront:", gBall);
    ApplyLayout(window);
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
    gCurrentSeconds = seconds;

    char text[32];
    if (seconds >= 0) snprintf(text, sizeof(text), "%d", seconds);
    else snprintf(text, sizeof(text), "-");
    id textString = NSStr(text);
    id color = LampColor(seconds >= 0 ? state : LampUnknown);

    MsgVoidObj(gBall, "setBackgroundColor:", color);
    if (gBallLabel && textString) MsgVoidObj(gBallLabel, "setText:", textString);

    if (gExpanded && gFullLabel) {
        id numberColor = color;
        if (seconds < 0)
            numberColor = MsgId((id)C("UIColor"), "lightGrayColor");
        MsgVoidObj(gFullLabel, "setTextColor:", numberColor);
        if (textString) MsgVoidObj(gFullLabel, "setText:", textString);
        id window = KeyWindow();
        if (window) {
            CGRect bounds = MsgRect(window, "bounds");
            CGFloat fontSize = bounds.size.height > 100
                ? bounds.size.height * 0.85 : 200.0;
            id font = ((id (*)(id, SEL, CGFloat))objc_msgSend)(
                (id)C("UIFont"), S("boldSystemFontOfSize:"), fontSize);
            MsgVoidObj(gFullLabel, "setFont:", font);
        }
    }
}

static void ScheduleTimer(void) {
    if (gTimer) return;
    Class timerClass = C("NSTimer");
    if (!timerClass || !gController) return;
    gTimer = ((id (*)(id, SEL, double, id, SEL, id, BOOL))objc_msgSend)(
        (id)timerClass,
        S("scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:"),
        1.0, gController, S("dsh_tick:"), 0, YES);
}

static void Tick(id self, SEL command, id timer) {
    (void)self;
    (void)command;
    (void)timer;
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
    class_addMethod(controllerClass, S("dsh_background:"), (IMP)EnterBackground, "v@:@");
    class_addMethod(controllerClass, S("dsh_foreground:"), (IMP)EnterForeground, "v@:@");
    class_addMethod(controllerClass, S("dsh_toggle:"), (IMP)ToggleExpanded, "v@:@");
    class_addMethod(controllerClass, S("dsh_pan:"), (IMP)HandlePan, "v@:@");
    gController = MsgId((id)controllerClass, "new");
    if (gController && Responds(gController, "performSelector:withObject:afterDelay:")) {
        ((void (*)(id, SEL, SEL, id, double))objc_msgSend)(
            gController, S("performSelector:withObject:afterDelay:"),
            S("dsh_start:"), 0, 0.5);
    }
}
