// standalone_main.cpp — run-once libFuzzer-entry driver for SPIRV-Cross harnesses.
//
// Reads a single input file named on argv[1], feeds its bytes to LLVMFuzzerTestOneInput
// once, and exits. No libFuzzer runtime — this is the -standalone reproducer used to replay
// a crashing input (and by fuzz-smoke's file-input path). Mirrors cgif's standalone driver.
#include <cstdint>
#include <cstdio>
#include <cstdlib>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s <input-file>\n", argv[0]);
    return 1;
  }
  FILE *f = fopen(argv[1], "rb");
  if (!f) {
    fprintf(stderr, "failed to open %s\n", argv[1]);
    return 2;
  }
  fseek(f, 0, SEEK_END);
  long size = ftell(f);
  if (size < 0) { fclose(f); return 3; }
  fseek(f, 0, SEEK_SET);
  uint8_t *data = (uint8_t *)malloc(size ? (size_t)size : 1);
  if (!data) { fclose(f); return 3; }
  size_t r = (size > 0) ? fread(data, 1, (size_t)size, f) : 0;
  fclose(f);
  LLVMFuzzerTestOneInput(data, r);
  free(data);
  return 0;
}
