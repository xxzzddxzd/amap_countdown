#include "SignalRoute.h"

#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "%s:%d: %s failed\n", __func__, __LINE__, #condition); \
        return false; \
    } \
} while (0)

static SRSignal signal_at(uint64_t id, int offset, double distance,
                          double capturedAt, int color, double endsAt) {
    SRSignal signal = {
        .id = id, .targetOffset = offset, .distanceMeters = distance,
        .source = 3, .capturedAt = capturedAt
    };
    if (color) {
        signal.phaseCount = 1;
        signal.phases[0] = (SHPhase){ color, capturedAt - 10, endsAt };
    }
    return signal;
}

static bool visible_is(SRRoute *route, unsigned position, double now,
                        uint64_t id, int offset, int color, int seconds) {
    SRDisplay display;
    return SRGetVisible(route, position, now, &display) && display.id == id &&
           display.targetOffset == offset && display.color == color &&
           display.seconds == seconds;
}

static bool test_sorting_missing_native_and_passed(void) {
    SRRoute *route = SRCreate(NULL);
    CHECK(route);
    SRSignal signals[] = {
        signal_at(33, 700, 300, 1000, 3, 1040),
        signal_at(11, 900, 100, 1000, 0, 0),
        signal_at(22, 800, 200, 1000, 1, 1030),
        signal_at(44, 1100, -100, 1000, 1, 1030),
        signal_at(55, 1200, NAN, 1000, 1, 1030)
    };
    CHECK(SRUpdate(route, signals, 5, 1000));
    CHECK(SRVisibleCount(route) == 3);
    CHECK(visible_is(route, 0, 1000, 11, 900, 0, -1));
    CHECK(visible_is(route, 1, 1000, 22, 800, 1, 30));
    CHECK(visible_is(route, 2, 1000, 33, 700, 3, 40));
    SRDisplay display;
    CHECK(SRGetVisible(route, 0, 1000, &display) && display.isNearest);
    CHECK(SRGetVisible(route, 1, 1000, &display) && !display.isNearest);
    CHECK(!SRGetVisible(route, 3, 1000, &display));
    CHECK(display.color == 0 && display.seconds == -1);
    CHECK(!SRGetVisible(route, UINT_MAX, 1000, &display));
    CHECK(!SRUpdate(route, NULL, 1, 1000));
    CHECK(!SRUpdate(route, signals, 5, NAN));
    CHECK(SRVisibleCount(route) == 3);
    SRDestroy(route);
    return true;
}

static bool test_swipe_selection_survives_updates(void) {
    SRRoute *route = SRCreate(NULL);
    CHECK(route);
    SRSignal signals[] = {
        signal_at(11, 900, 100, 1000, 1, 1030),
        signal_at(22, 800, 200, 1000, 3, 1040),
        signal_at(33, 700, 300, 1000, 1, 1050)
    };
    CHECK(SRUpdate(route, signals, 3, 1000));
    CHECK(!SRMove(route, -1));
    CHECK(SRMove(route, 1));
    CHECK(visible_is(route, 0, 1000, 22, 800, 3, 40));
    CHECK(visible_is(route, 1, 1000, 33, 700, 1, 50));
    CHECK(!SRMove(route, 2));
    CHECK(visible_is(route, 0, 1000, 22, 800, 3, 40));
    for (unsigned index = 0; index < 3; index++)
        signals[index].distanceMeters -= 80;
    CHECK(SRUpdate(route, signals, 3, 1001));
    CHECK(visible_is(route, 0, 1001, 22, 800, 3, 39));
    CHECK(SRMove(route, -1));
    CHECK(visible_is(route, 0, 1001, 11, 900, 1, 29));
    CHECK(SRMove(route, 1));
    signals[0].distanceMeters = -1;
    CHECK(SRUpdate(route, signals, 3, 1001));
    CHECK(visible_is(route, 0, 1001, 22, 800, 3, 39));
    CHECK(!SRMove(route, -1));
    signals[1].distanceMeters = -1;
    CHECK(SRUpdate(route, signals, 3, 1002));
    CHECK(visible_is(route, 0, 1002, 33, 700, 1, 48));
    CHECK(!SRMove(route, 1));
    CHECK(!SRMove(route, INT_MIN));
    CHECK(!SRBind(route, 22, 800, "manual:A Road", "A Road", "A junction", 1002));
    SRDestroy(route);
    return true;
}

static bool test_removed_selection_returns_to_nearest(void) {
    SRRoute *route = SRCreate(NULL);
    CHECK(route);
    SRSignal signals[] = {
        signal_at(11, 900, 100, 1000, 1, 1030),
        signal_at(22, 800, 200, 1000, 3, 1040),
        signal_at(33, 700, 300, 1000, 1, 1050)
    };
    CHECK(SRUpdate(route, signals, 3, 1000));
    CHECK(SRMove(route, 1));
    signals[1].distanceMeters = -1;
    CHECK(SRUpdate(route, signals, 3, 1000));
    CHECK(visible_is(route, 0, 1000, 11, 900, 1, 30));
    SRDestroy(route);
    return true;
}

static bool test_direction_blacklist_and_occurrence_isolation(void) {
    SHStore *store = SHOpen(":memory:");
    CHECK(store);
    SRRoute *route = SRCreate(store);
    CHECK(route);
    SRSignal signals[] = {
        signal_at(77, 900, 100, 1000, 1, 1030),
        signal_at(77, 700, 300, 1000, 3, 1040),
        signal_at(88, 600, 400, 1000, 1, 1050)
    };
    CHECK(SRUpdate(route, signals, 3, 1000));
    CHECK(SRBind(route, 77, 900, "road:north", "North Road", "Station", 1000));
    CHECK(SRBind(route, 77, 700, "road:south", "South Road", "Station", 1000));
    SRDisplay display;
    CHECK(SRGetVisible(route, 0, 1000, &display));
    CHECK(display.bound && strcmp(display.approachKey, "road:north") == 0);
    CHECK(SRGetVisible(route, 1, 1000, &display));
    CHECK(display.bound && strcmp(display.approachKey, "road:south") == 0);
    CHECK(SHList(store, NULL, 0) == 2);
    CHECK(SHSetBlacklisted(store, 77, "road:north", true));
    SRRefresh(route, 1000);
    CHECK(SRVisibleCount(route) == 2);
    CHECK(visible_is(route, 0, 1000, 77, 700, 3, 40));
    CHECK(visible_is(route, 1, 1000, 88, 600, 1, 50));
    CHECK(!SRMove(route, -1));
    CHECK(SRMove(route, 1));
    CHECK(SRMove(route, -1));
    CHECK(visible_is(route, 0, 1000, 77, 700, 3, 40));
    CHECK(SHSetBlacklisted(store, 77, "road:south", true));
    CHECK(visible_is(route, 0, 1000, 88, 600, 1, 50));
    CHECK(SRBind(route, 88, 600, "road:west", "West Road", "Park", 1000));
    CHECK(SHSetBlacklisted(store, 88, "road:west", true));
    CHECK(SRVisibleCount(route) == 0);
    CHECK(!SRGetVisible(route, 0, 1000, &display));
    CHECK(SHSetBlacklisted(store, 77, "road:north", false));
    CHECK(visible_is(route, 0, 1000, 77, 900, 1, 30));
    SRDestroy(route);
    SHClose(store);
    return true;
}

static const SHPhase matchingPhases[] = {
    { 1, 1000, 1030 }, { 3, 1030, 1060 }, { 2, 1060, 1065 },
    { 1, 1065, 1095 }, { 3, 1095, 1125 }, { 2, 1125, 1130 },
    { 1, 1130, 1160 }
};

static bool test_prediction_requires_explicit_direction(void) {
    SHStore *store = SHOpen(":memory:");
    CHECK(store);
    SHIdentity north = { 77, "road:north", "Station", "North Road" };
    SHIdentity south = { 77, "road:south", "Station", "South Road" };
    CHECK(SHRemember(store, &north, matchingPhases, 7, 1130));
    SHPhase shifted[7];
    for (unsigned index = 0; index < 7; index++) {
        shifted[index] = matchingPhases[index];
        shifted[index].startsAt += 15;
        shifted[index].endsAt += 15;
    }
    CHECK(SHRemember(store, &south, shifted, 7, 1145));
    SRRoute *route = SRCreate(store);
    CHECK(route);
    SRSignal signal = signal_at(77, 900, 100, 1160, 0, 0);
    CHECK(SRUpdate(route, &signal, 1, 1160));
    CHECK(visible_is(route, 0, 1160, 77, 900, 0, -1));
    SRDisplay display;
    CHECK(SRGetVisible(route, 0, 1160, &display) && !display.bound);
    CHECK(SRBind(route, 77, 900, "road:north", "North Road", "Station", 1160));
    CHECK(visible_is(route, 0, 1160, 77, 900, 3, 30));
    CHECK(SRGetVisible(route, 0, 1160, &display) && display.predicted);
    CHECK(SRBind(route, 77, 900, "road:south", "South Road", "Station", 1160));
    CHECK(visible_is(route, 0, 1160, 77, 900, 1, 15));
    CHECK(SRGetVisible(route, 0, 1160, &display) && display.predicted);
    /* A new route occurrence of the same ID does not inherit its direction. */
    signal.targetOffset = 700;
    CHECK(SRUpdate(route, &signal, 1, 1160));
    CHECK(SRGetVisible(route, 0, 1160, &display));
    CHECK(!display.bound && !display.predicted && display.color == 0);
    SRDestroy(route);
    SHClose(store);
    return true;
}

static bool test_native_priority_and_stale_prediction(void) {
    SHStore *store = SHOpen(":memory:");
    CHECK(store);
    SHIdentity identity = { 77, "road:north", "Station", "North Road" };
    CHECK(SHRemember(store, &identity, matchingPhases, 7, 1130));
    SRRoute *route = SRCreate(store);
    CHECK(route);
    SRSignal signal = signal_at(77, 900, 100, 1160, 3, 1190);
    signal.phases[0].startsAt = 1160;
    CHECK(SRUpdate(route, &signal, 1, 1160));
    CHECK(SRBind(route, 77, 900, "road:north", "North Road", "Station", 1160));
    SRDisplay display;
    CHECK(SRGetVisible(route, 0, 1160, &display));
    CHECK(display.color == 3 && display.seconds == 30 && !display.predicted);
    CHECK(SRGetVisible(route, 0, 1162.5, &display));
    CHECK(display.color == 3 && display.seconds == 28 && !display.predicted);
    CHECK(SRGetVisible(route, 0, 1162.6, &display));
    CHECK(display.color == 3 && display.seconds == 28 && display.predicted);
    CHECK(SRGetVisible(route, 0, 1190, &display));
    CHECK(display.color == 2 && display.seconds == 5 && display.predicted);
    CHECK(SRGetVisible(route, 0, 1130 + SH_PREDICTION_MAX_AGE_SECONDS + 100,
                       &display));
    CHECK(display.color == 0 && display.seconds == -1 && !display.predicted);
    SRDestroy(route);
    SHClose(store);
    return true;
}

static bool test_unbound_or_incomplete_history_stays_unknown(void) {
    SHStore *store = SHOpen(":memory:");
    CHECK(store);
    SHIdentity identity = { 77, "road:north", "Station", "North Road" };
    CHECK(SHRemember(store, &identity, matchingPhases, 3, 1065));
    CHECK(SHSetBlacklisted(store, 77, "road:north", true));
    SRRoute *route = SRCreate(store);
    CHECK(route);
    SRSignal signal = signal_at(77, 900, 100, 1070, 0, 0);
    CHECK(SRUpdate(route, &signal, 1, 1070));
    /* Even a sole historical direction cannot be automatically selected. */
    CHECK(visible_is(route, 0, 1070, 77, 900, 0, -1));
    CHECK(SRVisibleCount(route) == 1);
    CHECK(SHSetBlacklisted(store, 77, "road:north", false));
    CHECK(SRBind(route, 77, 900, "road:north", "North Road", "Station", 1070));
    CHECK(visible_is(route, 0, 1070, 77, 900, 0, -1));
    SRDestroy(route);
    SHClose(store);
    return true;
}

static bool test_ambiguity_rejects_binding_and_prediction(void) {
    SHStore *store = SHOpen(":memory:");
    CHECK(store);
    SHIdentity identity = { 77, "road:north", "Station", "North Road" };
    CHECK(SHRemember(store, &identity, matchingPhases, 7, 1130));
    SRRoute *route = SRCreate(store);
    CHECK(route);
    SRSignal signals[] = {
        signal_at(77, 900, 100, 1160, 3, 1190),
        signal_at(88, 800, 200, 1160, 1, 1180)
    };
    signals[0].phases[0].startsAt = 1160;
    CHECK(SRUpdate(route, signals, 2, 1160));
    CHECK(SRBind(route, 77, 900, "road:north", "North Road", "Station", 1160));
    signals[1].distanceMeters = 100;
    CHECK(SRUpdate(route, signals, 2, 1160));
    SRDisplay display;
    CHECK(SRGetVisible(route, 0, 1160, &display));
    CHECK(display.ambiguous && !display.bound && !display.predicted);
    CHECK(display.color == 0 && display.seconds == -1);
    CHECK(SRGetVisible(route, 1, 1160, &display));
    CHECK(display.ambiguous && display.color == 0 && display.seconds == -1);
    CHECK(!SRBind(route, 77, 900, "road:north", "North Road", "Station", 1160));
    signals[1].id = 77;
    signals[1].targetOffset = 900;
    signals[1].distanceMeters = 200;
    CHECK(SRUpdate(route, signals, 2, 1160));
    CHECK(SRGetVisible(route, 0, 1160, &display) && display.ambiguous);
    CHECK(display.color == 0 && display.seconds == -1);
    CHECK(SRGetVisible(route, 1, 1160, &display) && display.ambiguous);
    CHECK(display.color == 0 && display.seconds == -1);
    CHECK(!SRBind(route, 77, 900, "road:north", "North Road", "Station", 1160));
    SRDestroy(route);
    SHClose(store);
    return true;
}

static bool test_unknown_id_placeholder_and_invalid_phases(void) {
    SRRoute *route = SRCreate(NULL);
    CHECK(route);
    SRSignal signals[] = {
        signal_at(0, 900, 100, 1000, 0, 0),
        signal_at(88, 800, 200, 1000, 1, 1030)
    };
    CHECK(SRUpdate(route, signals, 2, 1000));
    CHECK(visible_is(route, 0, 1000, 0, 900, 0, -1));
    SRDisplay display;
    CHECK(SRGetVisible(route, 0, 1000, &display) && display.ambiguous);
    CHECK(!SRBind(route, 0, 900, "road:A", "A", "Junction", 1000));
    CHECK(visible_is(route, 1, 1000, 88, 800, 1, 30));
    CHECK(visible_is(route, 1, 1002.5, 88, 800, 1, 28));
    CHECK(visible_is(route, 1, 1002.6, 88, 800, 0, -1));
    signals[1].capturedAt = 1001;
    CHECK(SRUpdate(route, signals, 2, 1000));
    CHECK(visible_is(route, 1, 1000, 88, 800, 0, -1));
    signals[1].capturedAt = 1000;
    signals[1].phaseCount = 2;
    signals[1].phases[1] = (SHPhase){ 3, 990, 1030 };
    CHECK(SRUpdate(route, signals, 2, 1000));
    CHECK(visible_is(route, 1, 1000, 88, 800, 0, -1));
    signals[1].phaseCount = SR_MAX_PHASES + 1;
    CHECK(SRUpdate(route, signals, 2, 1000));
    CHECK(visible_is(route, 1, 1000, 88, 800, 0, -1));
    SRDestroy(route);
    return true;
}

static bool test_empty_route_and_explicit_reset_clear_bindings(void) {
    SHStore *store = SHOpen(":memory:");
    CHECK(store);
    SRRoute *route = SRCreate(store);
    CHECK(route);
    SRSignal signal = signal_at(77, 900, 100, 1000, 1, 1030);
    CHECK(SRUpdate(route, &signal, 1, 1000));
    CHECK(SRBind(route, 77, 900, "road:A", "A Road", "Station", 1000));
    CHECK(SHSetBlacklisted(store, 77, "road:A", true));
    CHECK(SRVisibleCount(route) == 0);
    CHECK(SRUpdate(route, NULL, 0, 1000));
    CHECK(SRUpdate(route, &signal, 1, 1000));
    SRDisplay display;
    CHECK(SRGetVisible(route, 0, 1000, &display));
    CHECK(!display.bound && !display.predicted && display.color == 1);
    CHECK(SRBind(route, 77, 900, "road:B", "B Road", "Station", 1000));
    CHECK(SRGetVisible(route, 0, 1000, &display) && display.bound);
    SRReset(route);
    CHECK(SRVisibleCount(route) == 0);
    CHECK(SRUpdate(route, &signal, 1, 1000));
    CHECK(SRGetVisible(route, 0, 1000, &display));
    CHECK(!display.bound && display.approachKey[0] == '\0');
    CHECK(SHList(store, NULL, 0) == 2);
    SRDestroy(route);
    SHClose(store);
    return true;
}

static bool test_manual_metadata_and_key_validation(void) {
    SRRoute *route = SRCreate(NULL);
    CHECK(route);
    SRSignal signal = signal_at(77, 900, 100, 1000, 1, 1030);
    CHECK(SRUpdate(route, &signal, 1, 1000));
    CHECK(!SRBind(route, 77, 900, NULL, "A", "Junction", 1000));
    CHECK(!SRBind(route, 77, 900, "   \t", "A", "Junction", 1000));
    char oversized[SR_APPROACH_CAPACITY + 1];
    memset(oversized, 'x', sizeof(oversized) - 1);
    oversized[sizeof(oversized) - 1] = '\0';
    CHECK(!SRBind(route, 77, 900, oversized, "A", "Junction", 1000));
    CHECK(SRBind(route, 77, 900, "manual:A Road", "A Road", "Junction", 1000));
    SRDisplay display;
    CHECK(SRGetVisible(route, 0, 1000, &display));
    CHECK(display.bound && strcmp(display.name, "Junction") == 0);
    CHECK(strcmp(display.approachName, "A Road") == 0);
    CHECK(SRBind(route, 77, 900, "manual:A Road", NULL, "New junction", 1000));
    CHECK(SRGetVisible(route, 0, 1000, &display));
    CHECK(strcmp(display.name, "New junction") == 0);
    CHECK(strcmp(display.approachName, "A Road") == 0);
    SRDestroy(route);
    return true;
}

static bool test_binding_requires_a_fresh_route_capture(void) {
    SRRoute *route = SRCreate(NULL);
    CHECK(route);
    SRSignal signal = signal_at(77, 900, 100, 1000, 1, 1030);
    CHECK(SRUpdate(route, &signal, 1, 1000));
    CHECK(!SRBind(route, 77, 900, "road:stale", "Old Road", "Station", 1003));
    SRDisplay display;
    CHECK(SRGetVisible(route, 0, 1003, &display) && !display.bound);
    CHECK(SRBind(route, 77, 900, "road:boundary", "Boundary Road", "Station", 1002.5));
    CHECK(!SRBind(route, 77, 900, "road:stale", "Old Road", "Station", 1002.5001));
    CHECK(SRGetVisible(route, 0, 1002.5, &display));
    CHECK(display.bound && strcmp(display.approachKey, "road:boundary") == 0);
    signal.capturedAt = 1001;
    CHECK(SRUpdate(route, &signal, 1, 1000));
    CHECK(!SRBind(route, 77, 900, "road:future", "Future Road", "Station", 1000));
    SRDestroy(route);
    return true;
}

static bool test_bad_state_retains_identity_blacklist_without_prediction(void) {
    SHStore *store = SHOpen(":memory:");
    CHECK(store);
    SHIdentity identity = { 77, "road:north", "Station", "North Road" };
    CHECK(SHRemember(store, &identity, matchingPhases, 7, 1130));
    SRRoute *route = SRCreate(store);
    CHECK(route);
    SRSignal signals[] = {
        signal_at(77, 900, 100, 1160, 3, 1190),
        signal_at(88, 800, 200, 1160, 1, 1180)
    };
    signals[0].phases[0].startsAt = 1160;
    CHECK(SRUpdate(route, signals, 2, 1160));
    CHECK(SRBind(route, 77, 900, "road:north", "North Road", "Station", 1160));
    CHECK(SHSetBlacklisted(store, 77, "road:north", true));
    CHECK(visible_is(route, 0, 1160, 88, 800, 1, 20));
    SHEntry before;
    CHECK(SHList(store, &before, 1) == 1);
    /* Bad or ambiguous native phase data must not discard a known identity.
     * A deliberately conflicting but structurally valid phase also proves
     * it cannot reach learning or invalidate the existing history model. */
    signals[0].dataUnavailable = true;
    signals[0].capturedAt = 1161;
    signals[0].phases[0] = (SHPhase){ 1, 1160, 1190 };
    CHECK(SRUpdate(route, signals, 2, 1161));
    CHECK(SRVisibleCount(route) == 1);
    CHECK(visible_is(route, 0, 1161, 88, 800, 1, 19));
    SHEntry after;
    CHECK(SHList(store, &after, 1) == 1);
    CHECK(after.lastObservedAt == before.lastObservedAt);
    CHECK(after.learnedAt == before.learnedAt && after.hasPrediction);
    SHPrediction prediction;
    CHECK(SHPredict(store, 77, "road:north", 1161, &prediction));
    CHECK(prediction.color == 3);
    CHECK(SHSetBlacklisted(store, 77, "road:north", false));
    CHECK(SRVisibleCount(route) == 2);
    SRDisplay display;
    CHECK(SRGetVisible(route, 0, 1161, &display));
    CHECK(display.bound && !display.ambiguous);
    CHECK(strcmp(display.approachKey, "road:north") == 0);
    CHECK(display.color == 0 && display.seconds == -1 && !display.predicted);
    signals[0].dataUnavailable = false;
    signals[0].capturedAt = 1162;
    signals[0].phases[0] = (SHPhase){ 3, 1160, 1190 };
    CHECK(SRUpdate(route, signals, 2, 1162));
    CHECK(SRGetVisible(route, 0, 1162, &display));
    CHECK(display.bound && display.color == 3 && display.seconds == 28);
    CHECK(!display.predicted);
    /* An absent timetable is different from rejected native data and can
     * fall back to a valid, explicitly bound historical direction. */
    signals[0].phaseCount = 0;
    signals[0].capturedAt = 1163;
    CHECK(SRUpdate(route, signals, 2, 1163));
    CHECK(SRGetVisible(route, 0, 1163, &display));
    CHECK(display.bound && display.predicted && display.color == 3);
    CHECK(display.seconds == 27);
    SRDestroy(route);
    SHClose(store);
    return true;
}

static bool test_new_nearest_is_selected_unless_manually_browsing(void) {
    SRRoute *route = SRCreate(NULL);
    CHECK(route);
    SRSignal signals[] = {
        signal_at(11, 900, 100, 1000, 1, 1030),
        signal_at(22, 800, 200, 1000, 3, 1040),
        signal_at(5, 950, 50, 1000, 0, 0)
    };
    CHECK(SRUpdate(route, signals, 2, 1000));
    CHECK(visible_is(route, 0, 1000, 11, 900, 1, 30));
    CHECK(SRUpdate(route, signals, 3, 1000));
    CHECK(visible_is(route, 0, 1000, 5, 950, 0, -1));
    CHECK(SRMove(route, 2));
    CHECK(visible_is(route, 0, 1000, 22, 800, 3, 40));
    SRSignal evenNearer = signal_at(1, 975, 20, 1000, 1, 1020);
    SRSignal expanded[] = { signals[0], signals[1], signals[2], evenNearer };
    CHECK(SRUpdate(route, expanded, 4, 1000));
    CHECK(visible_is(route, 0, 1000, 22, 800, 3, 40));
    /* Removing the manually selected occurrence restores automatic nearest. */
    expanded[1].distanceMeters = -1;
    CHECK(SRUpdate(route, expanded, 4, 1000));
    CHECK(visible_is(route, 0, 1000, 1, 975, 1, 20));
    /* A further newly captured nearer occurrence then updates the main pane. */
    expanded[1] = signal_at(2, 990, 10, 1000, 3, 1025);
    CHECK(SRUpdate(route, expanded, 4, 1000));
    CHECK(visible_is(route, 0, 1000, 2, 990, 3, 25));
    SRDestroy(route);
    return true;
}

int main(void) {
    bool (*tests[])(void) = {
        test_sorting_missing_native_and_passed,
        test_swipe_selection_survives_updates,
        test_removed_selection_returns_to_nearest,
        test_direction_blacklist_and_occurrence_isolation,
        test_prediction_requires_explicit_direction,
        test_native_priority_and_stale_prediction,
        test_unbound_or_incomplete_history_stays_unknown,
        test_ambiguity_rejects_binding_and_prediction,
        test_unknown_id_placeholder_and_invalid_phases,
        test_empty_route_and_explicit_reset_clear_bindings,
        test_manual_metadata_and_key_validation,
        test_binding_requires_a_fresh_route_capture,
        test_bad_state_retains_identity_blacklist_without_prediction,
        test_new_nearest_is_selected_unless_manually_browsing
    };
    for (size_t index = 0; index < sizeof(tests) / sizeof(tests[0]); index++) {
        if (!tests[index]()) return EXIT_FAILURE;
    }
    printf("route tests passed (%zu)\n", sizeof(tests) / sizeof(tests[0]));
    return EXIT_SUCCESS;
}
