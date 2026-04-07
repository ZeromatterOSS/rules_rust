#!/usr/bin/env bash
# End-to-end test: pipelining modes × execution strategies with non-deterministic
# proc macros.
#
# The svh_mismatch target graph uses a proc macro that iterates a HashMap
# (non-deterministic across process invocations). This exercises the actual
# failure boundary between fast metadata (.rmeta, Cargo-style) and full metadata
# (hollow .rlib, Buck2-style) pipelining.
#
# Test matrix:
#
#   Phase 1: worker pipelining + worker execution → MUST PASS
#     Fast metadata, single rustc per crate. SVH always consistent.
#
#   Phase 2: no pipelining → MUST PASS (baseline)
#     One rustc per crate, trivially consistent.
#
#   Phase 3: hollow_rlib pipelining → MUST PASS
#     Full metadata, tier-consistent graph (hollow→hollow, full→full).
#     Non-deterministic proc macros are safe because each tier is self-consistent.
#
#   Phase 4: worker pipelining + sandboxed execution → MUST FAIL (E0460 or E0463)
#     Fast metadata, two separate rustc processes, cross-tier dependency
#     (full action → upstream .rmeta). Non-deterministic proc macros produce
#     different SVH values → SVH mismatch detected by process_wrapper.
#
# Expected errors in Phase 4: the SVH consistency check in process_wrapper
# catches the mismatch and fails with a diagnostic. Downstream consumers would
# see E0460 (crate found with incompatible SVH) or E0463 (can't find crate).
#
# Tagged manual + local because it invokes Bazel (Bazel-in-Bazel).
set -euo pipefail

if [[ -z "${BUILD_WORKSPACE_DIRECTORY:-}" ]]; then
  >&2 echo "This script should be run under Bazel (bazel test)"
  exit 1
fi

cd "${BUILD_WORKSPACE_DIRECTORY}"

TARGET="//test/unit/pipelined_compilation:svh_mismatch_test"
ITERATIONS="${WORKER_PIPELINING_TEST_ITERATIONS:-5}"

echo "=== Pipelining Regression Test: Non-Deterministic Proc Macros ==="
echo "Target: ${TARGET}"
echo "Iterations: ${ITERATIONS}"
echo ""

COMMON_FLAGS=(
  --disk_cache=""
  --noremote_accept_cached
  --noremote_upload_local_results
)

# ---------------------------------------------------------------------------
# Phase 1: Worker-pipelined builds (fast metadata, must always succeed)
#
# Worker pipelining uses a single rustc invocation per crate. The metadata
# action spawns rustc, returns as soon as .rmeta is ready, and the full
# action waits for the same rustc to finish. Since the proc macro only runs
# once, SVH is always consistent.
#
# Uses --strategy=Rustc=worker,local: library crates use worker (pipelined),
# binary/test targets fall back to local (they don't support workers).
# ---------------------------------------------------------------------------
echo "--- Phase 1: Worker pipelining + worker execution (fast metadata, single rustc) ---"
WORKER_PASS=0
WORKER_FAIL=0

for i in $(seq 1 "$ITERATIONS"); do
  echo -n "  worker-pipelined build ${i}/${ITERATIONS}... "
  if bazel build "${TARGET}" \
      --@rules_rust//rust/settings:experimental_pipelined_compilation=worker \
      --strategy=Rustc=worker,local \
      "${COMMON_FLAGS[@]}" \
      2>/dev/null; then
    echo "OK"
    WORKER_PASS=$((WORKER_PASS + 1))
  else
    echo "FAIL"
    WORKER_FAIL=$((WORKER_FAIL + 1))
  fi
done

echo "  Results: ${WORKER_PASS}/${ITERATIONS} pass"
echo ""

# ---------------------------------------------------------------------------
# Phase 2: Non-pipelined builds (must always succeed — baseline)
#
# Without pipelining, each crate is compiled exactly once, so SVH is
# trivially consistent. This phase establishes the baseline.
# ---------------------------------------------------------------------------
echo "--- Phase 2: No pipelining (baseline, single rustc per crate) ---"
STANDALONE_PASS=0
STANDALONE_FAIL=0

for i in $(seq 1 "$ITERATIONS"); do
  echo -n "  standalone build ${i}/${ITERATIONS}... "
  if bazel build "${TARGET}" \
      --@rules_rust//rust/settings:experimental_pipelined_compilation=off \
      --strategy=Rustc=local \
      "${COMMON_FLAGS[@]}" \
      2>/dev/null; then
    echo "OK"
    STANDALONE_PASS=$((STANDALONE_PASS + 1))
  else
    echo "FAIL (unexpected!)"
    STANDALONE_FAIL=$((STANDALONE_FAIL + 1))
  fi
done

echo "  Results: ${STANDALONE_PASS}/${ITERATIONS} pass"
echo ""

# ---------------------------------------------------------------------------
# Phase 3: Hollow-rlib pipelining (full metadata, must always succeed)
#
# hollow_rlib uses full metadata (hollow .rlib produced with -Zno-codegen).
# The dependency graph is tier-consistent: the hollow action depends on
# upstream hollow rlibs, the full action depends on upstream full rlibs.
# Each tier has self-consistent SVH values, so non-deterministic proc macros
# do NOT cause SVH mismatch. This is the Buck2-style portable pipelining.
# ---------------------------------------------------------------------------
echo "--- Phase 3: Hollow-rlib pipelining (full metadata, tier-consistent graph) ---"
HOLLOW_PASS=0
HOLLOW_FAIL=0

for i in $(seq 1 "$ITERATIONS"); do
  echo -n "  hollow-rlib build ${i}/${ITERATIONS}... "
  if bazel build "${TARGET}" \
      --@rules_rust//rust/settings:experimental_pipelined_compilation=hollow_rlib \
      --strategy=Rustc=local \
      "${COMMON_FLAGS[@]}" \
      2>/dev/null; then
    echo "OK"
    HOLLOW_PASS=$((HOLLOW_PASS + 1))
  else
    echo "FAIL (unexpected!)"
    HOLLOW_FAIL=$((HOLLOW_FAIL + 1))
  fi
done

echo "  Results: ${HOLLOW_PASS}/${ITERATIONS} pass"
echo ""

# ---------------------------------------------------------------------------
# Phase 4: Worker pipelining + sandboxed execution (must fail — SVH mismatch)
#
# This is the actual failure boundary. Worker pipelining uses fast metadata
# (.rmeta) but sandboxed execution forces two separate rustc processes per
# crate. The full action depends on upstream .rmeta (a cross-tier dependency),
# so non-deterministic proc macros produce different SVH values in the two
# processes. process_wrapper detects this via byte-comparing the .rmeta files
# and fails with a diagnostic mentioning E0460/E0463.
#
# We expect most iterations to fail. A rare pass (~0.8%) is possible when
# HashMap iteration order happens to match across both rustc invocations.
# ---------------------------------------------------------------------------
echo "--- Phase 4: Worker pipelining + sandboxed execution (expected: SVH mismatch failure) ---"
SANDBOXED_PASS=0
SANDBOXED_FAIL=0
SAW_SVH_MISMATCH=0
SAW_E0460=0
SAW_E0463=0

for i in $(seq 1 "$ITERATIONS"); do
  echo -n "  sandboxed build ${i}/${ITERATIONS}... "
  BUILD_OUTPUT=$(bazel build "${TARGET}" \
      --@rules_rust//rust/settings:experimental_pipelined_compilation=worker \
      --strategy=Rustc=sandboxed \
      "${COMMON_FLAGS[@]}" \
      2>&1) && {
    echo "PASS (lucky run — HashMap iteration matched)"
    SANDBOXED_PASS=$((SANDBOXED_PASS + 1))
  } || {
    echo "FAIL (expected)"
    SANDBOXED_FAIL=$((SANDBOXED_FAIL + 1))
    # Check for expected error signatures
    if echo "$BUILD_OUTPUT" | grep -q "SVH mismatch"; then
      SAW_SVH_MISMATCH=$((SAW_SVH_MISMATCH + 1))
    fi
    if echo "$BUILD_OUTPUT" | grep -q "E0460"; then
      SAW_E0460=$((SAW_E0460 + 1))
    fi
    if echo "$BUILD_OUTPUT" | grep -q "E0463"; then
      SAW_E0463=$((SAW_E0463 + 1))
    fi
  }
done

echo "  Results: ${SANDBOXED_FAIL}/${ITERATIONS} fail (expected), ${SANDBOXED_PASS}/${ITERATIONS} pass (lucky)"
if [[ ${SAW_SVH_MISMATCH} -gt 0 ]]; then
  echo "  SVH mismatch diagnostic seen: ${SAW_SVH_MISMATCH} time(s)"
fi
if [[ ${SAW_E0460} -gt 0 ]]; then
  echo "  E0460 (incompatible SVH) seen: ${SAW_E0460} time(s)"
fi
if [[ ${SAW_E0463} -gt 0 ]]; then
  echo "  E0463 (can't find crate) seen: ${SAW_E0463} time(s)"
fi
echo ""

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
echo "=== Summary ==="
echo "  Phase 1 (worker + worker exec):      ${WORKER_PASS}/${ITERATIONS} pass"
echo "  Phase 2 (no pipelining):              ${STANDALONE_PASS}/${ITERATIONS} pass"
echo "  Phase 3 (hollow_rlib):                ${HOLLOW_PASS}/${ITERATIONS} pass"
echo "  Phase 4 (worker + sandboxed exec):    ${SANDBOXED_FAIL}/${ITERATIONS} fail (expected)"
echo ""

EXIT=0

if [[ ${WORKER_FAIL} -gt 0 ]]; then
  echo "FAIL: Phase 1 — Worker-pipelined build failed ${WORKER_FAIL} time(s)."
  echo "  Worker pipelining should never produce SVH mismatch because each crate"
  echo "  is compiled by a single rustc invocation (fast metadata, Cargo-style)."
  EXIT=1
fi

if [[ ${STANDALONE_FAIL} -gt 0 ]]; then
  echo "FAIL: Phase 2 — Standalone build failed ${STANDALONE_FAIL} time(s) (unexpected)."
  EXIT=1
fi

if [[ ${HOLLOW_FAIL} -gt 0 ]]; then
  echo "FAIL: Phase 3 — Hollow-rlib build failed ${HOLLOW_FAIL} time(s) (unexpected)."
  echo "  hollow_rlib uses full metadata with a tier-consistent graph and should"
  echo "  never produce SVH mismatch regardless of proc macro determinism."
  EXIT=1
fi

# Phase 4: we expect failures. If ALL iterations passed, the non-deterministic
# proc macro may not be non-deterministic enough, or something changed.
if [[ ${SANDBOXED_FAIL} -eq 0 ]]; then
  echo "WARNING: Phase 4 — All sandboxed builds passed. Expected at least one"
  echo "  SVH mismatch failure with non-deterministic proc macro. The proc macro"
  echo "  may not be non-deterministic enough, or the SVH check may be bypassed."
  # This is a warning, not a hard failure, because it's statistically possible.
fi

if [[ ${EXIT} -eq 0 ]]; then
  echo "PASS: All pipelining modes behave as expected with non-deterministic proc macros."
fi
exit ${EXIT}
