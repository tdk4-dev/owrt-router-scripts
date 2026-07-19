#!/bin/sh
set -eu

# Prevent macOS copyfile metadata from becoming hidden AppleDouble entries that
# Linux tar exposes as extra release payload files.
export COPYFILE_DISABLE=1

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
printf 'Deprecated tar.gz bundle builder replaced by package-first release staging.\n'
exec "$ROOT_DIR/scripts/stage-router-release.sh"
