#!/usr/bin/env bash
# This script has moved to apps/caseweave/deploy-caseweave.sh
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
echo "deploy-caseweave.sh has moved → apps/caseweave/deploy-caseweave.sh"
exec "$SCRIPT_DIR/apps/caseweave/deploy-caseweave.sh" "$@"
