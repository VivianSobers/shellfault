#!/usr/bin/env bash
set -euo pipefail

# Ensure we run from repository root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# On macOS, nix develop stdenv sets DEVELOPER_DIR to an Apple SDK path that
# lacks the git binary, breaking the /usr/bin/git wrapper.
if [ -n "${DEVELOPER_DIR:-}" ] && ! git --version >/dev/null 2>&1; then
  unset DEVELOPER_DIR
fi

run_step() {
  local name="$1"
  shift
  echo "==> $name"
  if ! "$@"; then
    echo "FAIL: $name" >&2
    exit 1
  fi
}

run_step "zig build test" zig build test
run_step "zig build e2e" zig build e2e

if [ -z "${SF_TEST_BASHES:-}" ]; then
  echo "FAIL: SF_TEST_BASHES is unset or empty" >&2
  exit 1
fi

run_step "bats tests/preload" bats tests/preload

echo "==> shellcheck"
shell_files=()
while IFS= read -r -d '' f; do
  shell_files+=("$f")
done < <(git ls-files -z -- '*.sh' '*.bash' '*.bats')

if [ ${#shell_files[@]} -eq 0 ]; then
  echo "FAIL: shellcheck: no tracked shell files found" >&2
  exit 1
fi

for f in "${shell_files[@]}"; do
  if ! shellcheck -x "$f"; then
    echo "FAIL: shellcheck: $f" >&2
    exit 1
  fi
done

run_step "zig build -Dtarget=x86_64-linux-musl" zig build -Dtarget=x86_64-linux-musl
run_step "zig build -Dtarget=aarch64-macos" zig build -Dtarget=aarch64-macos
run_step "zig build test-build -Dtarget=x86_64-linux-musl" zig build test-build -Dtarget=x86_64-linux-musl
run_step "zig build test-build -Dtarget=aarch64-macos" zig build test-build -Dtarget=aarch64-macos

echo "All checks passed."
