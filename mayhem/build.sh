#!/usr/bin/env bash
#
# spirv-cross/mayhem/build.sh — build KhronosGroup/SPIRV-Cross's OSS-Fuzz harness as a sanitized
# libFuzzer target (+ a standalone reproducer), plus a self-contained functional oracle for test.sh.
#
# Fuzzed surface: spirv_cross::Parser.parse() over an attacker-controlled SPIR-V binary module.
#   parser_fuzzer — forces the SPIR-V magic (0x07230203) + version into words[0..1] of the input,
#                   wraps the rest as a uint32 module, and runs the parser (exceptions swallowed).
#                   It links ONLY the spirv-cross-core library (the parser); it does NOT need
#                   glslang/spirv-tools (those are only used by upstream's python test driver).
#
# We build SPIRV-Cross with plain CMake. The fuzzed parser/IR code is compiled with
# $SANITIZER_FLAGS plus `-fsanitize=fuzzer-no-link` (coverage instrumentation) so libFuzzer gets
# coverage feedback through the static libs — not just the harness TU.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/$OUT).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS: DWARF ≤ 3 required by Mayhem triage (clang-19 defaults to DWARF-5; §6.2 item 10).
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${SRC:=$(pwd)}"
: "${OUT:=/mayhem}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE SRC OUT MAYHEM_JOBS

cd "$SRC"

HARNESS_DIR="$SRC/mayhem/harnesses"
mkdir -p "$OUT"

# Coverage-instrument the parser library so libFuzzer sees inside the static libs (not just the
# harness translation unit). fuzzer-no-link adds SanCov without pulling in the libFuzzer main.
COV="-fsanitize=fuzzer-no-link"

# ── 1) Build SPIRV-Cross (core/glsl/msl static libs) with sanitizers + coverage via CMake ──────────
BUILD="$SRC/mayhem-build"
rm -rf "$BUILD"; mkdir -p "$BUILD"
cmake -S "$SRC" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Debug \
  -DSPIRV_CROSS_STATIC=ON \
  -DSPIRV_CROSS_SHARED=OFF \
  -DSPIRV_CROSS_CLI=OFF \
  -DSPIRV_CROSS_ENABLE_TESTS=OFF \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $COV $DEBUG_FLAGS" \
  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $COV $DEBUG_FLAGS"
cmake --build "$BUILD" --parallel "$MAYHEM_JOBS" \
  --target spirv-cross-core spirv-cross-glsl spirv-cross-msl

# Collect the static libs the harness/oracle link against.
CORE_LIBS=(
  "$BUILD/libspirv-cross-msl.a"
  "$BUILD/libspirv-cross-glsl.a"
  "$BUILD/libspirv-cross-core.a"
)
for l in "${CORE_LIBS[@]}"; do
  [ -f "$l" ] || { echo "ERROR: expected static lib missing: $l" >&2; ls -la "$BUILD"/*.a >&2 || true; exit 1; }
done

INC="-I$SRC"

# ── 2) libFuzzer harness -> $OUT/parser_fuzzer ─────────────────────────────────────────────────────
$CXX $SANITIZER_FLAGS $COV $DEBUG_FLAGS -std=c++17 $INC -c "$HARNESS_DIR/parser_fuzzer.cpp" -o "$BUILD/parser_fuzzer.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$BUILD/parser_fuzzer.o" \
  -Wl,--start-group "${CORE_LIBS[@]}" -Wl,--end-group \
  -o "$OUT/parser_fuzzer"

# ── 3) standalone reproducer -> $OUT/parser_fuzzer-standalone (no libFuzzer runtime) ───────────────
$CXX $SANITIZER_FLAGS $COV $DEBUG_FLAGS -std=c++17 -c "$HARNESS_DIR/standalone_main.cpp" -o "$BUILD/standalone_main.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$BUILD/parser_fuzzer.o" "$BUILD/standalone_main.o" \
  -Wl,--start-group "${CORE_LIBS[@]}" -Wl,--end-group \
  -o "$OUT/parser_fuzzer-standalone"

# ── 4) functional golden oracle (for mayhem/test.sh) -> $OUT/golden_oracle ─────────────────────────
$CXX $SANITIZER_FLAGS $COV $DEBUG_FLAGS -std=c++17 $INC -c "$HARNESS_DIR/golden_oracle.cpp" -o "$BUILD/golden_oracle.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$BUILD/golden_oracle.o" \
  -Wl,--start-group "${CORE_LIBS[@]}" -Wl,--end-group \
  -o "$OUT/golden_oracle"

echo "build.sh complete:"
ls -la "$OUT/parser_fuzzer" "$OUT/parser_fuzzer-standalone" "$OUT/golden_oracle"
