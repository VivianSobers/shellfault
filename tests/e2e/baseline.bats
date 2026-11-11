#!/usr/bin/env bats

setup() {
  load '../helpers.bash'
  CORPUS_DIR="${BATS_TEST_DIRNAME}/../corpus"
}

teardown() {
  if [ -d "shellfault-out" ]; then
    git clean -fd shellfault-out >/dev/null 2>&1 || true
  fi
}

@test "append twice is a RERUN finding" {
  run sf run --out "${BATS_TEST_TMPDIR}/out" "${CORPUS_DIR}/append-twice/buggy.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"RERUN: second run changed the workspace"* ]]
  [[ "$output" == *"list.txt"* ]]
}

@test "mkdir without -p is a RERUN finding" {
  run sf run --out "${BATS_TEST_TMPDIR}/out" "${CORPUS_DIR}/mkdir-no-p/buggy.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"RERUN: second run failed"* ]]
}

@test "fixed scripts pass the baseline" {
  run sf run --out "${BATS_TEST_TMPDIR}/out" "${CORPUS_DIR}/append-twice/fixed.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"baseline ok"* ]]

  run sf run --out "${BATS_TEST_TMPDIR}/out" "${CORPUS_DIR}/mkdir-no-p/fixed.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"baseline ok"* ]]
}

@test "nondeterministic script stops with exit 2" {
  run sf run --out "${BATS_TEST_TMPDIR}/out" "${CORPUS_DIR}/nondeterministic/script.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"two clean runs differ:"* ]]
}

@test "failing reference stops with exit 2" {
  mkscript "fail.sh" "exit 42"
  run sf run --out "${BATS_TEST_TMPDIR}/out" "${BATS_TEST_TMPDIR}/fail.sh"
  [ "$status" -eq 2 ]
}

@test "missing trace is an error" {
  mkscript "s.sh" "echo hi"
  run sf run --out "${BATS_TEST_TMPDIR}/out" --bash /bin/sh "${BATS_TEST_TMPDIR}/s.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"trace"* ]]
}

@test "script path and args with spaces and globs" {
  local dir="${BATS_TEST_TMPDIR}/dir with space"
  mkdir -p "$dir"
  local script="$dir/s*.sh"
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\nprintf "%%s" "$1" > result.txt\n' > "$script"
  chmod +x "$script"

  local outdir="${BATS_TEST_TMPDIR}/sf-out"
  run sf run --out "$outdir" "$script" -- "a b*"
  [ "$status" -eq 0 ]

  local result_file
  result_file=$(find "$outdir" -name "result.txt" | head -n 1)
  [ -f "$result_file" ]
  [ "$(cat "$result_file")" = "a b*" ]
}

@test "no processes left after run" {
  mkscript "bg.sh" "sleep 300 &"
  run sf run --out "${BATS_TEST_TMPDIR}/out" "${BATS_TEST_TMPDIR}/bg.sh"
  [ "$status" -eq 0 ]
  run pgrep -f 'sleep 300'
  [ "$status" -eq 1 ]
}

@test "absolute workspace paths do not make runs differ" {
  run sf run --out "${BATS_TEST_TMPDIR}/out" "${CORPUS_DIR}/abs-path/script.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"baseline ok"* ]]
}

@test "files kept from the first run do not make the rerun differ" {
  run sf run --out "${BATS_TEST_TMPDIR}/out" "${CORPUS_DIR}/abs-path-once/script.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"baseline ok"* ]]
}

@test "output inside the fixture is refused" {
  local fix_dir="${BATS_TEST_TMPDIR}/fixture"
  mkdir -p "$fix_dir"
  mkscript "fixture/script.sh" "echo hi"
  cd "$fix_dir" || exit 1
  run sf run --fixture . script.sh
  [ "$status" -eq 2 ]
  [[ "$output" == *"output directory is inside the fixture"* ]]
}

@test "setup errors say what failed" {
  local script="${BATS_TEST_TMPDIR}/s.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'true' > "$script"
  chmod +x "$script"
  run --separate-stderr sf run --bash /no/such/bash --out "${BATS_TEST_TMPDIR}/out" "$script"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"shellfault:"* ]]
  [[ "$stderr" == *"/no/such/bash"* ]]
}
