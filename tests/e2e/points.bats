#!/usr/bin/env bats

setup() {
  load '../helpers.bash'
}

teardown() {
  if [ -d "shellfault-out" ]; then
    git clean -fd shellfault-out >/dev/null 2>&1 || true
  fi
}

@test "points lists boundaries and externals" {
  mkscript "target.sh" "echo hello; mkdir somedir"
  run sf points --out "${BATS_TEST_TMPDIR}/out" "${BATS_TEST_TMPDIR}/target.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"target.sh:"* ]]
  [[ "$output" == *"external: "* ]]
}

@test "points warns when DEBUG trap is replaced" {
  mkscript "debug_trap.sh" "trap '' DEBUG; echo after"
  run sf points --out "${BATS_TEST_TMPDIR}/out" "${BATS_TEST_TMPDIR}/debug_trap.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning:"* ]]
  [[ "$output" == *"DEBUG trap replaced; later points are not covered"* ]]
}
