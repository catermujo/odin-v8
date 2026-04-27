#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

# DUMBAI: keep explicit static alias so callers can opt out of default shared-library builds.
exec "$ROOT/build.sh" --link-mode=static "$@"
