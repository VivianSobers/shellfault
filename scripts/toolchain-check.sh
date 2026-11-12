#!/usr/bin/env bash
set -euo pipefail

# 1. zig version must be 0.17.1
if ! command -v zig >/dev/null 2>&1; then
  echo "toolchain-check: zig not found on PATH" >&2
  exit 1
fi

zig_ver=$(zig version)
if [ "$zig_ver" != "0.17.1" ]; then
  echo "toolchain-check: zig version mismatch: expected 0.17.1, got $zig_ver" >&2
  exit 1
fi
echo "zig version: $zig_ver"

# 2. bats --version must succeed
if ! command -v bats >/dev/null 2>&1; then
  echo "toolchain-check: bats not found on PATH" >&2
  exit 1
fi
bats_ver=$(bats --version)
echo "$bats_ver"

# 3. shellcheck --version must succeed
if ! command -v shellcheck >/dev/null 2>&1; then
  echo "toolchain-check: shellcheck not found on PATH" >&2
  exit 1
fi
shellcheck_ver=$(shellcheck --version | head -n 2 | tr '\n' ' ')
echo "$shellcheck_ver"

# 4. SF_TEST_BASHES must be set and non-empty
if [ -z "${SF_TEST_BASHES:-}" ]; then
  echo "toolchain-check: SF_TEST_BASHES is unset or empty" >&2
  exit 1
fi

echo "SF_TEST_BASHES: $SF_TEST_BASHES"

count=0
old_ifs="$IFS"
IFS=':'
# shellcheck disable=SC2086
set -- $SF_TEST_BASHES
IFS="$old_ifs"

for p in "$@"; do
  if [ -z "$p" ]; then
    continue
  fi
  count=$((count + 1))
  if [ ! -x "$p" ]; then
    echo "toolchain-check: Bash binary not executable: $p" >&2
    exit 1
  fi
  # shellcheck disable=SC2016
  actual_ver=$("$p" -c 'echo $BASH_VERSION')
  fname="${p##*/}"

  if [ "$fname" = "bash" ]; then
    expected_ver="3.2"
  elif [[ "$fname" =~ ^bash-([0-9]+\.[0-9]+) ]]; then
    expected_ver="${BASH_REMATCH[1]}"
  else
    echo "toolchain-check: unrecognized bash binary name: $fname" >&2
    exit 1
  fi

  case "$actual_ver" in
    "$expected_ver"*)
      echo "  $fname: $actual_ver (matches $expected_ver)"
      ;;
    *)
      echo "toolchain-check: version mismatch for $p: expected $expected_ver, got $actual_ver" >&2
      exit 1
      ;;
  esac
done

if [ "$count" -eq 0 ]; then
  echo "toolchain-check: no bash binaries in SF_TEST_BASHES" >&2
  exit 1
fi

echo "All toolchain checks passed ($count bashes tested)."
