#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TEST_CTL="$BATS_TEST_TMPDIR/ctl"
  mkdir -p "$TEST_CTL"
}

get_bashes() {
  local bashes_var="${SF_TEST_BASHES:-/bin/bash:/opt/homebrew/bin/bash}"
  local IFS=:
  # shellcheck disable=SC2086
  set -- $bashes_var
  printf '%s\n' "$@"
}

mkscript() {
  local path="$1"
  shift
  printf '%s\n' "$@" > "$path"
  chmod +x "$path"
}

@test "exit status visible after command" {
  local script="$BATS_TEST_TMPDIR/script.sh"
  mkscript "$script" \
    "false" \
    "echo \"\$?\""

  for bash_bin in $(get_bashes); do
    local out
    out="$(cd "$REPO_ROOT" && SF_CTL="$TEST_CTL" BASH_ENV="src/preload.bash" "$bash_bin" "$script")"
    [ "$out" = "1" ]
  done
}

@test "set -e still exits" {
  local script="$BATS_TEST_TMPDIR/script.sh"
  mkscript "$script" \
    "set -e" \
    "false" \
    "echo no"

  for bash_bin in $(get_bashes); do
    run bash -c "cd '$REPO_ROOT' && SF_CTL='$TEST_CTL' BASH_ENV='src/preload.bash' '$bash_bin' '$script'"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
  done
}

@test "dollar underscore preserved" {
  local script="$BATS_TEST_TMPDIR/script.sh"
  mkscript "$script" \
    "echo foo bar" \
    "echo \"\$_\""

  for bash_bin in $(get_bashes); do
    local out
    out="$(cd "$REPO_ROOT" && SF_CTL="$TEST_CTL" BASH_ENV="src/preload.bash" "$bash_bin" "$script")"
    local last_line
    last_line="$(printf '%s\n' "$out" | tail -n1)"
    [ "$last_line" = "bar" ]
  done
}

@test "positional parameters preserved" {
  local script="$BATS_TEST_TMPDIR/script.sh"
  mkscript "$script" \
    "set -- one two three" \
    "echo \"\$1 \$2 \$3\""

  for bash_bin in $(get_bashes); do
    local out
    out="$(cd "$REPO_ROOT" && SF_CTL="$TEST_CTL" BASH_ENV="src/preload.bash" "$bash_bin" "$script")"
    [ "$out" = "one two three" ]
  done
}

@test "fd 3 to 9 untouched" {
  local script="$BATS_TEST_TMPDIR/script.sh"
  mkscript "$script" \
    "echo \"written to fd 9\" >&9"

  local fd_out="$BATS_TEST_TMPDIR/fd9.out"

  for bash_bin in $(get_bashes); do
    rm -f "$fd_out"
    (
      cd "$REPO_ROOT" || exit 1
      exec 9>"$fd_out"
      SF_CTL="$TEST_CTL" BASH_ENV="src/preload.bash" "$bash_bin" "$script"
    )
    local content
    content="$(cat "$fd_out")"
    [ "$content" = "written to fd 9" ]
  done
}

@test "same RANDOM sequence for same seed" {
  local script="$BATS_TEST_TMPDIR/script.sh"
  mkscript "$script" \
    "echo \"\$RANDOM \$RANDOM \$RANDOM\""

  for bash_bin in $(get_bashes); do
    local r1 r2 r3
    r1="$(cd "$REPO_ROOT" && SF_CTL="$TEST_CTL" SF_SEED=12345 BASH_ENV="src/preload.bash" "$bash_bin" "$script")"
    r2="$(cd "$REPO_ROOT" && SF_CTL="$TEST_CTL" SF_SEED=12345 BASH_ENV="src/preload.bash" "$bash_bin" "$script")"
    r3="$(cd "$REPO_ROOT" && SF_CTL="$TEST_CTL" SF_SEED=54321 BASH_ENV="src/preload.bash" "$bash_bin" "$script")"
    [ "$r1" = "$r2" ]
    [ "$r1" != "$r3" ]
  done
}

@test "noclobber scripts see no preload errors" {
  local script="$BATS_TEST_TMPDIR/script.sh"
  mkscript "$script" \
    "set -C" \
    "ls >/dev/null" \
    "echo x"

  local stdout_file="$BATS_TEST_TMPDIR/stdout.log"
  local stderr_file="$BATS_TEST_TMPDIR/stderr.log"

  for bash_bin in $(get_bashes); do
    rm -f "$TEST_CTL/trace.log" "$stdout_file" "$stderr_file"
    (
      cd "$REPO_ROOT" || exit 1
      SF_CTL="$TEST_CTL" BASH_ENV="src/preload.bash" "$bash_bin" "$script" >"$stdout_file" 2>"$stderr_file"
    )
    local out err
    out="$(cat "$stdout_file")"
    err="$(cat "$stderr_file")"
    [ "$out" = "x" ]
    [ -z "$err" ]
    [ -f "$TEST_CTL/trace.log" ]
    grep -q $'^X\t[^\t]*\tls$' "$TEST_CTL/trace.log"
  done
}

