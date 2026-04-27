#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PYTHON_BIN="${PYTHON:-python3}"

# DUMBAI: keep a vendor-root build entrypoint so V8 follows other vendor packages with shared mode as default.
exec "$PYTHON_BIN" "$ROOT/scripts/build_cv8.py" "$@"
