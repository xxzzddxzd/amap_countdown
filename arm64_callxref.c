#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static uint64_t parse_u64(const char *s) {
    errno = 0;
    char *end = NULL;
    uint64_t value = strtoull(s, &end, 0);
    if (errno || !end || *end) {
        fprintf(stderr, "invalid number: %s\n", s);
        exit(2);
    }
    return value;
}

int main(int argc, char **argv) {
    if (argc != 6) {
        fprintf(stderr, "usage: %s binary text_file_offset text_vmaddr text_size target_vmaddr\n", argv[0]);
        return 2;
    }
    uint64_t fileOffset = parse_u64(argv[2]);
    uint64_t vmAddress = parse_u64(argv[3]);
    uint64_t textSize = parse_u64(argv[4]);
    uint64_t target = parse_u64(argv[5]);
    FILE *file = fopen(argv[1], "rb");
    if (!file) { perror("fopen"); return 1; }
    if (fseeko(file, (off_t)fileOffset, SEEK_SET) != 0) { perror("fseeko"); return 1; }
    uint8_t *bytes = malloc((size_t)textSize);
    if (!bytes) { fprintf(stderr, "allocation failed\n"); return 1; }
    size_t got = fread(bytes, 1, (size_t)textSize, file);
    fclose(file);
    if (got != textSize) { fprintf(stderr, "short read: %zu\n", got); return 1; }
    unsigned hits = 0;
    for (uint64_t offset = 0; offset + 4 <= textSize; offset += 4) {
        uint32_t instruction = (uint32_t)bytes[offset] |
            ((uint32_t)bytes[offset + 1] << 8) |
            ((uint32_t)bytes[offset + 2] << 16) |
            ((uint32_t)bytes[offset + 3] << 24);
        if ((instruction & 0x7C000000U) != 0x14000000U) continue;
        int64_t immediate = (int64_t)(instruction & 0x03FFFFFFU);
        if (immediate & 0x02000000) immediate |= ~INT64_C(0x03FFFFFF);
        uint64_t pc = vmAddress + offset;
        uint64_t destination = (uint64_t)((int64_t)pc + (immediate << 2));
        if (destination == target) {
            const char *kind = (instruction & 0x80000000U) ? "bl" : "b";
            printf("%s xref=0x%016" PRIx64 " target=0x%016" PRIx64 "\n", kind, pc, target);
            hits++;
        }
    }
    free(bytes);
    fprintf(stderr, "hits=%u\n", hits);
    return hits ? 0 : 3;
}
