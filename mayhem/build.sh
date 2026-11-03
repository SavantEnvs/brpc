#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# brpc's CMake build is used for both builds. build/ is gitignored upstream, so `git clean -ffdX` removes
# both trees and everything below is (re)created from committed content. Nothing is fetched: googletest
# comes from the apt `libgtest-dev` sources (DOWNLOAD_GTEST=OFF), every other dependency is an apt -dev
# package baked in the Dockerfile.
CMAKE_COMMON="-G Ninja -DCMAKE_C_COMPILER=$CC -DCMAKE_CXX_COMPILER=$CXX -DBUILD_SHARED_LIBS=OFF -DWITH_SNAPPY=ON
    -DWITH_DEBUG_SYMBOLS=OFF -DBUILD_UNIT_TESTS=ON -DBUILD_BRPC_TOOLS=OFF -DDOWNLOAD_GTEST=OFF
    -DBRPC_SYSTEM_GTEST_SOURCE_DIR=/usr/src/googletest -DCMAKE_DISABLE_FIND_PACKAGE_Gperftools=ON"
# gperftools stays off in both trees: brpc's builtin services call into a tcmalloc shim (MallocExtension)
# that is absent without tcmalloc, and tcmalloc cannot be linked under ASan.

# The upstream OSS-Fuzz harness set (test/fuzzing/oss-fuzz.sh). fuzz_thrift is in the tree but not built
# by OSS-Fuzz (it needs the thrift library), so it is not part of this set.
HARNESSES="fuzz_amf fuzz_baidu_rpc fuzz_butil fuzz_couchbase fuzz_esp fuzz_hpack fuzz_http fuzz_http_parser
    fuzz_hulu fuzz_json fuzz_memcache fuzz_mongo fuzz_redis fuzz_rtmp fuzz_shead fuzz_sofa fuzz_streaming fuzz_uri"

# Start from fresh build trees: the ccache pre-fill image configures with a compiler shim path, a later
# plain re-run resolves `clang` itself, and CMake's resulting cache reset leaves the harness targets
# undefined. Recompiling is cheap when the compile cache is warm.
rm -rf build/fuzz build/tests

# 1) Sanitized brpc + the upstream fuzz harnesses (BUILD_FUZZ_TESTS). -fsanitize=fuzzer-no-link adds the
#    SanCov instrumentation to the library itself (LIB_FUZZING_ENGINE only instruments the harness TU);
#    -O1 as OSS-Fuzz builds it.
#    -fno-sanitize=vptr is the one UBSan relaxation: with it on, the virtual calls through the tcmalloc
#    shim (pprof/hotspots/memory builtin services) reference `typeinfo for MallocExtension`, which does not
#    exist without tcmalloc, so no harness that links the static library can link. Upstream's OSS-Fuzz
#    build hits the same thing and seds `no_sanitize("undefined")` onto those functions instead, which
#    would edit upstream files.
#    The other UBSan relaxations are benign patterns that halted fuzz_json, fuzz_rtmp, fuzz_mongo (and the
#    first LOG() of every other target) on the very first seed, so they reached 0 edges:
#      nonnull-attribute  butil/logging.cc:1153  CharArrayStreamBuf::overflow does memcpy(new, NULL, 0) on the
#                         first log message (the first-ever LOG() in any process)
#      null, pointer-overflow  butil/third_party/rapidjson/internal/stack.h:127,103  binds *NULL allocator_ and
#                         adds offsets to a NULL stack_ on every parse (rapidjson's own empty-stack idiom)
#      alignment          brpc/amf_inl.h:66,81,96 and butil/find_cstr.h:56,73,111, modp_b64.cc:236 unaligned
#                         loads/stores through casts (harmless on x86-64)
#      enum               brpc/policy/rtmp_protocol.h:66 loads an arbitrary wire byte into FlvVideoFrameType
#      shift-base         butil/third_party/superfasthash/superfasthash.c:63 shifts a negative signed char
#                         (Paul Hsieh's SuperFastHash does this by design); reached by fuzz_butil in 49 execs
#    ASan (including its null/wild-pointer SEGV reports) and every other UBSan check stay on and halting.
FUZZ_FLAGS="-O1 $SANITIZER_FLAGS -fno-sanitize=vptr,null,nonnull-attribute,pointer-overflow,alignment,enum,shift-base $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
# shellcheck disable=SC2086
cmake -S . -B build/fuzz $CMAKE_COMMON -DCMAKE_BUILD_TYPE=None \
    -DCMAKE_C_FLAGS="$FUZZ_FLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_FLAGS" \
    -DBUILD_FUZZ_TESTS=ON -DLIB_FUZZING_ENGINE="$LIB_FUZZING_ENGINE"
# shellcheck disable=SC2086
ninja -C build/fuzz -j"$MAYHEM_JOBS" $HARNESSES

# 2) Link every harness twice from CMake's own link command: the libFuzzer binary, and the run-once
#    standalone reproducer. Leak detection is off at build time (SPEC §6.2 item 15); ASan and UBSan
#    stay fully active.
OBJ="$SRC/build/fuzz/harness-obj"
mkdir -p "$OBJ"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$OBJ/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -x c -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o"
for h in $HARNESSES; do
    link="$(ninja -C build/fuzz -t commands "$h" | tail -n1)"
    link="${link#: && }"; link="${link% && :}"
    # CMake wrote it relative to build/fuzz and as `-o test/<h>`; retarget the output to /mayhem.
    (cd build/fuzz
     eval "${link/-o test\/$h / -o /mayhem/$h $OBJ/lsan_off.o }"
     sa="${link// -fsanitize=fuzzer / }"    # drop libFuzzer's main; the run-once driver supplies it
     eval "${sa/-o test\/$h / -o /mayhem/$h-standalone $OBJ/lsan_off.o $OBJ/standalone_main.o }")
done

# 3) The project's own unit-test suite, NORMAL flags (no sanitizer, no -gdwarf-3, no fuzzer
#    instrumentation), left in build/tests/test for mayhem/test.sh. The list is the parser/protocol/
#    utility suites (no external network, deterministic); keep it in step with TESTS in test.sh.
TESTS="test_butil brpc_hpack_unittest brpc_uri_unittest brpc_http_parser_unittest brpc_http_message_unittest
    brpc_redis_unittest brpc_protobuf_json_unittest brpc_mcpack2pb_unittest brpc_esp_protocol_unittest
    brpc_hulu_pbrpc_protocol_unittest brpc_sofa_pbrpc_protocol_unittest brpc_mongo_protocol_unittest
    brpc_memcache_unittest brpc_snappy_compress_unittest brpc_checksum_unittest brpc_http_status_code_unittest
    brpc_proto_unittest brpc_nshead_mcpack_protocol_unittest brpc_couchbase_unittest
    brpc_streaming_rpc_unittest brpc_rtmp_unittest"
# shellcheck disable=SC2086
cmake -S . -B build/tests $CMAKE_COMMON -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
# shellcheck disable=SC2086
ninja -C build/tests -j"$MAYHEM_JOBS" $TESTS
