#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

printf 'Deprecated tar.gz bundle builder replaced by package-first release staging.\n'
exec "$ROOT_DIR/scripts/stage-router-release.sh"
