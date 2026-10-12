#define _POSIX_C_SOURCE 200809L

#include "SignalHistory.h"
#include <math.h>
#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Host-side regression tests for the persistent model. No UIKit or live map
 * connection is needed: all timestamps are explicit and deterministic. */
#define CHECK(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "%s:%d: %s failed\n", __func__, __LINE__, #condition); \
        return false; \
    } \
} while (0)

typedef struct {
    SHStore *store;
    char path[512];
} Fixture;

static bool fixture_open(Fixture *fixture) {
    memset(fixture, 0, sizeof(*fixture));
    snprintf(fixture->path, sizeof(fixture->path), "/tmp/amap-history-test-XXXXXX");
    int fd = mkstemp(fixture->path);
    if (fd < 0) return false;
    close(fd);
    fixture->store = SHOpen(fixture->path);
    return fixture->store != NULL;
}

static void fixture_close(Fixture *fixture) {
    if (fixture->store) SHClose(fixture->store);
    fixture->store = NULL;
    unlink(fixture->path);
    char auxiliary[sizeof(fixture->path) + 16];
    const char *suffixes[] = { "-wal", "-shm", "-journal" };
    for (size_t i = 0; i < sizeof(suffixes) / sizeof(suffixes[0]); i++) {
        snprintf(auxiliary, sizeof(auxiliary), "%s%s", fixture->path, suffixes[i]);
        unlink(auxiliary);
    }
}

static bool entry_for(SHStore *store, uint64_t id, const char *key, SHEntry *result) {
    size_t count = SHList(store, NULL, 0);
    if (!count) return false;
    SHEntry *entries = calloc(count, sizeof(*entries));
    if (!entries) return false;
    size_t total = SHList(store, entries, count);
    bool found = false;
    for (size_t i = 0; i < count && i < total; i++) {
        if (entries[i].signalId == id && strcmp(entries[i].approachKey, key) == 0) {
            *result = entries[i];
            found = true;
            break;
        }
    }
    free(entries);
    return found;
}

/* Counting all non-internal rows avoids depending on private table names. An
 * unchanged native snapshot must not inflate the persisted samples. */
static sqlite3_int64 persisted_row_count(const char *path) {
    sqlite3 *database = NULL;
    if (sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        sqlite3_close(database);
        return -1;
    }
    sqlite3_stmt *tables = NULL;
    const char *query = "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'";
    if (sqlite3_prepare_v2(database, query, -1, &tables, NULL) != SQLITE_OK) {
        sqlite3_close(database);
        return -1;
    }
    sqlite3_int64 total = 0;
    int status;
    while ((status = sqlite3_step(tables)) == SQLITE_ROW) {
        const char *name = (const char *)sqlite3_column_text(tables, 0);
        char *count_query = sqlite3_mprintf("SELECT COUNT(*) FROM \"%w\"", name);
        sqlite3_stmt *count = NULL;
        if (!count_query || sqlite3_prepare_v2(database, count_query, -1, &count, NULL) != SQLITE_OK ||
            sqlite3_step(count) != SQLITE_ROW) {
            sqlite3_free(count_query);
            sqlite3_finalize(count);
            total = -1;
            break;
        }
        total += sqlite3_column_int64(count, 0);
        sqlite3_free(count_query);
        sqlite3_finalize(count);
    }
    if (status != SQLITE_DONE && total >= 0) total = -1;
    sqlite3_finalize(tables);
    sqlite3_close(database);
    return total;
}

static sqlite3_int64 phase_row_count(const char *path) {
    sqlite3 *database = NULL;
    sqlite3_stmt *statement = NULL;
    sqlite3_int64 count = -1;
    if (sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK &&
        sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM phases", -1, &statement, NULL) == SQLITE_OK &&
        sqlite3_step(statement) == SQLITE_ROW) {
        count = sqlite3_column_int64(statement, 0);
    }
    sqlite3_finalize(statement);
    sqlite3_close(database);
    return count;
}

static const SHPhase matching_phases[] = {
    { 1, 1000, 1030 }, { 3, 1030, 1060 }, { 2, 1060, 1065 },
    { 1, 1065, 1095 }, { 3, 1095, 1125 }, { 2, 1125, 1130 },
    { 1, 1130, 1160 }
};

static bool prediction_is(SHStore *store, uint64_t id, const char *key,
                          double now, int color, double remaining) {
    SHPrediction prediction = {0};
    if (!SHPredict(store, id, key, now, &prediction)) return false;
    return prediction.available && prediction.color == color &&
        fabs(prediction.remaining - remaining) < 0.000001 &&
        fabs(prediction.phaseEndsAt - (now + remaining)) < 0.000001;
}

static bool prediction_missing(SHStore *store, uint64_t id, const char *key, double now) {
    SHPrediction prediction = { .available = true, .color = 3, .remaining = 99 };
    return !SHPredict(store, id, key, now, &prediction) && !prediction.available;
}

static bool test_identity_and_direction_blacklist(void) {
    Fixture fixture;
    CHECK(fixture_open(&fixture));
    SHIdentity north = { UINT64_MAX, "road:north", "人民路与建设路", "人民路北侧" };
    SHIdentity south = { UINT64_MAX, "road:south", "人民路与建设路", "人民路南侧" };
    CHECK(SHUpsertIdentity(fixture.store, &north));
    CHECK(SHUpsertIdentity(fixture.store, &south));
    CHECK(SHList(fixture.store, NULL, 0) == 2);
    SHEntry entry;
    CHECK(entry_for(fixture.store, UINT64_MAX, "road:north", &entry));
    CHECK(strcmp(entry.name, north.name) == 0);
    CHECK(strcmp(entry.approachName, north.approachName) == 0);
    CHECK(!entry.blacklisted);

    north.name = NULL;
    north.approachName = NULL;
    CHECK(SHUpsertIdentity(fixture.store, &north));
    CHECK(entry_for(fixture.store, UINT64_MAX, "road:north", &entry));
    CHECK(strcmp(entry.name, "人民路与建设路") == 0);
    north.name = "人民路口";
    CHECK(SHUpsertIdentity(fixture.store, &north));
    CHECK(entry_for(fixture.store, UINT64_MAX, "road:north", &entry));
    CHECK(strcmp(entry.name, "人民路口") == 0);
    north.name = "";
    CHECK(SHUpsertIdentity(fixture.store, &north));
    CHECK(entry_for(fixture.store, UINT64_MAX, "road:north", &entry));
    CHECK(entry.name[0] == '\0');

    SHIdentity invalid = { 5, NULL, "Unknown direction", NULL };
    CHECK(!SHUpsertIdentity(fixture.store, &invalid));
    invalid.approachKey = "";
    CHECK(!SHUpsertIdentity(fixture.store, &invalid));
    CHECK(SHList(fixture.store, NULL, 0) == 2);

    CHECK(SHSetBlacklisted(fixture.store, UINT64_MAX, "road:north", true));
    CHECK(SHIsBlacklisted(fixture.store, UINT64_MAX, "road:north"));
    CHECK(!SHIsBlacklisted(fixture.store, UINT64_MAX, "road:south"));
    SHClose(fixture.store);
    fixture.store = SHOpen(fixture.path);
    CHECK(fixture.store != NULL);
    CHECK(SHIsBlacklisted(fixture.store, UINT64_MAX, "road:north"));
    CHECK(!SHIsBlacklisted(fixture.store, UINT64_MAX, "road:south"));
    CHECK(entry_for(fixture.store, UINT64_MAX, "road:south", &entry));
    CHECK(strcmp(entry.name, "人民路与建设路") == 0);
    CHECK(SHSetBlacklisted(fixture.store, UINT64_MAX, "road:north", false));
    SHClose(fixture.store);
    fixture.store = SHOpen(fixture.path);
    CHECK(fixture.store != NULL);
    CHECK(!SHIsBlacklisted(fixture.store, UINT64_MAX, "road:north"));
    SHEntry only_one;
    CHECK(SHList(fixture.store, &only_one, 1) == 2);
    fixture_close(&fixture);
    return true;
}

static bool test_complete_cycle_boundaries_and_freshness(void) {
    Fixture fixture;
    CHECK(fixture_open(&fixture));
    SHIdentity identity = { UINT64_MAX, "road:east", "Station junction", "Station Road" };
    CHECK(SHRemember(fixture.store, &identity, matching_phases, 7, 1130));
    CHECK(prediction_is(fixture.store, UINT64_MAX, "road:east", 1130, 1, 30));
    CHECK(prediction_is(fixture.store, UINT64_MAX, "road:east", 1159, 1, 1));
    CHECK(prediction_is(fixture.store, UINT64_MAX, "road:east", 1160, 3, 30));
    CHECK(prediction_is(fixture.store, UINT64_MAX, "road:east", 1189, 3, 1));
    CHECK(prediction_is(fixture.store, UINT64_MAX, "road:east", 1190, 2, 5));
    CHECK(prediction_is(fixture.store, UINT64_MAX, "road:east", 1195, 1, 30));
    CHECK(prediction_is(fixture.store, UINT64_MAX, "road:east", 1260, 1, 30));
    CHECK(prediction_missing(fixture.store, UINT64_MAX, "road:west", 1140));
    CHECK(prediction_missing(fixture.store, UINT64_MAX - 1, "road:east", 1140));
    SHPrediction prediction;
    CHECK(SHPredict(fixture.store, UINT64_MAX, "road:east", 1140, &prediction));
    CHECK(prediction_missing(fixture.store, UINT64_MAX, "road:east", prediction.learnedAt - 0.001));
    CHECK(prediction_missing(fixture.store, UINT64_MAX, "road:east",
                             prediction.learnedAt + SH_PREDICTION_MAX_AGE_SECONDS + 1));
    CHECK(prediction_missing(fixture.store, UINT64_MAX, "road:east", NAN));
    SHEntry entry;
    CHECK(entry_for(fixture.store, UINT64_MAX, "road:east", &entry));
    CHECK(entry.hasPrediction);
    CHECK(fabs(entry.redSeconds - 30) < 0.000001);
    CHECK(fabs(entry.greenSeconds - 30) < 0.000001);
    CHECK(fabs(entry.yellowSeconds - 5) < 0.000001);

    /* A complete red/green-only native sequence is valid; a missing yellow
     * interval is only rejected when it actually leaves a gap. */
    SHIdentity opposite = { UINT64_MAX, "road:west", "Station junction", "West Road" };
    SHPhase opposite_phases[] = {
        { 1, 1000, 1020 }, { 3, 1020, 1060 },
        { 1, 1060, 1080 }, { 3, 1080, 1120 }, { 1, 1120, 1140 }
    };
    CHECK(SHRemember(fixture.store, &opposite, opposite_phases, 5, 1130));
    CHECK(prediction_is(fixture.store, UINT64_MAX, "road:west", 1160, 3, 20));
    CHECK(prediction_is(fixture.store, UINT64_MAX, "road:east", 1160, 3, 30));
    CHECK(entry_for(fixture.store, UINT64_MAX, "road:west", &entry));
    CHECK(fabs(entry.yellowSeconds) < 0.000001);

    sqlite3_int64 rows = persisted_row_count(fixture.path);
    CHECK(rows > 0);
    CHECK(SHRemember(fixture.store, &identity, matching_phases, 7, 1140));
    CHECK(SHRemember(fixture.store, &identity, matching_phases, 7, 1150));
    CHECK(persisted_row_count(fixture.path) == rows);
    SHClose(fixture.store);
    fixture.store = SHOpen(fixture.path);
    CHECK(fixture.store != NULL);
    CHECK(prediction_is(fixture.store, UINT64_MAX, "road:east", 1160, 3, 30));
    CHECK(SHPredict(fixture.store, UINT64_MAX, "road:east", 1160, &prediction));
    double previous_learned_at = prediction.learnedAt;
    double stale_received_at = 1160 + SH_PREDICTION_MAX_AGE_SECONDS + 1;
    CHECK(SHRemember(fixture.store, &identity, matching_phases, 7, stale_received_at));
    CHECK(prediction_missing(fixture.store, UINT64_MAX, "road:east", stale_received_at));
    CHECK(entry_for(fixture.store, UINT64_MAX, "road:east", &entry));
    CHECK(fabs(entry.learnedAt - previous_learned_at) < 0.000001);
    fixture_close(&fixture);
    return true;
}

static bool test_incomplete_and_changed_cycles(void) {
    Fixture fixture;
    CHECK(fixture_open(&fixture));
    SHIdentity one_cycle = { 10, "road:a", NULL, NULL };
    CHECK(SHRemember(fixture.store, &one_cycle, matching_phases, 3, 1065));
    CHECK(prediction_missing(fixture.store, 10, "road:a", 1070));

    SHIdentity with_gap = { 11, "road:a", NULL, NULL };
    SHPhase gap_phases[] = {
        { 1, 1000, 1030 }, { 3, 1031, 1060 }, { 2, 1060, 1065 },
        { 1, 1065, 1095 }, { 3, 1096, 1125 }, { 2, 1125, 1130 },
        { 1, 1130, 1160 }
    };
    CHECK(SHRemember(fixture.store, &with_gap, gap_phases, 7, 1130));
    CHECK(prediction_missing(fixture.store, 11, "road:a", 1140));

    SHIdentity missing_yellow = { 12, "road:a", NULL, NULL };
    SHPhase missing_phases[] = {
        { 1, 1000, 1030 }, { 3, 1030, 1060 },
        { 1, 1065, 1095 }, { 3, 1095, 1125 }, { 1, 1130, 1160 }
    };
    CHECK(SHRemember(fixture.store, &missing_yellow, missing_phases, 5, 1130));
    CHECK(prediction_missing(fixture.store, 12, "road:a", 1140));

    SHIdentity changed = { 13, "road:a", NULL, NULL };
    SHPhase changed_phases[] = {
        { 1, 1000, 1030 }, { 3, 1030, 1060 }, { 2, 1060, 1065 },
        { 1, 1065, 1100 }, { 3, 1100, 1130 }, { 2, 1130, 1135 },
        { 1, 1135, 1175 }
    };
    CHECK(SHRemember(fixture.store, &changed, changed_phases, 7, 1135));
    CHECK(prediction_missing(fixture.store, 13, "road:a", 1140));

    SHIdentity confirmed = { 14, "road:a", NULL, NULL };
    CHECK(SHRemember(fixture.store, &confirmed, matching_phases, 6, 1130));
    CHECK(prediction_is(fixture.store, 14, "road:a", 1130, 1, 30));
    fixture_close(&fixture);
    return true;
}

static bool test_native_drift_invalidates_model(void) {
    Fixture fixture;
    CHECK(fixture_open(&fixture));
    SHIdentity identity = { 20, "road:north", "Fixed route", NULL };
    CHECK(SHRemember(fixture.store, &identity, matching_phases, 7, 1130));
    CHECK(prediction_is(fixture.store, 20, "road:north", 1135, 1, 25));
    SHPhase drift = { 1, 1134, 1164 };
    CHECK(SHRemember(fixture.store, &identity, &drift, 1, 1135));
    CHECK(prediction_missing(fixture.store, 20, "road:north", 1135));
    SHEntry entry;
    CHECK(entry_for(fixture.store, 20, "road:north", &entry));
    CHECK(!entry.hasPrediction);
    /* A callback may include previously known phases and the newly shifted
     * phase together. The old stable block must not restore a drifted model. */
    SHPhase replay_with_drift[8];
    memcpy(replay_with_drift, matching_phases, sizeof(matching_phases));
    replay_with_drift[7] = drift;
    CHECK(SHRemember(fixture.store, &identity, replay_with_drift, 8, 1136));
    CHECK(prediction_missing(fixture.store, 20, "road:north", 1136));
    CHECK(entry_for(fixture.store, 20, "road:north", &entry));
    CHECK(!entry.hasPrediction);
    SHPhase shifted_cycles[] = {
        { 1, 1134, 1164 }, { 3, 1164, 1194 }, { 2, 1194, 1199 },
        { 1, 1199, 1229 }, { 3, 1229, 1259 }, { 2, 1259, 1264 },
        { 1, 1264, 1294 }
    };
    CHECK(SHRemember(fixture.store, &identity, shifted_cycles, 7, 1264));
    CHECK(prediction_is(fixture.store, 20, "road:north", 1264, 1, 30));
    CHECK(prediction_is(fixture.store, 20, "road:north", 1294, 3, 30));
    fixture_close(&fixture);
    return true;
}

static bool observe_transition(SHStore *store, const SHIdentity *identity,
                               int old_color, double at, int new_color, double next_end) {
    return SHObserve(store, identity, old_color, at, at - 1) &&
           SHObserve(store, identity, new_color, next_end, at);
}

static bool test_observation_learns_only_complete_phases(void) {
    Fixture fixture;
    CHECK(fixture_open(&fixture));
    SHIdentity identity = { 30, "road:north", "Observed junction", NULL };
    CHECK(SHObserve(fixture.store, &identity, 1, 1030, 1005));
    CHECK(prediction_missing(fixture.store, 30, "road:north", 1005));
    CHECK(observe_transition(fixture.store, &identity, 1, 1030, 3, 1060));
    CHECK(phase_row_count(fixture.path) == 0);
    CHECK(observe_transition(fixture.store, &identity, 3, 1060, 2, 1065));
    CHECK(phase_row_count(fixture.path) == 1);
    CHECK(observe_transition(fixture.store, &identity, 2, 1065, 1, 1095));
    CHECK(observe_transition(fixture.store, &identity, 1, 1095, 3, 1125));
    CHECK(observe_transition(fixture.store, &identity, 3, 1125, 2, 1130));
    CHECK(prediction_missing(fixture.store, 30, "road:north", 1125));
    CHECK(observe_transition(fixture.store, &identity, 2, 1130, 1, 1160));
    CHECK(observe_transition(fixture.store, &identity, 1, 1160, 3, 1190));
    CHECK(observe_transition(fixture.store, &identity, 3, 1190, 2, 1195));
    CHECK(prediction_is(fixture.store, 30, "road:north", 1190, 2, 5));
    SHEntry entry;
    CHECK(entry_for(fixture.store, 30, "road:north", &entry));
    CHECK(entry.hasPrediction);
    CHECK(fabs(entry.redSeconds - 30) < 0.000001);
    CHECK(fabs(entry.greenSeconds - 30) < 0.000001);
    CHECK(fabs(entry.yellowSeconds - 5) < 0.000001);
    fixture_close(&fixture);
    return true;
}

static bool test_unobserved_transition_does_not_complete_phase(void) {
    Fixture fixture;
    CHECK(fixture_open(&fixture));
    SHIdentity identity = { 31, "road:south", NULL, NULL };
    CHECK(SHObserve(fixture.store, &identity, 1, 1030, 1005));
    CHECK(observe_transition(fixture.store, &identity, 1, 1030, 3, 1060));
    /* No observation near the end of green: this phase is incomplete. */
    CHECK(SHObserve(fixture.store, &identity, 2, 1065, 1060));
    CHECK(phase_row_count(fixture.path) == 0);
    CHECK(observe_transition(fixture.store, &identity, 2, 1065, 1, 1095));
    CHECK(observe_transition(fixture.store, &identity, 1, 1095, 3, 1125));
    CHECK(observe_transition(fixture.store, &identity, 3, 1125, 2, 1130));
    CHECK(observe_transition(fixture.store, &identity, 2, 1130, 1, 1160));
    CHECK(observe_transition(fixture.store, &identity, 1, 1160, 3, 1190));
    CHECK(prediction_missing(fixture.store, 31, "road:south", 1160));
    fixture_close(&fixture);
    return true;
}

static bool test_mixed_snapshot_cannot_hide_changed_future_cycle(void) {
    Fixture fixture;
    CHECK(fixture_open(&fixture));
    SHIdentity identity = { 40, "road:east", "Changing junction", NULL };
    SHPhase mixed_phases[] = {
        { 1, 1000, 1030 }, { 3, 1030, 1060 }, { 2, 1060, 1065 },
        { 1, 1065, 1095 }, { 3, 1095, 1125 }, { 2, 1125, 1130 },
        { 1, 1130, 1160 }, { 3, 1160, 1195 }, { 2, 1195, 1200 }
    };
    /* The current red still agrees with the old schedule, but the complete
     * native snapshot already proves that its following green changed. */
    CHECK(SHRemember(fixture.store, &identity, mixed_phases, 9, 1140));
    CHECK(SHObserve(fixture.store, &identity, 1, 1160, 1140));
    CHECK(prediction_missing(fixture.store, 40, "road:east", 1160));
    CHECK(SHRemember(fixture.store, &identity, mixed_phases, 9, 1141));
    CHECK(prediction_missing(fixture.store, 40, "road:east", 1160));

    SHPhase new_cycles[] = {
        { 3, 1160, 1195 }, { 2, 1195, 1200 }, { 1, 1200, 1230 },
        { 3, 1230, 1265 }, { 2, 1265, 1270 }, { 1, 1270, 1300 }
    };
    CHECK(SHRemember(fixture.store, &identity, new_cycles, 6, 1300));
    CHECK(prediction_is(fixture.store, 40, "road:east", 1300, 3, 35));
    /* Receiving historical records again must preserve the newly learned
     * cycle rather than selecting their older, shorter green phase. */
    CHECK(SHRemember(fixture.store, &identity, mixed_phases, 9, 1301));
    CHECK(prediction_is(fixture.store, 40, "road:east", 1301, 3, 34));
    SHEntry entry;
    CHECK(entry_for(fixture.store, 40, "road:east", &entry));
    CHECK(fabs(entry.greenSeconds - 35) < 0.000001);

    /* The first callback can already contain the old history and two complete
     * new cycles. Replaying that same history must keep the newest model. */
    SHIdentity updated = { 40, "road:fully-updated", "Changing junction", NULL };
    SHPhase full_updated_history[] = {
        { 1, 1000, 1030 }, { 3, 1030, 1060 }, { 2, 1060, 1065 },
        { 1, 1065, 1095 }, { 3, 1095, 1125 }, { 2, 1125, 1130 },
        { 1, 1130, 1160 },
        { 3, 1160, 1195 }, { 2, 1195, 1200 }, { 1, 1200, 1230 },
        { 3, 1230, 1265 }, { 2, 1265, 1270 }, { 1, 1270, 1300 }
    };
    CHECK(SHRemember(fixture.store, &updated, full_updated_history, 13, 1300));
    CHECK(prediction_is(fixture.store, 40, "road:fully-updated", 1300, 3, 35));
    CHECK(entry_for(fixture.store, 40, "road:fully-updated", &entry));
    double learned_at = entry.learnedAt;
    CHECK(SHRemember(fixture.store, &updated, full_updated_history, 13, 1301));
    CHECK(prediction_is(fixture.store, 40, "road:fully-updated", 1301, 3, 34));
    CHECK(entry_for(fixture.store, 40, "road:fully-updated", &entry));
    CHECK(fabs(entry.learnedAt - learned_at) < 0.000001);
    fixture_close(&fixture);
    return true;
}

int main(void) {
    struct { const char *name; bool (*run)(void); } tests[] = {
        { "identity, uint64 ID, directions and persistent blacklist", test_identity_and_direction_blacklist },
        { "complete cycles, boundaries, expiry and snapshot deduplication", test_complete_cycle_boundaries_and_freshness },
        { "incomplete, missing, gapped and changed cycles", test_incomplete_and_changed_cycles },
        { "native phase drift invalidates prediction", test_native_drift_invalidates_model },
        { "transition observations learn complete phases", test_observation_learns_only_complete_phases },
        { "missed transition does not invent a complete phase", test_unobserved_transition_does_not_complete_phase },
        { "mixed snapshots cannot hide changed future cycles", test_mixed_snapshot_cannot_hide_changed_future_cycle }
    };
    size_t failures = 0;
    size_t count = sizeof(tests) / sizeof(tests[0]);
    for (size_t i = 0; i < count; i++) {
        bool passed = tests[i].run();
        if (!passed) failures++;
        printf("%s %s\n", passed ? "PASS" : "FAIL", tests[i].name);
    }
    printf("SignalHistory: %zu/%zu test groups passed\n", count - failures, count);
    return failures ? 1 : 0;
}
