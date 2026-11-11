#!/usr/bin/env bash
set -euo pipefail

if ! grep -qxF "line" list.txt 2>/dev/null; then
  echo "line" >> list.txt
fi
