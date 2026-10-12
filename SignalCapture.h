#ifndef AMAP_SIGNAL_CAPTURE_H
#define AMAP_SIGNAL_CAPTURE_H

#include "SignalRoute.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Read-only snapshots of AMap 16.11.1's verified native vectors. No native
 * pointers survive the call. currentOffset belongs to the active navigation,
 * and capturedAt is wall-clock epoch seconds. A valid empty vector returns
 * true with *outCount == 0; malformed input returns false with count zero.
 * All forward candidates are considered before the nearest capacity entries
 * are retained. Unknown identities and unusable phases remain waiting slots.
 * As with the existing native readers, pointer checks are plausibility checks;
 * the caller must provide the live native object during its callback. */
bool SCReadCar(const void *feed, int currentOffset, double capturedAt,
               SRSignal *out, size_t capacity, size_t *outCount);
bool SCReadTravel(const void *processor, int currentOffset, double capturedAt,
                  SRSignal *out, size_t capacity, size_t *outCount);

#ifdef __cplusplus
}
#endif
#endif
