#!/usr/bin/env bats

setup() {
  load '../helpers.bash'
}

@test "shellfault --version prints version and exits 0" {
  run sf --version
  [ "$status" -eq 0 ]
  [ "$output" = "shellfault 0.0.0 (Lua 5.4.8)" ]
}

@test "shellfault frobnicate exits 2 and prints unknown command on stderr" {
  run sf frobnicate
  [ "$status" -eq 2 ]
  [ "$output" = "unknown command: frobnicate" ]
}
