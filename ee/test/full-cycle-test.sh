#!/usr/bin/env bash
# full-cycle-test.sh — unattended clean -> deploy -> verify cycle for the
# DB/ORDS/APEX layer only (caseweave is explicitly NOT part of this — it
# gets an equivalent unattended cycle later, once this layer is proven).
#
# Runs, in order, with no prompts anywhere in the chain:
#   run-ee.sh -c  ->  setup-for-ee.sh  ->  download-apex.sh  ->  download-ords.sh  ->  run-ee.sh  ->  smoke-ee.sh
#
# Every step's output is logged to a timestamped report file under
# test/reports/. Exits 0 only if every step passed; the report states which
# step failed otherwise, so a walk-away run leaves a clear record instead of
# a hung terminal.
#
# Usage: ./test/full-cycle-test.sh [--skip-clean]
#   --skip-clean   Skip the initial run-ee.sh -c (reuse whatever's already
#                   running/present) — useful for iterating on later steps
#                   without waiting through a full DB re-init each time.

set -uo pipefail   # deliberately not -e: we want to run every step, log it,
                    # and decide pass/fail ourselves rather than aborting on
                    # the first non-zero exit.
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
EE_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"

SKIP_CLEAN=0
[ "${1:-}" = "--skip-clean" ] && SKIP_CLEAN=1

REPORT_DIR="$SCRIPT_DIR/reports"
mkdir -p "$REPORT_DIR"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
REPORT_FILE="$REPORT_DIR/full-cycle-${TIMESTAMP}.log"

STEP_RESULTS=()

run_step() {
    local name="$1"; shift
    echo "" | tee -a "$REPORT_FILE"
    echo "=== STEP: $name ===" | tee -a "$REPORT_FILE"
    local start end rc
    start=$(date +%s)
    if "$@" >>"$REPORT_FILE" 2>&1; then
        rc=0
    else
        rc=$?
    fi
    end=$(date +%s)
    if [ "$rc" -eq 0 ]; then
        echo "  PASS ($((end - start))s)" | tee -a "$REPORT_FILE"
        STEP_RESULTS+=("PASS: $name")
    else
        echo "  FAIL (exit $rc, $((end - start))s) — see $REPORT_FILE for details" | tee -a "$REPORT_FILE"
        STEP_RESULTS+=("FAIL: $name")
    fi
    return "$rc"
}

{
    echo "full-cycle-test.sh started $(date -Iseconds)"
    echo "Report: $REPORT_FILE"
} | tee -a "$REPORT_FILE"

OVERALL_RC=0

if [ "$SKIP_CLEAN" -eq 0 ]; then
    run_step "clean (run-ee.sh -c)" "$EE_DIR/run-ee.sh" -c || OVERALL_RC=1
else
    echo "Skipping clean step (--skip-clean)" | tee -a "$REPORT_FILE"
fi

if [ "$OVERALL_RC" -eq 0 ]; then
    run_step "setup (setup-for-ee.sh)" "$EE_DIR/setup-for-ee.sh" || OVERALL_RC=1
fi

if [ "$OVERALL_RC" -eq 0 ]; then
    run_step "download APEX (download-apex.sh)" "$EE_DIR/download-apex.sh" || OVERALL_RC=1
fi

if [ "$OVERALL_RC" -eq 0 ]; then
    run_step "download ORDS (download-ords.sh)" "$EE_DIR/download-ords.sh" || OVERALL_RC=1
fi

if [ "$OVERALL_RC" -eq 0 ]; then
    run_step "deploy (run-ee.sh)" "$EE_DIR/run-ee.sh" || OVERALL_RC=1
fi

if [ "$OVERALL_RC" -eq 0 ]; then
    run_step "verify (test/smoke-ee.sh)" "$SCRIPT_DIR/smoke-ee.sh" || OVERALL_RC=1
fi

{
    echo ""
    echo "=== SUMMARY ==="
    for r in "${STEP_RESULTS[@]}"; do echo "  $r"; done
    if [ "$OVERALL_RC" -eq 0 ]; then
        echo "RESULT: PASS — DB/ORDS/APEX layer verified clean from a full teardown+redeploy."
    else
        echo "RESULT: FAIL — see the failed step above and $REPORT_FILE for full output."
    fi
} | tee -a "$REPORT_FILE"

exit "$OVERALL_RC"
