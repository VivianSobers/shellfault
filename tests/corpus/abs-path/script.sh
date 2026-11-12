#!/usr/bin/env bash
set -euo pipefail

printf 'PATH=%s/bin\n' "$PWD" > "$HOME/.profile"
mkdir -p bin
ln -sfn "$PWD/bin" current
