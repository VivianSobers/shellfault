#!/usr/bin/env bash

sf() {
  local bin="${SF_BIN:-}"
  if [[ -z "$bin" ]]; then
    if [[ -x "zig-out/bin/shellfault" ]]; then
      bin="zig-out/bin/shellfault"
    elif [[ -x "${BATS_TEST_DIRNAME:-}/../../zig-out/bin/shellfault" ]]; then
      bin="${BATS_TEST_DIRNAME}/../../zig-out/bin/shellfault"
    else
      bin="zig-out/bin/shellfault"
    fi
  fi
  "$bin" "$@"
}

mkscript() {
  local name="$1"
  local body="$2"
  local target="${BATS_TEST_TMPDIR:-/tmp}/$name"
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$target"
  chmod +x "$target"
}
