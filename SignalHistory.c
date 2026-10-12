#include "SignalHistory.h"

#include <inttypes.h>
#include <math.h>
#include <pthread.h>
#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SH_SCHEMA_VERSION 1
#define SH_MAX_SAMPLES 256
#define SH_MAX_MODEL_PHASES 16
#define SH_TIME_EPSILON 0.001
#define SH_STABILITY_TOLERANCE 1.0
#define SH_MAX_PHASE_SECONDS 600.0
#define SH_MAX_PERIOD_SECONDS 1800.0
#define SH_TRANSITION_GAP_SECONDS 5.0

struct SHStore {
    sqlite3 *db;
    pthread_mutex_t mutex;
};

typedef struct {
    bool valid;
    double anchor;
    double period;
    double learnedAt;
    double learningSince;
    SHPhase phases[SH_MAX_MODEL_PHASES]; /* relative to anchor */
    size_t count;
} SHModel;

static bool SHValidKey(const char *key) {
    return key && key[0] && strlen(key) < SH_KEY_CAPACITY;
}

static bool SHValidIdentity(const SHIdentity *identity) {
    return identity && SHValidKey(identity->approachKey);
}

static void SHIdText(uint64_t signalId, char text[17]) {
    snprintf(text, 17, "%016" PRIx64, signalId);
}

static bool SHExec(SHStore *store, const char *sql) {
    return sqlite3_exec(store->db, sql, NULL, NULL, NULL) == SQLITE_OK;
}

static sqlite3_stmt *SHPrepare(SHStore *store, const char *sql) {
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(store->db, sql, -1, &statement, NULL) != SQLITE_OK)
        return NULL;
    return statement;
}

static void SHBindKey(sqlite3_stmt *statement, uint64_t signalId, const char *key) {
    char text[17];
    SHIdText(signalId, text);
    sqlite3_bind_text(statement, 1, text, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(statement, 2, key, -1, SQLITE_TRANSIENT);
}

static void SHBindOptionalText(sqlite3_stmt *statement, int index, const char *text) {
    if (text) sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT);
    else sqlite3_bind_null(statement, index);
}

static bool SHStepDone(sqlite3_stmt *statement) {
    if (!statement) return false;
    bool success = sqlite3_step(statement) == SQLITE_DONE;
    sqlite3_finalize(statement);
    return success;
}

static bool SHUpsertLocked(SHStore *store, const SHIdentity *identity, double seenAt) {
    sqlite3_stmt *statement = SHPrepare(store,
        "INSERT OR IGNORE INTO directions(signal_id,approach_key,name,approach_name,last_seen) "
        "VALUES(?1,?2,COALESCE(?3,''),COALESCE(?4,''),?5)");
    if (!statement) return false;
    SHBindKey(statement, identity->signalId, identity->approachKey);
    SHBindOptionalText(statement, 3, identity->name);
    SHBindOptionalText(statement, 4, identity->approachName);
    sqlite3_bind_double(statement, 5, seenAt);
    if (!SHStepDone(statement)) return false;
    statement = SHPrepare(store,
        "UPDATE directions SET name=COALESCE(?3,name),approach_name=COALESCE(?4,approach_name),"
        "last_seen=MAX(last_seen,?5) WHERE signal_id=?1 AND approach_key=?2");
    if (!statement) return false;
    SHBindKey(statement, identity->signalId, identity->approachKey);
    SHBindOptionalText(statement, 3, identity->name);
    SHBindOptionalText(statement, 4, identity->approachName);
    sqlite3_bind_double(statement, 5, seenAt);
    return SHStepDone(statement);
}

static double SHLastSeenLocked(SHStore *store, uint64_t signalId, const char *key) {
    sqlite3_stmt *statement = SHPrepare(store,
        "SELECT last_seen FROM directions WHERE signal_id=?1 AND approach_key=?2");
    if (!statement) return 0;
    SHBindKey(statement, signalId, key);
    double result = sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_double(statement, 0) : 0;
    sqlite3_finalize(statement);
    return result;
}

SHStore *SHOpen(const char *path) {
    if (!path || !path[0]) return NULL;
    SHStore *store = calloc(1, sizeof(*store));
    if (!store) return NULL;
    if (pthread_mutex_init(&store->mutex, NULL) != 0) {
        free(store);
        return NULL;
    }
    if (sqlite3_open_v2(path, &store->db,
                        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                        NULL) != SQLITE_OK) {
        SHClose(store);
        return NULL;
    }
    sqlite3_busy_timeout(store->db, 100);
    sqlite3_stmt *version = SHPrepare(store, "PRAGMA user_version");
    if (!version || sqlite3_step(version) != SQLITE_ROW) {
        if (version) sqlite3_finalize(version);
        SHClose(store);
        return NULL;
    }
    int schemaVersion = sqlite3_column_int(version, 0);
    sqlite3_finalize(version);
    if (schemaVersion > SH_SCHEMA_VERSION ||
        !SHExec(store, "PRAGMA journal_mode=WAL") ||
        !SHExec(store, "PRAGMA synchronous=NORMAL") ||
        !SHExec(store, "BEGIN IMMEDIATE")) {
        SHClose(store);
        return NULL;
    }
    bool success = SHExec(store,
        "CREATE TABLE IF NOT EXISTS directions("
        "signal_id TEXT NOT NULL,approach_key TEXT NOT NULL,name TEXT NOT NULL DEFAULT '',"
        "approach_name TEXT NOT NULL DEFAULT '',blacklisted INTEGER NOT NULL DEFAULT 0,"
        "last_seen REAL NOT NULL DEFAULT 0,PRIMARY KEY(signal_id,approach_key));"
        "CREATE TABLE IF NOT EXISTS phases("
        "signal_id TEXT NOT NULL,approach_key TEXT NOT NULL,color INTEGER NOT NULL,"
        "starts_at REAL NOT NULL,ends_at REAL NOT NULL,observed_at REAL NOT NULL,"
        "PRIMARY KEY(signal_id,approach_key,starts_at,ends_at,color));"
        "CREATE INDEX IF NOT EXISTS phase_direction_time ON phases(signal_id,approach_key,starts_at);"
        "CREATE TABLE IF NOT EXISTS models("
        "signal_id TEXT NOT NULL,approach_key TEXT NOT NULL,valid INTEGER NOT NULL DEFAULT 0,"
        "anchor REAL NOT NULL,period REAL NOT NULL,learned_at REAL NOT NULL,"
        "learning_since REAL NOT NULL DEFAULT 0,"
        "PRIMARY KEY(signal_id,approach_key));"
        "CREATE TABLE IF NOT EXISTS model_phases("
        "signal_id TEXT NOT NULL,approach_key TEXT NOT NULL,ordinal INTEGER NOT NULL,"
        "color INTEGER NOT NULL,starts_at REAL NOT NULL,ends_at REAL NOT NULL,"
        "PRIMARY KEY(signal_id,approach_key,ordinal));"
        "CREATE TABLE IF NOT EXISTS observations("
        "signal_id TEXT NOT NULL,approach_key TEXT NOT NULL,color INTEGER NOT NULL,"
        "ends_at REAL NOT NULL,observed_at REAL NOT NULL,starts_at REAL,"
        "PRIMARY KEY(signal_id,approach_key));"
        "PRAGMA user_version=1");
    if (!success || !SHExec(store, "COMMIT")) {
        SHExec(store, "ROLLBACK");
        SHClose(store);
        return NULL;
    }
    return store;
}

void SHClose(SHStore *store) {
    if (!store) return;
    if (store->db) sqlite3_close_v2(store->db);
    pthread_mutex_destroy(&store->mutex);
    free(store);
}

bool SHUpsertIdentity(SHStore *store, const SHIdentity *identity) {
    if (!store || !SHValidIdentity(identity)) return false;
    pthread_mutex_lock(&store->mutex);
    bool success = SHExec(store, "BEGIN IMMEDIATE");
    if (success) success = SHUpsertLocked(store, identity, 0);
    if (success) success = SHExec(store, "COMMIT");
    if (!success) SHExec(store, "ROLLBACK");
    pthread_mutex_unlock(&store->mutex);
    return success;
}

static SHModel SHLoadModelLocked(SHStore *store, uint64_t signalId, const char *key) {
    SHModel model = {0};
    sqlite3_stmt *statement = SHPrepare(store,
        "SELECT valid,anchor,period,learned_at,learning_since FROM models WHERE signal_id=?1 AND approach_key=?2");
    if (!statement) return model;
    SHBindKey(statement, signalId, key);
    if (sqlite3_step(statement) == SQLITE_ROW) {
        model.valid = sqlite3_column_int(statement, 0) != 0;
        model.anchor = sqlite3_column_double(statement, 1);
        model.period = sqlite3_column_double(statement, 2);
        model.learnedAt = sqlite3_column_double(statement, 3);
        model.learningSince = sqlite3_column_double(statement, 4);
    }
    sqlite3_finalize(statement);
    if (!model.valid || !isfinite(model.period) || model.period <= 0) {
        model.valid = false;
        return model;
    }
    statement = SHPrepare(store,
        "SELECT color,starts_at,ends_at FROM model_phases "
        "WHERE signal_id=?1 AND approach_key=?2 ORDER BY ordinal");
    if (!statement) {
        model.valid = false;
        return model;
    }
    SHBindKey(statement, signalId, key);
    while (sqlite3_step(statement) == SQLITE_ROW) {
        if (model.count == SH_MAX_MODEL_PHASES) {
            model.valid = false;
            break;
        }
        SHPhase *phase = &model.phases[model.count++];
        phase->color = sqlite3_column_int(statement, 0);
        phase->startsAt = sqlite3_column_double(statement, 1);
        phase->endsAt = sqlite3_column_double(statement, 2);
    }
    sqlite3_finalize(statement);
    if (model.count < 2 || fabs(model.phases[0].startsAt) > SH_TIME_EPSILON ||
        fabs(model.phases[model.count - 1].endsAt - model.period) > SH_TIME_EPSILON)
        model.valid = false;
    for (size_t i = 0; model.valid && i < model.count; ++i) {
        const SHPhase *phase = &model.phases[i];
        if (phase->color < 1 || phase->color > 3 || !isfinite(phase->startsAt) ||
            !isfinite(phase->endsAt) || phase->endsAt <= phase->startsAt ||
            (i && fabs(phase->startsAt - model.phases[i - 1].endsAt) > SH_TIME_EPSILON))
            model.valid = false;
    }
    return model;
}

static bool SHModelAt(const SHModel *model, double now, SHPrediction *prediction) {
    if (!model->valid || !isfinite(now)) return false;
    double offset = fmod(now - model->anchor, model->period);
    if (offset < 0) offset += model->period;
    for (size_t i = 0; i < model->count; ++i) {
        const SHPhase *phase = &model->phases[i];
        if (offset >= phase->startsAt && offset < phase->endsAt) {
            prediction->color = phase->color;
            prediction->remaining = phase->endsAt - offset;
            prediction->phaseEndsAt = now + prediction->remaining;
            prediction->learnedAt = model->learnedAt;
            prediction->available = true;
            return true;
        }
    }
    return false;
}

static bool SHInvalidateLocked(SHStore *store, uint64_t signalId, const char *key, double since) {
    sqlite3_stmt *statement = SHPrepare(store,
        "INSERT INTO models(signal_id,approach_key,valid,anchor,period,learned_at,learning_since) "
        "VALUES(?1,?2,0,0,0,0,?3) ON CONFLICT(signal_id,approach_key) DO UPDATE "
        "SET valid=0,learning_since=MAX(learning_since,excluded.learning_since)");
    if (!statement) return false;
    SHBindKey(statement, signalId, key);
    sqlite3_bind_double(statement, 3, since);
    if (!SHStepDone(statement)) return false;
    const char *queries[] = {
        "DELETE FROM model_phases WHERE signal_id=?1 AND approach_key=?2"
    };
    for (size_t i = 0; i < sizeof(queries) / sizeof(queries[0]); ++i) {
        statement = SHPrepare(store, queries[i]);
        if (!statement) return false;
        SHBindKey(statement, signalId, key);
        if (!SHStepDone(statement)) return false;
    }
    return true;
}

static bool SHPhaseMatchesModel(const SHModel *model, const SHPhase *phase) {
    if (!model->valid) return true;
    for (size_t i = 0; i < model->count; ++i) {
        const SHPhase *known = &model->phases[i];
        if (known->color != phase->color) continue;
        double cycles = round((phase->startsAt - model->anchor - known->startsAt) / model->period);
        double expectedStart = model->anchor + cycles * model->period + known->startsAt;
        double expectedEnd = model->anchor + cycles * model->period + known->endsAt;
        if (fabs(phase->startsAt - expectedStart) <= SH_STABILITY_TOLERANCE &&
            fabs(phase->endsAt - expectedEnd) <= SH_STABILITY_TOLERANCE)
            return true;
    }
    return false;
}

static bool SHInsertPhaseLocked(SHStore *store, const SHIdentity *identity,
                                const SHPhase *phase, double observedAt, bool *changed) {
    sqlite3_stmt *statement = SHPrepare(store,
        "SELECT 1 FROM phases WHERE signal_id=?1 AND approach_key=?2 AND color=?3 "
        "AND ABS(starts_at-?4)<=?6 AND ABS(ends_at-?5)<=?6 LIMIT 1");
    if (!statement) return false;
    SHBindKey(statement, identity->signalId, identity->approachKey);
    sqlite3_bind_int(statement, 3, phase->color);
    sqlite3_bind_double(statement, 4, phase->startsAt);
    sqlite3_bind_double(statement, 5, phase->endsAt);
    sqlite3_bind_double(statement, 6, SH_TIME_EPSILON);
    bool exists = sqlite3_step(statement) == SQLITE_ROW;
    sqlite3_finalize(statement);
    if (exists) return true;
    statement = SHPrepare(store,
        "DELETE FROM phases WHERE signal_id=?1 AND approach_key=?2 "
        "AND ends_at>?3 AND starts_at<?4");
    if (!statement) return false;
    SHBindKey(statement, identity->signalId, identity->approachKey);
    sqlite3_bind_double(statement, 3, phase->startsAt + SH_TIME_EPSILON);
    sqlite3_bind_double(statement, 4, phase->endsAt - SH_TIME_EPSILON);
    if (!SHStepDone(statement)) return false;
    statement = SHPrepare(store,
        "INSERT INTO phases(signal_id,approach_key,color,starts_at,ends_at,observed_at) "
        "VALUES(?1,?2,?3,?4,?5,?6)");
    if (!statement) return false;
    SHBindKey(statement, identity->signalId, identity->approachKey);
    sqlite3_bind_int(statement, 3, phase->color);
    sqlite3_bind_double(statement, 4, phase->startsAt);
    sqlite3_bind_double(statement, 5, phase->endsAt);
    sqlite3_bind_double(statement, 6, observedAt);
    if (!SHStepDone(statement)) return false;
    *changed = true;
    return true;
}

static bool SHSaveModelLocked(SHStore *store, const SHIdentity *identity, const SHModel *model) {
    sqlite3_stmt *statement = SHPrepare(store,
        "INSERT OR REPLACE INTO models(signal_id,approach_key,valid,anchor,period,learned_at,learning_since) "
        "VALUES(?1,?2,1,?3,?4,?5,?6)");
    if (!statement) return false;
    SHBindKey(statement, identity->signalId, identity->approachKey);
    sqlite3_bind_double(statement, 3, model->anchor);
    sqlite3_bind_double(statement, 4, model->period);
    sqlite3_bind_double(statement, 5, model->learnedAt);
    sqlite3_bind_double(statement, 6, model->learningSince);
    if (!SHStepDone(statement)) return false;
    statement = SHPrepare(store, "DELETE FROM model_phases WHERE signal_id=?1 AND approach_key=?2");
    if (!statement) return false;
    SHBindKey(statement, identity->signalId, identity->approachKey);
    if (!SHStepDone(statement)) return false;
    for (size_t i = 0; i < model->count; ++i) {
        statement = SHPrepare(store,
            "INSERT INTO model_phases(signal_id,approach_key,ordinal,color,starts_at,ends_at) "
            "VALUES(?1,?2,?3,?4,?5,?6)");
        if (!statement) return false;
        SHBindKey(statement, identity->signalId, identity->approachKey);
        sqlite3_bind_int(statement, 3, (int)i);
        sqlite3_bind_int(statement, 4, model->phases[i].color);
        sqlite3_bind_double(statement, 5, model->phases[i].startsAt);
        sqlite3_bind_double(statement, 6, model->phases[i].endsAt);
        if (!SHStepDone(statement)) return false;
    }
    return true;
}

static bool SHLearnLocked(SHStore *store, const SHIdentity *identity, double observedAt) {
    SHPhase phases[SH_MAX_SAMPLES];
    size_t count = 0;
    SHModel previous = SHLoadModelLocked(store, identity->signalId, identity->approachKey);
    sqlite3_stmt *statement = SHPrepare(store,
        "SELECT color,starts_at,ends_at FROM (SELECT color,starts_at,ends_at FROM phases "
        "WHERE signal_id=?1 AND approach_key=?2 AND starts_at>=?3 "
        "ORDER BY starts_at DESC LIMIT 256) ORDER BY starts_at");
    if (!statement) return false;
    SHBindKey(statement, identity->signalId, identity->approachKey);
    sqlite3_bind_double(statement, 3, previous.learningSince);
    while (count < SH_MAX_SAMPLES && sqlite3_step(statement) == SQLITE_ROW) {
        SHPhase phase = {sqlite3_column_int(statement, 0), sqlite3_column_double(statement, 1),
                         sqlite3_column_double(statement, 2)};
        if (count && phases[count - 1].color == phase.color &&
            fabs(phases[count - 1].endsAt - phase.startsAt) <= SH_TIME_EPSILON) {
            phases[count - 1].endsAt = phase.endsAt;
        } else {
            phases[count++] = phase;
        }
    }
    sqlite3_finalize(statement);
    SHModel candidate = {0};
    double latestEnd = 0;
    for (size_t first = 0; first < count; ++first) {
        for (size_t length = 2; length <= SH_MAX_MODEL_PHASES && first + 2 * length <= count; ++length) {
            bool matches = true;
            bool hasRed = false, hasGreen = false;
            double firstPeriod = phases[first + length - 1].endsAt - phases[first].startsAt;
            double secondPeriod = phases[first + 2 * length - 1].endsAt - phases[first + length].startsAt;
            if (firstPeriod <= 0 || secondPeriod > SH_MAX_PERIOD_SECONDS ||
                fabs(firstPeriod - secondPeriod) > SH_STABILITY_TOLERANCE) continue;
            for (size_t i = 0; i < 2 * length; ++i) {
                const SHPhase *phase = &phases[first + i];
                if (i && fabs(phase->startsAt - phases[first + i - 1].endsAt) > SH_TIME_EPSILON) {
                    matches = false;
                    break;
                }
                if (phase->color == 1) hasRed = true;
                if (phase->color == 3) hasGreen = true;
                if (i < length) {
                    const SHPhase *repeated = &phases[first + i + length];
                    if (phase->color != repeated->color ||
                        fabs((phase->endsAt - phase->startsAt) -
                             (repeated->endsAt - repeated->startsAt)) > SH_STABILITY_TOLERANCE) {
                        matches = false;
                        break;
                    }
                }
            }
            double end = phases[first + 2 * length - 1].endsAt;
            if (!matches || !hasRed || !hasGreen || end <= latestEnd) continue;
            candidate.valid = true;
            candidate.anchor = phases[first + length].startsAt;
            candidate.period = secondPeriod;
            candidate.learnedAt = fmin(observedAt, end);
            /* Earlier schedule history may contain a different cycle. This
             * model is supported by the two stable cycles beginning here. */
            candidate.learningSince = fmax(previous.learningSince, phases[first].startsAt);
            candidate.count = length;
            for (size_t i = 0; i < length; ++i) {
                candidate.phases[i] = phases[first + length + i];
                candidate.phases[i].startsAt -= candidate.anchor;
                candidate.phases[i].endsAt -= candidate.anchor;
            }
            latestEnd = end;
        }
    }
    if (candidate.valid) {
        /* A stable historical block is insufficient when the same native
         * timetable already contains a later change. Validate every known
         * phase from the candidate anchor before allowing extrapolation. */
        for (size_t i = 0; i < count; ++i) {
            if (phases[i].startsAt + SH_TIME_EPSILON < candidate.anchor) continue;
            if (!SHPhaseMatchesModel(&candidate, &phases[i])) {
                if (!SHInvalidateLocked(store, identity->signalId,
                                         identity->approachKey, phases[i].startsAt)) return false;
                candidate.valid = false;
                break;
            }
        }
        if (candidate.valid && !SHSaveModelLocked(store, identity, &candidate)) return false;
    }
    /* Keep bounded historical samples, retaining enough phases for verification. */
    statement = SHPrepare(store,
        "DELETE FROM phases WHERE signal_id=?1 AND approach_key=?2 AND starts_at NOT IN "
        "(SELECT starts_at FROM phases WHERE signal_id=?1 AND approach_key=?2 ORDER BY starts_at DESC LIMIT 256)");
    if (!statement) return false;
    SHBindKey(statement, identity->signalId, identity->approachKey);
    return SHStepDone(statement);
}

static bool SHValidPhase(const SHPhase *phase) {
    return phase->color >= 1 && phase->color <= 3 && isfinite(phase->startsAt) &&
           isfinite(phase->endsAt) && phase->startsAt > 0 &&
           phase->endsAt > phase->startsAt &&
           phase->endsAt - phase->startsAt <= SH_MAX_PHASE_SECONDS;
}

static int SHComparePhases(const void *a, const void *b) {
    const SHPhase *first = a, *second = b;
    if (first->startsAt < second->startsAt) return -1;
    if (first->startsAt > second->startsAt) return 1;
    if (first->endsAt < second->endsAt) return -1;
    if (first->endsAt > second->endsAt) return 1;
    return first->color - second->color;
}

bool SHRemember(SHStore *store, const SHIdentity *identity,
                const SHPhase *phases, size_t count, double observedAt) {
    if (!store || !SHValidIdentity(identity) || !isfinite(observedAt) || observedAt <= 0 ||
        (!phases && count) || count > SH_MAX_SAMPLES) return false;
    SHPhase normalized[SH_MAX_SAMPLES];
    for (size_t i = 0; i < count; ++i) {
        if (!SHValidPhase(&phases[i])) return false;
        normalized[i] = phases[i];
    }
    qsort(normalized, count, sizeof(normalized[0]), SHComparePhases);
    size_t normalizedCount = 0;
    for (size_t i = 0; i < count; ++i) {
        SHPhase phase = normalized[i];
        if (normalizedCount) {
            SHPhase *last = &normalized[normalizedCount - 1];
            if (phase.startsAt < last->endsAt - SH_TIME_EPSILON) {
                if (phase.color != last->color) return false;
                last->endsAt = fmax(last->endsAt, phase.endsAt);
                continue;
            }
            if (phase.color == last->color && fabs(phase.startsAt - last->endsAt) <= SH_TIME_EPSILON) {
                last->endsAt = phase.endsAt;
                continue;
            }
        }
        normalized[normalizedCount++] = phase;
    }
    pthread_mutex_lock(&store->mutex);
    bool success = SHExec(store, "BEGIN IMMEDIATE");
    if (success && observedAt + SH_TIME_EPSILON <
        SHLastSeenLocked(store, identity->signalId, identity->approachKey)) success = false;
    if (success) success = SHUpsertLocked(store, identity, observedAt);
    SHModel model = success ? SHLoadModelLocked(store, identity->signalId, identity->approachKey) : (SHModel){0};
    for (size_t i = 0; success && model.valid && i < normalizedCount; ++i) {
        /* Older timetable history belongs to the previous learning epoch.
         * Replaying it must not invalidate a newly established current cycle. */
        if (normalized[i].endsAt <= model.learningSince + SH_TIME_EPSILON) continue;
        if (!SHPhaseMatchesModel(&model, &normalized[i])) {
            success = SHInvalidateLocked(store, identity->signalId, identity->approachKey, normalized[i].startsAt);
            model.valid = false;
        }
    }
    bool changed = false;
    for (size_t i = 0; success && i < normalizedCount; ++i)
        success = SHInsertPhaseLocked(store, identity, &normalized[i], observedAt, &changed);
    if (success && changed) success = SHLearnLocked(store, identity, observedAt);
    if (success) success = SHExec(store, "COMMIT");
    if (!success) SHExec(store, "ROLLBACK");
    pthread_mutex_unlock(&store->mutex);
    return success;
}

bool SHObserve(SHStore *store, const SHIdentity *identity, int color,
               double phaseEndsAt, double observedAt) {
    if (!store || !SHValidIdentity(identity) || color < 1 || color > 3 ||
        !isfinite(phaseEndsAt) || !isfinite(observedAt) || observedAt <= 0 ||
        phaseEndsAt < observedAt - SH_TIME_EPSILON ||
        phaseEndsAt - observedAt > SH_MAX_PHASE_SECONDS) return false;
    pthread_mutex_lock(&store->mutex);
    bool success = SHExec(store, "BEGIN IMMEDIATE");
    if (success && observedAt + SH_TIME_EPSILON <
        SHLastSeenLocked(store, identity->signalId, identity->approachKey)) success = false;
    if (success) success = SHUpsertLocked(store, identity, observedAt);
    bool hasPrevious = false, hasStart = false;
    int previousColor = 0;
    double previousEnd = 0, previousObserved = 0, previousStart = 0;
    sqlite3_stmt *statement = NULL;
    if (success) {
        statement = SHPrepare(store,
            "SELECT color,ends_at,observed_at,starts_at FROM observations WHERE signal_id=?1 AND approach_key=?2");
        if (!statement) success = false;
        else {
            SHBindKey(statement, identity->signalId, identity->approachKey);
            if (sqlite3_step(statement) == SQLITE_ROW) {
                hasPrevious = true;
                previousColor = sqlite3_column_int(statement, 0);
                previousEnd = sqlite3_column_double(statement, 1);
                previousObserved = sqlite3_column_double(statement, 2);
                hasStart = sqlite3_column_type(statement, 3) != SQLITE_NULL;
                previousStart = sqlite3_column_double(statement, 3);
            }
            sqlite3_finalize(statement);
        }
    }
    SHModel model = success ? SHLoadModelLocked(store, identity->signalId, identity->approachKey) : (SHModel){0};
    SHPrediction expected = {0};
    if (success && SHModelAt(&model, observedAt, &expected) &&
        (expected.color != color || fabs(expected.phaseEndsAt - phaseEndsAt) > SH_STABILITY_TOLERANCE))
        success = SHInvalidateLocked(store, identity->signalId, identity->approachKey, observedAt);
    bool trackStart = false;
    double startsAt = 0;
    bool changed = false;
    if (success && hasPrevious) {
        if (color == previousColor && fabs(phaseEndsAt - previousEnd) <= SH_STABILITY_TOLERANCE &&
            observedAt <= previousEnd + SH_TIME_EPSILON) {
            trackStart = hasStart;
            startsAt = previousStart;
        } else if (color != previousColor && observedAt - previousObserved <= SH_TRANSITION_GAP_SECONDS &&
                   previousEnd >= previousObserved - SH_TIME_EPSILON &&
                   previousEnd <= observedAt + SH_TIME_EPSILON &&
                   observedAt - previousEnd <= SH_TRANSITION_GAP_SECONDS) {
            trackStart = true;
            startsAt = previousEnd;
            if (hasStart) {
                SHPhase completed = {previousColor, previousStart, previousEnd};
                if (SHValidPhase(&completed))
                    success = SHInsertPhaseLocked(store, identity, &completed, observedAt, &changed);
            }
        }
    }
    if (success && changed) success = SHLearnLocked(store, identity, observedAt);
    if (success) {
        statement = SHPrepare(store,
            "INSERT OR REPLACE INTO observations(signal_id,approach_key,color,ends_at,observed_at,starts_at) "
            "VALUES(?1,?2,?3,?4,?5,?6)");
        if (!statement) success = false;
        else {
            SHBindKey(statement, identity->signalId, identity->approachKey);
            sqlite3_bind_int(statement, 3, color);
            sqlite3_bind_double(statement, 4, phaseEndsAt);
            sqlite3_bind_double(statement, 5, observedAt);
            if (trackStart) sqlite3_bind_double(statement, 6, startsAt);
            else sqlite3_bind_null(statement, 6);
            success = SHStepDone(statement);
        }
    }
    if (success) success = SHExec(store, "COMMIT");
    if (!success) SHExec(store, "ROLLBACK");
    pthread_mutex_unlock(&store->mutex);
    return success;
}

bool SHPredict(SHStore *store, uint64_t signalId, const char *approachKey,
               double now, SHPrediction *prediction) {
    if (prediction) memset(prediction, 0, sizeof(*prediction));
    if (!store || !prediction || !SHValidKey(approachKey) || !isfinite(now)) return false;
    pthread_mutex_lock(&store->mutex);
    SHModel model = SHLoadModelLocked(store, signalId, approachKey);
    bool available = model.valid && now >= model.learnedAt &&
        now + SH_TIME_EPSILON >= SHLastSeenLocked(store, signalId, approachKey) &&
        now - model.learnedAt <= SH_PREDICTION_MAX_AGE_SECONDS && SHModelAt(&model, now, prediction);
    pthread_mutex_unlock(&store->mutex);
    return available;
}

bool SHSetBlacklisted(SHStore *store, uint64_t signalId, const char *approachKey, bool blacklisted) {
    if (!store || !SHValidKey(approachKey)) return false;
    SHIdentity identity = {signalId, approachKey, NULL, NULL};
    pthread_mutex_lock(&store->mutex);
    bool success = SHExec(store, "BEGIN IMMEDIATE");
    if (success) success = SHUpsertLocked(store, &identity, 0);
    if (success) {
        sqlite3_stmt *statement = SHPrepare(store,
            "UPDATE directions SET blacklisted=?3 WHERE signal_id=?1 AND approach_key=?2");
        if (!statement) success = false;
        else {
            SHBindKey(statement, signalId, approachKey);
            sqlite3_bind_int(statement, 3, blacklisted ? 1 : 0);
            success = SHStepDone(statement);
        }
    }
    if (success) success = SHExec(store, "COMMIT");
    if (!success) SHExec(store, "ROLLBACK");
    pthread_mutex_unlock(&store->mutex);
    return success;
}

bool SHIsBlacklisted(SHStore *store, uint64_t signalId, const char *approachKey) {
    if (!store || !SHValidKey(approachKey)) return false;
    pthread_mutex_lock(&store->mutex);
    sqlite3_stmt *statement = SHPrepare(store,
        "SELECT blacklisted FROM directions WHERE signal_id=?1 AND approach_key=?2");
    bool blacklisted = false;
    if (statement) {
        SHBindKey(statement, signalId, approachKey);
        if (sqlite3_step(statement) == SQLITE_ROW) blacklisted = sqlite3_column_int(statement, 0) != 0;
        sqlite3_finalize(statement);
    }
    pthread_mutex_unlock(&store->mutex);
    return blacklisted;
}

static void SHCopyText(char *target, size_t capacity, const unsigned char *text) {
    if (!capacity) return;
    snprintf(target, capacity, "%s", text ? (const char *)text : "");
}

size_t SHList(SHStore *store, SHEntry *entries, size_t capacity) {
    if (!store) return 0;
    pthread_mutex_lock(&store->mutex);
    sqlite3_stmt *statement = SHPrepare(store,
        "SELECT signal_id,approach_key,name,approach_name,blacklisted,last_seen "
        "FROM directions ORDER BY last_seen DESC,signal_id,approach_key");
    size_t count = 0;
    if (statement) {
        while (sqlite3_step(statement) == SQLITE_ROW) {
            if (entries && count < capacity) {
                SHEntry *entry = &entries[count];
                memset(entry, 0, sizeof(*entry));
                const unsigned char *id = sqlite3_column_text(statement, 0);
                entry->signalId = id ? (uint64_t)strtoull((const char *)id, NULL, 16) : 0;
                SHCopyText(entry->approachKey, sizeof(entry->approachKey), sqlite3_column_text(statement, 1));
                SHCopyText(entry->name, sizeof(entry->name), sqlite3_column_text(statement, 2));
                SHCopyText(entry->approachName, sizeof(entry->approachName), sqlite3_column_text(statement, 3));
                entry->blacklisted = sqlite3_column_int(statement, 4) != 0;
                entry->lastObservedAt = sqlite3_column_double(statement, 5);
                SHModel model = SHLoadModelLocked(store, entry->signalId, entry->approachKey);
                entry->hasPrediction = model.valid;
                entry->learnedAt = model.learnedAt;
                for (size_t i = 0; i < model.count; ++i) {
                    double duration = model.phases[i].endsAt - model.phases[i].startsAt;
                    if (model.phases[i].color == 1) entry->redSeconds += duration;
                    else if (model.phases[i].color == 2) entry->yellowSeconds += duration;
                    else if (model.phases[i].color == 3) entry->greenSeconds += duration;
                }
                if (!model.valid) {
                    /* Observed durations remain useful before a stable complete
                     * cycle has been learned, and after a cycle changes. */
                    sqlite3_stmt *durations = SHPrepare(store,
                        "SELECT color,ends_at-starts_at FROM phases WHERE signal_id=?1 AND approach_key=?2 "
                        "ORDER BY starts_at DESC");
                    if (durations) {
                        SHBindKey(durations, entry->signalId, entry->approachKey);
                        bool seen[4] = {false};
                        while (sqlite3_step(durations) == SQLITE_ROW) {
                            int color = sqlite3_column_int(durations, 0);
                            if (color < 1 || color > 3 || seen[color]) continue;
                            seen[color] = true;
                            double duration = sqlite3_column_double(durations, 1);
                            if (color == 1) entry->redSeconds = duration;
                            else if (color == 2) entry->yellowSeconds = duration;
                            else entry->greenSeconds = duration;
                            if (seen[1] && seen[2] && seen[3]) break;
                        }
                        sqlite3_finalize(durations);
                    }
                }
            }
            ++count;
        }
        sqlite3_finalize(statement);
    }
    pthread_mutex_unlock(&store->mutex);
    return count;
}
