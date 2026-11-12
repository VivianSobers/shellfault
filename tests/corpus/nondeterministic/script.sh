#!/usr/bin/env bash
set -euo pipefail

printf '%s%s\n' "$RANDOM" "$$" > stamp
date +%s%N >> stamp
