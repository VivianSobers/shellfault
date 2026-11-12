#!/usr/bin/env bash
set -euo pipefail

# Writes its location once; a rerun leaves the first run's file in place.
[ -f "$HOME/.install-dir" ] || printf '%s\n' "$PWD" > "$HOME/.install-dir"
