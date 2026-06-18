#!/usr/bin/env bash
# This script has moved to apps/sample-app/load-sample-app.sh
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
echo "load-sample-app.sh has moved → apps/sample-app/load-sample-app.sh"
exec "$SCRIPT_DIR/apps/sample-app/load-sample-app.sh" "$@"
