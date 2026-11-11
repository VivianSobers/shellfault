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

run_script() {
  local bash_bin="$1"
  local script_path="$2"
  shift 2
  (
    cd "$REPO_ROOT" || exit 1
    SF_CTL="$TEST_CTL" BASH_ENV="src/preload.bash" "$bash_bin" "$script_path" "$@"
  )
}

@test "top-level commands get sequential ids" {
  local script="$BATS_TEST_TMPDIR/script.sh"
  mkscript "$script" \
    "a=1" \
    "true" \
    "echo hi >/dev/null"

  for bash_bin in $(get_bashes); do
    rm -f "$TEST_CTL/trace.log"
    run_script "$bash_bin" "$script"
    [ -f "$TEST_CTL/trace.log" ]
    local ids
    ids="$(awk -F'\t' '$1 == "B" { print $2 }' "$TEST_CTL/trace.log" | tr '\n' ' ' | sed 's/ $//')"
    [ "$ids" = "1 2 3" ]
  done
}

@test "command substitution gets nested ids" {
  local script="$BATS_TEST_TMPDIR/script.sh"
  mkscript "$script" \
    "x=\$(true; true)"

  for bash_bin in $(get_bashes); do
    rm -f "$TEST_CTL/trace.log"
    run_script "$bash_bin" "$script"
    [ -f "$TEST_CTL/trace.log" ]
    local ids
    ids="$(awk -F'\t' '$1 == "B" { print $2 }' "$TEST_CTL/trace.log" | tr '\n' ' ' | sed 's/ $//')"
    [ "$ids" = "1 1/1 1/2" ]
  done
}

@test "function body commands carry the function name" {
  local script="$BATS_TEST_TMPDIR/script.sh"
  mkscript "$script" \
    "f() {" \
    "  true" \
    "}" \
    "f"

  for bash_bin in $(get_bashes); do
    rm -f "$TEST_CTL/trace.log"
    run_script "$bash_bin" "$script"
    [ -f "$TEST_CTL/trace.log" ]
    local func_count
    func_count="$(awk -F'\t' '$1 == "B" && $5 == "f" { count++ } END { print count+0 }' "$TEST_CTL/trace.log")"
    [ "$func_count" -ge 1 ]
    local top_funcs
    top_funcs="$(awk -F'\t' '$1 == "B" && $2 == "1" { print $5 }' "$TEST_CTL/trace.log")"
    [ -z "$top_funcs" ]
  done
}

@test "external command is recorded" {
  local script="$BATS_TEST_TMPDIR/script.sh"
  mkscript "$script" \
    "/bin/ls >/dev/null" \
    "ls >/dev/null"

  for bash_bin in $(get_bashes); do
    rm -f "$TEST_CTL/trace.log"
    run_script "$bash_bin" "$script"
    [ -f "$TEST_CTL/trace.log" ]
    grep -q $'^X\t[^\t]*\t/bin/ls$' "$TEST_CTL/trace.log"
    grep -q $'^X\t[^\t]*\tls$' "$TEST_CTL/trace.log"
  done
}

@test "newline and tab in command are escaped" {
  local script="$BATS_TEST_TMPDIR/script.sh"
  printf 'echo "line1\nline2\ttab\\back" >/dev/null\n' > "$script"
  chmod +x "$script"

  for bash_bin in $(get_bashes); do
    rm -f "$TEST_CTL/trace.log"
    run_script "$bash_bin" "$script"
    [ -f "$TEST_CTL/trace.log" ]
    local line_count
    line_count="$(wc -l < "$TEST_CTL/trace.log" | tr -d ' ')"
    [ "$line_count" -eq 1 ]
    local tab_count
    tab_count="$(tr -cd '\t' < "$TEST_CTL/trace.log" | wc -c | tr -d ' ')"
    [ "$tab_count" -eq 5 ]
    local cmd_field
    cmd_field="$(awk -F'\t' '{ print $6 }' "$TEST_CTL/trace.log")"
    [[ "$cmd_field" == *"\\n"* ]]
    [[ "$cmd_field" == *"\\t"* ]]
    [[ "$cmd_field" == *"\\\\"* ]]
  done
}

@test "child bash script is not traced" {
  local child="$BATS_TEST_TMPDIR/child.sh"
  mkscript "$child" \
    "echo child_unique_marker >/dev/null"

  local parent="$BATS_TEST_TMPDIR/parent.sh"

  for bash_bin in $(get_bashes); do
    mkscript "$parent" \
      "echo parent_before >/dev/null" \
      "\"$bash_bin\" \"$child\"" \
      "echo parent_after >/dev/null"

    rm -f "$TEST_CTL/trace.log"
    run_script "$bash_bin" "$parent"
    [ -f "$TEST_CTL/trace.log" ]
    grep -q "parent_before" "$TEST_CTL/trace.log"
    grep -q "parent_after" "$TEST_CTL/trace.log"
    ! grep -q "child_unique_marker" "$TEST_CTL/trace.log"
  done
}

@test "simple pipeline elements are parent boundaries in order" {
  local script="$BATS_TEST_TMPDIR/script.sh"
  mkscript "$script" \
    "echo a | cat >/dev/null"

  for bash_bin in $(get_bashes); do
    rm -f "$TEST_CTL/trace.log"
    run_script "$bash_bin" "$script"
    [ -f "$TEST_CTL/trace.log" ]
    local ids
    ids="$(awk -F'\t' '$1 == "B" { print $2 }' "$TEST_CTL/trace.log" | tr '\n' ' ' | sed 's/ $//')"
    [ "$ids" = "1 2" ]
  done
}

@test "loop fed by a pipe is nested under the producer" {
  local script="$BATS_TEST_TMPDIR/script.sh"
  mkscript "$script" \
    "printf '1\\n' | while read -r l; do :; done"

  for bash_bin in $(get_bashes); do
    rm -f "$TEST_CTL/trace.log"
    run_script "$bash_bin" "$script"
    [ -f "$TEST_CTL/trace.log" ]
    local first_id
    first_id="$(awk -F'\t' '$1 == "B" { print $2; exit }' "$TEST_CTL/trace.log")"
    [ "$first_id" = "1" ]
    local non_nested
    non_nested="$(awk -F'\t' '$1 == "B" && NR > 1 && $2 !~ /^1\// { print $2 }' "$TEST_CTL/trace.log")"
    [ -z "$non_nested" ]
  done
}

@test "replacing the DEBUG trap is reported" {
  local script="$BATS_TEST_TMPDIR/script.sh"
  mkscript "$script" \
    "true" \
    "trap 'true' DEBUG" \
    "true"

  for bash_bin in $(get_bashes); do
    rm -f "$TEST_CTL/trace.log"
    run_script "$bash_bin" "$script"
    [ -f "$TEST_CTL/trace.log" ]
    local w_line
    w_line="$(awk -F'\t' '$1 == "W" { print $4 }' "$TEST_CTL/trace.log")"
    [ "$w_line" = "2" ]
    local w_msg
    w_msg="$(awk -F'\t' '$1 == "W" { print $5 }' "$TEST_CTL/trace.log")"
    [ "$w_msg" = "debug-trap-replaced" ]
  done
}

@test "concurrent children do not mislabel keywords" {
  local script="$BATS_TEST_TMPDIR/script.sh"
  mkscript "$script" \
    "for r in \$(seq 1 30); do for i in 1 2 3; do echo \$i; done | while read -r l; do ls >/dev/null; done; done"

  for bash_bin in $(get_bashes); do
    rm -f "$TEST_CTL/trace.log"
    run_script "$bash_bin" "$script"
    [ -f "$TEST_CTL/trace.log" ]
    ! grep -q -E $'^X\t[^\t]*\t(for|while|do|done|echo|read)$' "$TEST_CTL/trace.log"
    grep -q $'^X\t[^\t]*\tls$' "$TEST_CTL/trace.log"
  done
}

