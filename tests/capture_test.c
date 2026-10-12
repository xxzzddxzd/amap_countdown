#include "SignalCapture.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    unsigned char *object;
    unsigned char *items;
    unsigned char *lights;
    size_t count;
    size_t stride;
    bool car;
} Fixture;

static void WritePointer(void *object, size_t offset, const void *value) {
    uintptr_t pointer = (uintptr_t)value;
    memcpy((unsigned char *)object + offset, &pointer, sizeof(pointer));
}

static void WriteInt(void *object, size_t offset, int32_t value) {
    memcpy((unsigned char *)object + offset, &value, sizeof(value));
}

static void WriteId(void *object, size_t offset, uint64_t value) {
    memcpy((unsigned char *)object + offset, &value, sizeof(value));
}

static void *Allocate(size_t size) {
    void *value = calloc(1, size ? size : 8);
    assert(value && (uintptr_t)value >= UINT64_C(0x100000000));
    return value;
}

static Fixture MakeFixture(bool car, size_t count) {
    Fixture fixture = {.count = count, .stride = car ? 232 : 112, .car = car};
    fixture.object = Allocate(car ? 312 : 128);
    fixture.items = Allocate(count * fixture.stride);
    WritePointer(fixture.object, car ? 296 : 0x68, fixture.items);
    WritePointer(fixture.object, car ? 304 : 0x70,
                    fixture.items + count * fixture.stride);
    if (!car) fixture.lights = Allocate(count * 88);
    for (size_t index = 0; index < count; ++index) {
        unsigned char *item = fixture.items + index * fixture.stride;
        WriteId(item, car ? 0x60 : 8, index + 1);
        WriteInt(item, car ? 0x4c : 0x44, (int32_t)(500 + index));
        if (car) {
            WriteInt(item, 8, 1);
            WriteInt(item, 224, -1);
        } else {
            /* This range ends before currentOffset: distant forward lights
             * must remain visible outside the nearest-selector interval. */
            WriteInt(item, 0x48, (int32_t)(510 + index));
            WritePointer(item, 0x28, fixture.lights + index * 88);
            WritePointer(item, 0x30, fixture.lights + (index + 1) * 88);
        }
    }
    return fixture;
}

static void DestroyFixture(Fixture fixture) {
    free(fixture.object);
    free(fixture.items);
    free(fixture.lights);
}

static bool Read(Fixture fixture, int currentOffset, SRSignal *out,
                 size_t capacity, size_t *count) {
    return fixture.car
        ? SCReadCar(fixture.object, currentOffset, 100.0, out, capacity, count)
        : SCReadTravel(fixture.object, currentOffset, 100.0, out, capacity, count);
}

static void AttachPhases(Fixture fixture, size_t index,
                         void *begin, size_t count) {
    void *container = fixture.car
        ? fixture.items + index * fixture.stride
        : fixture.lights + index * 88;
    WritePointer(container, fixture.car ? 136 : 0x10, begin);
    WritePointer(container, fixture.car ? 144 : 0x18,
                    begin ? (unsigned char *)begin + count * 24 : NULL);
}

static void SetPhase(void *table, size_t index, int32_t code,
                      int64_t startsAt, int64_t endsAt) {
    unsigned char *row = (unsigned char *)table + index * 24;
    WriteInt(row, 0, code);
    memcpy(row + 8, &startsAt, sizeof(startsAt));
    memcpy(row + 16, &endsAt, sizeof(endsAt));
}

static void CheckPhase(SRSignal signal, unsigned index, int color,
                        double startsAt, double endsAt) {
    assert(index < signal.phaseCount);
    assert(signal.phases[index].color == color);
    assert(signal.phases[index].startsAt == startsAt);
    assert(signal.phases[index].endsAt == endsAt);
}

static void TestSorting(bool car) {
    Fixture fixture = MakeFixture(car, 7);
    int targets[] = {500, 600, 700, 1000, 980, 1001, 970};
    for (size_t index = 0; index < fixture.count; ++index) {
        void *item = fixture.items + index * fixture.stride;
        WriteInt(item, car ? 0x4c : 0x44, targets[index]);
        if (!car) WriteInt(item, 0x48, targets[index]);
    }
    SRSignal out[7];
    size_t count = 999;
    assert(Read(fixture, 1000, out, 2, &count) && count == 2);
    assert(out[0].id == 4 && out[0].distanceMeters == 0.0);
    assert(out[1].id == 5 && out[1].distanceMeters == 20.0);
    assert(out[0].source == (car ? 3 : 2));
    assert(out[0].targetOffset == 1000 && out[0].capturedAt == 100.0);
    assert(!out[0].ambiguous && !out[0].dataUnavailable && out[0].phaseCount == 0);
    assert(Read(fixture, 1000, out, 7, &count) && count == 6);
    const uint64_t expected[] = {4, 5, 7, 3, 2, 1};
    for (size_t index = 0; index < count; ++index)
        assert(out[index].id == expected[index]);

    /* Invalid identity is a waiting slot at the same location, never skipped. */
    WriteId(fixture.items + 3 * fixture.stride, car ? 0x60 : 8, UINT64_MAX);
    assert(Read(fixture, 1000, out, 1, &count) && count == 1);
    assert(out[0].id == 0 && out[0].ambiguous && out[0].dataUnavailable && out[0].distanceMeters == 0.0);
    WriteId(fixture.items + 3 * fixture.stride, car ? 0x60 : 8, 0);
    assert(Read(fixture, 1000, out, 2, &count) && count == 2);
    assert(out[0].id == 0 && out[0].ambiguous && out[0].dataUnavailable && out[1].id == 5);
    assert(Read(fixture, 1000, NULL, 0, &count) && count == 0);
    DestroyFixture(fixture);
}

static void TestFullVector(bool car) {
    size_t maximum = car ? 512 : 256;
    Fixture fixture = MakeFixture(car, maximum);
    SRSignal out[3];
    size_t count = 0;
    assert(Read(fixture, 1000, out, 3, &count) && count == 3);
    /* In the 512-entry car vector, 500 + 511 is already passed. */
    size_t nearest = car ? 500 : maximum - 1;
    assert(out[0].id == nearest + 1);
    assert(out[1].id == nearest && out[2].id == nearest - 1);
    DestroyFixture(fixture);
}

static void TestArgumentsAndVectors(bool car) {
    Fixture fixture = MakeFixture(car, 1);
    size_t beginOffset = car ? 296 : 0x68;
    size_t endOffset = car ? 304 : 0x70;
    SRSignal out[2];
    size_t count = 5;
    WritePointer(fixture.object, beginOffset, NULL);
    WritePointer(fixture.object, endOffset, NULL);
    assert(Read(fixture, 1000, out, 2, &count) && count == 0);
    WritePointer(fixture.object, beginOffset, fixture.items);
    WritePointer(fixture.object, endOffset, fixture.items);
    assert(Read(fixture, 1000, out, 2, &count) && count == 0);
    WritePointer(fixture.object, endOffset, fixture.items + fixture.stride);
    assert(!Read(fixture, -1, out, 2, &count) && count == 0);
    assert(!Read(fixture, 1000, NULL, 2, &count) && count == 0);
    assert(!Read(fixture, 1000, out, 2, NULL));
    assert(!(car ? SCReadCar(NULL, 1000, 100.0, out, 2, &count)
                 : SCReadTravel(NULL, 1000, 100.0, out, 2, &count)));
    assert(count == 0);
    assert(!(car ? SCReadCar(fixture.object, 1000, NAN, out, 2, &count)
                 : SCReadTravel(fixture.object, 1000, NAN, out, 2, &count)));
    assert(count == 0);
    assert(!(car ? SCReadCar(fixture.object + 1, 1000, 100.0, out, 2, &count)
                 : SCReadTravel(fixture.object + 1, 1000, 100.0, out, 2, &count)));
    assert(count == 0);

    WritePointer(fixture.object, endOffset, fixture.items + fixture.stride - 8);
    assert(!Read(fixture, 1000, out, 2, &count) && count == 0);
    WritePointer(fixture.object, endOffset,
                    (const void *)((uintptr_t)fixture.items - 8));
    assert(!Read(fixture, 1000, out, 2, &count) && count == 0);
    WritePointer(fixture.object, beginOffset, fixture.items + 1);
    WritePointer(fixture.object, endOffset, fixture.items + fixture.stride + 1);
    assert(!Read(fixture, 1000, out, 2, &count) && count == 0);
    WritePointer(fixture.object, beginOffset, (const void *)(uintptr_t)8);
    WritePointer(fixture.object, endOffset, (const void *)(uintptr_t)8);
    assert(!Read(fixture, 1000, out, 2, &count) && count == 0);
    WritePointer(fixture.object, beginOffset, fixture.items);
    size_t maximum = car ? 512 : 256;
    WritePointer(fixture.object, endOffset,
                    (const void *)((uintptr_t)fixture.items +
                                  (maximum + 1) * fixture.stride));
    assert(!Read(fixture, 1000, out, 2, &count) && count == 0);
    DestroyFixture(fixture);
}

static void TestCarPhases(void) {
    Fixture fixture = MakeFixture(true, 1);
    unsigned char *table = Allocate(64 * 24);
    AttachPhases(fixture, 0, table, 2);
    SetPhase(table, 0, 11, 100, 130);
    SetPhase(table, 1, 30, 130, 170);
    WriteInt(fixture.items, 224, 3);
    SRSignal out[1];
    size_t count = 0;
    assert(Read(fixture, 1000, out, 1, &count) && count == 1);
    assert(!out[0].ambiguous && !out[0].dataUnavailable && out[0].phaseCount == 3);
    CheckPhase(out[0], 0, 3, 100, 127);
    CheckPhase(out[0], 1, 2, 127, 130);
    CheckPhase(out[0], 2, 1, 130, 170);

    WriteInt(fixture.items, 224, 30);
    assert(Read(fixture, 1000, out, 1, &count));
    assert(out[0].phaseCount == 2);
    CheckPhase(out[0], 0, 2, 100, 130);
    WriteInt(fixture.items, 224, 1000);
    assert(Read(fixture, 1000, out, 1, &count));
    CheckPhase(out[0], 0, 2, 100, 130);
    WriteInt(fixture.items, 224, -1);
    assert(Read(fixture, 1000, out, 1, &count));
    assert(out[0].phaseCount == 2);
    CheckPhase(out[0], 0, 3, 100, 130);
    WriteInt(fixture.items, 224, 0);
    assert(Read(fixture, 1000, out, 1, &count));
    assert(out[0].phaseCount == 2);
    CheckPhase(out[0], 0, 3, 100, 130);

    /* Continuous native green fragments share ONE final yellow interval. */
    AttachPhases(fixture, 0, table, 4);
    SetPhase(table, 0, 11, 100, 110);
    SetPhase(table, 1, 11, 110, 130);
    SetPhase(table, 2, 1, 130, 150);
    SetPhase(table, 3, 30, 150, 170);
    WriteInt(fixture.items, 224, 3);
    assert(Read(fixture, 1000, out, 1, &count));
    assert(!out[0].ambiguous && !out[0].dataUnavailable && out[0].phaseCount == 3);
    CheckPhase(out[0], 0, 3, 100, 127);
    CheckPhase(out[0], 1, 2, 127, 130);
    CheckPhase(out[0], 2, 1, 130, 170);

    /* Up to 128 normalized rows may arise; retain only the first 64 safely. */
    AttachPhases(fixture, 0, table, 64);
    for (size_t index = 0; index < 64; ++index)
        SetPhase(table, index, index % 2 ? 30 : 11,
                    100 + (int64_t)index * 20, 120 + (int64_t)index * 20);
    assert(Read(fixture, 1000, out, 1, &count));
    assert(!out[0].ambiguous && !out[0].dataUnavailable && out[0].phaseCount == SR_MAX_PHASES);
    SetPhase(table, 63, 999, 1360, 1380);
    assert(Read(fixture, 1000, out, 1, &count));
    assert(!out[0].ambiguous && out[0].dataUnavailable && out[0].phaseCount == 0);
    free(table);
    DestroyFixture(fixture);
}

static void TestTravelPhases(void) {
    Fixture fixture = MakeFixture(false, 1);
    unsigned char *table = Allocate(5 * 24);
    AttachPhases(fixture, 0, table, 2);
    SetPhase(table, 0, 10, 100, 130);
    SetPhase(table, 1, 1, 133, 160);
    SRSignal out[1];
    size_t count = 0;
    assert(Read(fixture, 1000, out, 1, &count) && count == 1);
    assert(!out[0].ambiguous && !out[0].dataUnavailable && out[0].phaseCount == 3);
    CheckPhase(out[0], 0, 3, 100, 130);
    CheckPhase(out[0], 1, 2, 130, 133);
    CheckPhase(out[0], 2, 1, 133, 160);
    SetPhase(table, 1, 1, 131, 160);
    assert(Read(fixture, 1000, out, 1, &count));
    CheckPhase(out[0], 1, 2, 130, 131);
    SetPhase(table, 1, 1, 135, 160);
    assert(Read(fixture, 1000, out, 1, &count));
    CheckPhase(out[0], 1, 2, 130, 135);
    SetPhase(table, 1, 1, 136, 160);
    assert(Read(fixture, 1000, out, 1, &count));
    assert(out[0].phaseCount == 2); /* Unverified gaps are not filled. */
    SetPhase(table, 1, 1, 130, 160);
    assert(Read(fixture, 1000, out, 1, &count));
    assert(out[0].phaseCount == 2);

    AttachPhases(fixture, 0, table, 5);
    SetPhase(table, 0, 10, 100, 200);
    SetPhase(table, 1, 11, 200, 300);
    SetPhase(table, 2, 2, 300, 302);
    SetPhase(table, 3, 5, 302, 305);
    SetPhase(table, 4, 1, 305, 350);
    assert(Read(fixture, 1000, out, 1, &count));
    assert(!out[0].ambiguous && !out[0].dataUnavailable && out[0].phaseCount == 3);
    CheckPhase(out[0], 0, 3, 100, 300);
    CheckPhase(out[0], 1, 2, 300, 305);
    CheckPhase(out[0], 2, 1, 305, 350);
    free(table);
    DestroyFixture(fixture);
}

static void TestUnusablePhases(bool car) {
    Fixture fixture = MakeFixture(car, 1);
    unsigned char *table = Allocate(65 * 24);
    SRSignal out[1];
    size_t count = 0;
    AttachPhases(fixture, 0, table, 2);
    SetPhase(table, 0, 11, 100, 130);
    SetPhase(table, 1, 1, 129, 170); /* Overlap. */
    assert(Read(fixture, 1000, out, 1, &count));
    assert(!out[0].ambiguous && out[0].dataUnavailable && out[0].phaseCount == 0);
    SetPhase(table, 1, 999, 130, 170);
    assert(Read(fixture, 1000, out, 1, &count));
    assert(!out[0].ambiguous && out[0].dataUnavailable && out[0].phaseCount == 0);
    AttachPhases(fixture, 0, table, 1);
    SetPhase(table, 0, 11, 100, car ? 1100 : 281);
    assert(Read(fixture, 1000, out, 1, &count));
    assert(!out[0].ambiguous && out[0].dataUnavailable && out[0].phaseCount == 0);
    SetPhase(table, 0, 11, 0, 30);
    assert(Read(fixture, 1000, out, 1, &count));
    assert(!out[0].ambiguous && out[0].dataUnavailable && out[0].phaseCount == 0);
    SetPhase(table, 0, 11, 100, 100);
    assert(Read(fixture, 1000, out, 1, &count));
    assert(!out[0].ambiguous && out[0].dataUnavailable && out[0].phaseCount == 0);

    /* Individual rows fit, but merged 1,000-second same-color data is invalid. */
    size_t pieces = car ? 2 : 10;
    AttachPhases(fixture, 0, table, pieces);
    for (size_t index = 0; index < pieces; ++index) {
        int64_t length = car ? 500 : 100;
        SetPhase(table, index, 11, 100 + (int64_t)index * length,
                    100 + (int64_t)(index + 1) * length);
    }
    assert(Read(fixture, 1000, out, 1, &count));
    assert(!out[0].ambiguous && out[0].dataUnavailable && out[0].phaseCount == 0);

    AttachPhases(fixture, 0, table, car ? 65 : 33);
    assert(Read(fixture, 1000, out, 1, &count));
    assert(!out[0].ambiguous && out[0].dataUnavailable && out[0].phaseCount == 0);
    AttachPhases(fixture, 0, table + 1, 1);
    assert(Read(fixture, 1000, out, 1, &count));
    assert(!out[0].ambiguous && out[0].dataUnavailable && out[0].phaseCount == 0);
    AttachPhases(fixture, 0, NULL, 0);
    assert(Read(fixture, 1000, out, 1, &count));
    assert(!out[0].ambiguous && !out[0].dataUnavailable && out[0].phaseCount == 0);
    free(table);
    DestroyFixture(fixture);
}

static void TestUnsupportedAndMultiInner(void) {
    Fixture car = MakeFixture(true, 2);
    SRSignal out[2];
    size_t count = 0;
    WriteInt(car.items + car.stride, 8, 0);
    assert(Read(car, 1000, out, 2, &count) && count == 2);
    assert(out[0].id == 2 && !out[0].ambiguous && out[0].dataUnavailable && out[0].phaseCount == 0);
    DestroyFixture(car);

    Fixture travel = MakeFixture(false, 2);
    unsigned char *multipleLights = Allocate(2 * 88);
    WritePointer(travel.items + travel.stride, 0x28, multipleLights);
    WritePointer(travel.items + travel.stride, 0x30, multipleLights + 2 * 88);
    assert(Read(travel, 1000, out, 2, &count) && count == 2);
    assert(out[0].id == 2 && !out[0].ambiguous && out[0].dataUnavailable && out[0].phaseCount == 0);
    WritePointer(travel.items + travel.stride, 0x28, NULL);
    WritePointer(travel.items + travel.stride, 0x30, NULL);
    assert(Read(travel, 1000, out, 2, &count));
    assert(!out[0].ambiguous && out[0].dataUnavailable && out[0].phaseCount == 0);
    WritePointer(travel.items + travel.stride, 0x28, multipleLights + 1);
    WritePointer(travel.items + travel.stride, 0x30, multipleLights + 89);
    assert(Read(travel, 1000, out, 2, &count));
    assert(!out[0].ambiguous && out[0].dataUnavailable && out[0].phaseCount == 0);
    WritePointer(travel.items + travel.stride, 0x28, travel.lights + 88);
    WritePointer(travel.items + travel.stride, 0x30, travel.lights + 176);
    WriteInt(travel.items + travel.stride, 0x48, 500); /* rangeEnd < target. */
    assert(Read(travel, 1000, out, 2, &count));
    assert(!out[0].ambiguous && out[0].dataUnavailable && out[0].phaseCount == 0);
    free(multipleLights);
    DestroyFixture(travel);
}

int main(void) {
    TestSorting(true);
    TestSorting(false);
    TestFullVector(true);
    TestFullVector(false);
    TestArgumentsAndVectors(true);
    TestArgumentsAndVectors(false);
    TestCarPhases();
    TestTravelPhases();
    TestUnusablePhases(true);
    TestUnusablePhases(false);
    TestUnsupportedAndMultiInner();
    puts("capture tests passed");
    return 0;
}
