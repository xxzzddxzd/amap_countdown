#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int64_t sign_extend(uint64_t value, unsigned bits) {
    uint64_t mask = 1ULL << (bits - 1);
    return (int64_t)((value ^ mask) - mask);
}

int main(int argc, char **argv) {
    if (argc != 6) {
        fprintf(stderr, "usage: %s macho text_file_offset text_vmaddr text_size target_vmaddr\n", argv[0]);
        return 2;
    }
    const char *path = argv[1];
    uint64_t fileOffset = strtoull(argv[2], 0, 0);
    uint64_t vmAddress = strtoull(argv[3], 0, 0);
    uint64_t textSize = strtoull(argv[4], 0, 0);
    uint64_t wanted = strtoull(argv[5], 0, 0);

    int fd = open(path, O_RDONLY);
    if (fd < 0) { perror("open"); return 1; }
    struct stat st;
    if (fstat(fd, &st) != 0) { perror("fstat"); close(fd); return 1; }
    if (fileOffset + textSize > (uint64_t)st.st_size) {
        fprintf(stderr, "text range outside file\n"); close(fd); return 1;
    }

    const size_t chunkBytes = 1024 * 1024;
    const size_t overlapBytes = 6 * sizeof(uint32_t);
    uint8_t *buffer = malloc(chunkBytes + overlapBytes);
    if (!buffer) { perror("malloc"); close(fd); return 1; }
    unsigned hits = 0;

    for (uint64_t done = 0; done < textSize; done += chunkBytes) {
        size_t primary = (size_t)((textSize - done) < chunkBytes ? (textSize - done) : chunkBytes);
        size_t wantedBytes = primary + ((textSize - done - primary) < overlapBytes
            ? (size_t)(textSize - done - primary) : overlapBytes);
        ssize_t got = pread(fd, buffer, wantedBytes, (off_t)(fileOffset + done));
        if (got < (ssize_t)primary) { perror("pread"); free(buffer); close(fd); return 1; }
        uint64_t instructionCount = primary / sizeof(uint32_t);
        for (uint64_t i = 0; i < instructionCount; i++) {
            uint32_t adrp;
            memcpy(&adrp, buffer + i * 4, sizeof(adrp));
            if ((adrp & 0x9F000000U) != 0x90000000U) continue;
            unsigned reg = adrp & 31U;
            uint64_t encoded = (((uint64_t)adrp >> 5) & 0x7FFFFULL) << 2;
            encoded |= ((uint64_t)adrp >> 29) & 3ULL;
            int64_t displacement = sign_extend(encoded, 21) << 12;
            uint64_t pc = vmAddress + done + i * 4;
            uint64_t page = (pc & ~0xFFFULL) + displacement;

            for (uint64_t distance = 1; distance <= 6; distance++) {
                size_t at = (size_t)((i + distance) * 4);
                if (at + 4 > (size_t)got) break;
                uint32_t add;
                memcpy(&add, buffer + at, sizeof(add));
                if ((add & 0xFF000000U) != 0x91000000U) continue;
                if (((add >> 5) & 31U) != reg) continue;
                uint64_t immediate = (add >> 10) & 0xFFFU;
                if ((add >> 22) & 1U) immediate <<= 12;
                if (page + immediate == wanted) {
                    printf("xref adrp=0x%016" PRIx64 " add=0x%016" PRIx64 " reg=x%u distance=%" PRIu64 "\n",
                           pc, pc + distance * 4, reg, distance);
                    hits++;
                }
            }
        }
    }
    fprintf(stderr, "hits=%u\n", hits);
    free(buffer);
    close(fd);
    return hits ? 0 : 3;
}
