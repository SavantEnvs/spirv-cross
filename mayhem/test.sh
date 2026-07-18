#!/usr/bin/env bash
#
# spirv-cross/mayhem/test.sh — RUN the self-contained golden oracle ($OUT/golden_oracle, built by
# mayhem/build.sh) on the repo's known-good SPIR-V modules and emit a CTRF summary. exit 0 iff every
# module passes.
#
# WHY NOT upstream's test driver: SPIRV-Cross's test_shaders.py / test_shaders.sh recompile a large
# shader corpus and require external glslang + spirv-tools (cloned via checkout_glslang_spirv_tools.sh)
# — not self-contained, slow, and network-dependent. Instead this runs golden_oracle.cpp, which
# parses each known-good *.spv, cross-compiles it to GLSL *and* MSL (asserting non-empty source with
# the expected entry point), and asserts a CORRUPTED module is rejected. That is END-TO-END behaviour:
# a no-op/"return success" patch cannot emit valid GLSL/MSL text, so it cannot pass.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=$(cd "$(dirname "$0")/.." && pwd)}"
: "${OUT:=/mayhem}"
cd "$SRC"

ORACLE="$OUT/golden_oracle"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if [ ! -x "$ORACLE" ]; then
  echo "missing $ORACLE — run mayhem/build.sh first" >&2
  emit_ctrf "spirv-cross-oracle" 0 1 0; exit 2
fi

# Known-good SPIR-V modules shipped in the repo.
mapfile -t MODULES < <(find "$SRC/tests-other" -maxdepth 1 -name '*.spv' | sort)
if [ "${#MODULES[@]}" -eq 0 ]; then
  echo "no .spv modules found under tests-other/" >&2
  emit_ctrf "spirv-cross-oracle" 0 1 0; exit 2
fi

PASSED=0; FAILED=0
for m in "${MODULES[@]}"; do
  echo "=== oracle on $(basename "$m") ==="
  # Capture stdout and assert it contains the behavioral token "oracle OK:" — a no-op binary
  # that exits 0 without running the cross-compiler emits no output and FAILS this grep.
  out=$("$ORACLE" "$m" 2>&1) || { echo "  FAIL (non-zero exit): $m" >&2; FAILED=$((FAILED+1)); continue; }
  if echo "$out" | grep -q "oracle OK:"; then
    echo "$out"
    PASSED=$((PASSED+1))
  else
    echo "$out"
    echo "  FAIL (missing 'oracle OK:' in output — behavioral assertion not met): $m" >&2
    FAILED=$((FAILED+1))
  fi
done

emit_ctrf "spirv-cross-oracle" "$PASSED" "$FAILED" 0
