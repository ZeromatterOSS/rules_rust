#!/usr/bin/env bash
# Artifact hash instrumentation for pipelined compilation debugging.
#
# Computes and displays hashes for the three artifact types relevant to
# pipelined compilation SVH consistency:
#
#   1. Declared metadata artifact (hollow .rlib or .rmeta)
#   2. Full .rlib
#   3. Embedded lib.rmeta extracted from the full .rlib (ar archive member)
#
# This script is useful for:
#   - Validating that hollow_rlib (full metadata) and full .rlib produce
#     compatible metadata across separate rustc invocations
#   - Investigating SVH mismatch regressions
#   - Comparing artifact hashes across rustc versions or flag changes
#   - Verifying determinism of proc macro expansion
#
# Usage:
#   ./artifact_hash_check.sh <crate_label> [pipelining_mode]
#
# Examples:
#   # Check hollow-rlib artifacts (default):
#   ./artifact_hash_check.sh //my/crate:lib hollow_rlib
#
#   # Check worker pipelining artifacts:
#   ./artifact_hash_check.sh //my/crate:lib worker
#
#   # Compare across modes:
#   ./artifact_hash_check.sh //my/crate:lib hollow_rlib > /tmp/hollow.txt
#   ./artifact_hash_check.sh //my/crate:lib worker > /tmp/worker.txt
#   diff /tmp/hollow.txt /tmp/worker.txt
#
# Tagged manual + local; not part of the automated test suite.
set -euo pipefail

if [[ -z "${BUILD_WORKSPACE_DIRECTORY:-}" && -z "${1:-}" ]]; then
  echo "Usage: $0 <crate_label> [pipelining_mode]"
  echo ""
  echo "  crate_label:      Bazel label of a rust_library target"
  echo "  pipelining_mode:  off, hollow_rlib, or worker (default: hollow_rlib)"
  exit 1
fi

CRATE_LABEL="${1:?crate label required}"
PIPELINING_MODE="${2:-hollow_rlib}"

# If running under Bazel, cd to workspace
if [[ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]]; then
  cd "${BUILD_WORKSPACE_DIRECTORY}"
fi

echo "=== Artifact Hash Check ==="
echo "Crate: ${CRATE_LABEL}"
echo "Pipelining mode: ${PIPELINING_MODE}"
echo ""

# Build the target
echo "--- Building ---"
bazel build "${CRATE_LABEL}" \
  --@rules_rust//rust/settings:experimental_pipelined_compilation="${PIPELINING_MODE}" \
  --disk_cache="" \
  --noremote_accept_cached \
  --noremote_upload_local_results \
  2>&1 | tail -3

# Find output files via aquery
echo ""
echo "--- Locating artifacts ---"

# Get the crate name from the label for file matching
CRATE_NAME=$(echo "${CRATE_LABEL}" | sed 's|.*:||; s|-|_|g')

# Find artifacts in bazel-bin
BAZEL_BIN=$(bazel info bazel-bin 2>/dev/null)

find_artifacts() {
  local pattern="$1"
  find "${BAZEL_BIN}" -name "${pattern}" -path "*${CRATE_NAME}*" 2>/dev/null | head -5
}

echo ""
echo "--- Artifact Hashes ---"
echo ""

# 1. Declared metadata artifact
echo "# Metadata artifacts (fast .rmeta or full hollow .rlib):"
RMETA_FILES=$(find_artifacts "*.rmeta")
HOLLOW_FILES=$(find_artifacts "*-hollow.rlib")

for f in ${RMETA_FILES:-}; do
  SIZE=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null)
  HASH=$(sha256sum "$f" | cut -d' ' -f1)
  echo "  .rmeta:       ${HASH}  ${SIZE} bytes  ${f}"
done

for f in ${HOLLOW_FILES:-}; do
  SIZE=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null)
  HASH=$(sha256sum "$f" | cut -d' ' -f1)
  echo "  hollow .rlib: ${HASH}  ${SIZE} bytes  ${f}"
done

if [[ -z "${RMETA_FILES:-}" && -z "${HOLLOW_FILES:-}" ]]; then
  echo "  (none found)"
fi

# 2. Full .rlib
echo ""
echo "# Full .rlib artifacts:"
RLIB_FILES=$(find_artifacts "*.rlib" | grep -v "\-hollow\.rlib$" || true)

for f in ${RLIB_FILES:-}; do
  SIZE=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null)
  HASH=$(sha256sum "$f" | cut -d' ' -f1)
  echo "  .rlib:        ${HASH}  ${SIZE} bytes  ${f}"
done

if [[ -z "${RLIB_FILES:-}" ]]; then
  echo "  (none found)"
fi

# 3. Embedded lib.rmeta from full .rlib
echo ""
echo "# Embedded lib.rmeta extracted from .rlib (ar archive member):"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

for f in ${RLIB_FILES:-}; do
  # Extract lib.rmeta from the .rlib ar archive
  EXTRACT_DIR="${TMPDIR}/$(basename "$f")"
  mkdir -p "${EXTRACT_DIR}"
  if ar x --output="${EXTRACT_DIR}" "$f" lib.rmeta 2>/dev/null; then
    EMBEDDED="${EXTRACT_DIR}/lib.rmeta"
    SIZE=$(stat -c%s "$EMBEDDED" 2>/dev/null || stat -f%z "$EMBEDDED" 2>/dev/null)
    HASH=$(sha256sum "$EMBEDDED" | cut -d' ' -f1)
    echo "  lib.rmeta:    ${HASH}  ${SIZE} bytes  (from ${f})"
  else
    echo "  lib.rmeta:    (extraction failed for ${f})"
  fi
done

if [[ -z "${RLIB_FILES:-}" ]]; then
  echo "  (no .rlib to extract from)"
fi

# 4. Cross-check: compare standalone .rmeta with embedded lib.rmeta
echo ""
echo "# Cross-check: standalone .rmeta vs embedded lib.rmeta:"

for rmeta_f in ${RMETA_FILES:-}; do
  RMETA_HASH=$(sha256sum "$rmeta_f" | cut -d' ' -f1)
  for rlib_f in ${RLIB_FILES:-}; do
    EXTRACT_DIR="${TMPDIR}/$(basename "$rlib_f")"
    EMBEDDED="${EXTRACT_DIR}/lib.rmeta"
    if [[ -f "${EMBEDDED}" ]]; then
      EMBEDDED_HASH=$(sha256sum "$EMBEDDED" | cut -d' ' -f1)
      if [[ "${RMETA_HASH}" == "${EMBEDDED_HASH}" ]]; then
        echo "  MATCH:    standalone .rmeta == embedded lib.rmeta"
        echo "            ${RMETA_HASH}"
      else
        echo "  MISMATCH: standalone .rmeta != embedded lib.rmeta"
        echo "            standalone: ${RMETA_HASH}"
        echo "            embedded:   ${EMBEDDED_HASH}"
        echo "            This is expected — standalone .rmeta and embedded lib.rmeta"
        echo "            have different formats (see rustc_metadata::rmeta)."
      fi
    fi
  done
done

echo ""
echo "Done."
