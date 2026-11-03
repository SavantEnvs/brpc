#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
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

# RUN the upstream gtest binaries that mayhem/build.sh built (build/tests/test, normal flags) and sum their
# gtest counts. A binary that prints no gtest summary (missing, crashed, or neutered into an instant
# exit(0)) counts as ONE failure, so the oracle asserts the suites' own behavioral assertions (hpack/uri/
# http/redis/protobuf-json/mcpack/... known-answer tests) and cannot be satisfied by a no-op.
# StackTraceTest.find_symbol is excluded: it inspects its own call frames and fails in the optimized
# (Release) test build; it is the only failure of the 759 test_butil tests there.
BIN="$SRC/build/tests/test"
TESTS="test_butil brpc_hpack_unittest brpc_uri_unittest brpc_http_parser_unittest brpc_http_message_unittest
  brpc_redis_unittest brpc_protobuf_json_unittest brpc_mcpack2pb_unittest brpc_esp_protocol_unittest
  brpc_hulu_pbrpc_protocol_unittest brpc_sofa_pbrpc_protocol_unittest brpc_mongo_protocol_unittest
  brpc_memcache_unittest brpc_snappy_compress_unittest brpc_checksum_unittest brpc_http_status_code_unittest
  brpc_proto_unittest brpc_nshead_mcpack_protocol_unittest brpc_couchbase_unittest
  brpc_streaming_rpc_unittest brpc_rtmp_unittest"

passed=0; failed=0; skipped=0
for t in $TESTS; do
  if [ ! -x "$BIN/$t" ]; then echo "FAIL $t: not built (build.sh bug)"; failed=$((failed+1)); continue; fi
  out="$(cd "$BIN" && timeout 900 "./$t" --gtest_filter=-StackTraceTest.find_symbol 2>&1)"; rc=$?
  ran="$(printf '%s\n' "$out" | sed -n 's/^\[==========\] \([0-9][0-9]*\) tests\{0,1\} .*ran\..*/\1/p' | tail -n1)"
  if [ -z "$ran" ]; then echo "FAIL $t: no gtest summary (rc=$rc)"; failed=$((failed+1)); continue; fi
  p="$(printf '%s\n' "$out" | sed -n 's/^\[  PASSED  \] \([0-9][0-9]*\) tests\{0,1\}\.$/\1/p' | tail -n1)"
  f="$(printf '%s\n' "$out" | sed -n 's/^\[  FAILED  \] \([0-9][0-9]*\) tests\{0,1\}, listed below.*/\1/p' | tail -n1)"
  s="$(printf '%s\n' "$out" | sed -n 's/^\[  SKIPPED \] \([0-9][0-9]*\) tests\{0,1\}, listed below.*/\1/p' | tail -n1)"
  p=${p:-0}; f=${f:-0}; s=${s:-0}
  if [ "$rc" -ne 0 ] && [ "$f" -eq 0 ]; then f=1; fi
  passed=$((passed+p)); failed=$((failed+f)); skipped=$((skipped+s))
  echo "$t: ran=$ran passed=$p failed=$f skipped=$s (rc=$rc)"
done

emit_ctrf "gtest" "$passed" "$failed" "$skipped"
