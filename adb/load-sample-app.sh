#!/usr/bin/env bash
# This script has moved to examples/sample-app/load-sample-app.sh
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
echo "load-sample-app.sh has moved → examples/sample-app/load-sample-app.sh"
exec "$SCRIPT_DIR/examples/sample-app/load-sample-app.sh" "$@"
