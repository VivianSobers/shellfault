# shellcheck shell=bash

# shellcheck disable=SC2317
if [ -z "${SF_ROOT:-}" ]; then
  export SF_ROOT="$$"
elif [ "$$" != "$SF_ROOT" ]; then
  return 0 2>/dev/null || exit 0
fi

[ -n "${SF_CTL:-}" ] || return 0 2>/dev/null || exit 0

SF_MODE="${SF_MODE:-reference}"
if [ -n "${SF_SEED:-}" ]; then
  RANDOM="$SF_SEED"
fi

SF_TRACE_FD="${SF_TRACE_FD:-87}"
eval "exec $SF_TRACE_FD>>\"\$SF_CTL/trace.log\""

__sf_depth=0
__sf_prefix=""
__sf_n=0
__sf_id=""
__sf_prev_arg=""

trap() {
  local __sf_has_debug=0
  local __sf_is_query=0
  local __sf_arg
  for __sf_arg in "$@"; do
    case "$__sf_arg" in
      -p|-l) __sf_is_query=1 ;;
      DEBUG|debug) __sf_has_debug=1 ;;
    esac
  done
  if [ "$__sf_has_debug" -eq 1 ] && [ "$__sf_is_query" -eq 0 ]; then
    eval "printf 'W\\t%s\\t%s\\t%s\\tdebug-trap-replaced\\n' \
      \"\$__sf_id\" \"\${BASH_SOURCE[1]}\" \"\${BASH_LINENO[0]}\" >&\$SF_TRACE_FD 2>/dev/null" || :
  fi
  # shellcheck disable=SC2064
  builtin trap "$@"
}

__sf_trap() {
  local __sf_sub="$BASH_SUBSHELL" || :
  if [ "$__sf_sub" -gt "$__sf_depth" ]; then
    __sf_prefix="${__sf_id:-0}" || :
    __sf_n=0 || :
    __sf_depth="$__sf_sub" || :
  fi
  __sf_n=$((__sf_n + 1)) || :
  if [ -n "$__sf_prefix" ]; then
    __sf_id="${__sf_prefix}/${__sf_n}" || :
  else
    __sf_id="$__sf_n" || :
  fi

  local __sf_funcs="" || :
  local __sf_i || :
  for (( __sf_i = 1; __sf_i < ${#FUNCNAME[@]}; __sf_i++ )); do
    local __sf_fn="${FUNCNAME[$__sf_i]}" || :
    if [ "$__sf_fn" = "main" ] || [ "$__sf_fn" = "source" ]; then
      continue
    fi
    if [ -z "$__sf_funcs" ]; then
      __sf_funcs="$__sf_fn" || :
    else
      __sf_funcs="${__sf_funcs},${__sf_fn}" || :
    fi
  done

  local __sf_cmd="$BASH_COMMAND" || :
  local __sf_esc="$__sf_cmd" || :
  __sf_esc="${__sf_esc//\\/\\\\}" || :
  __sf_esc="${__sf_esc//$'\t'/\\t}" || :
  __sf_esc="${__sf_esc//$'\n'/\\n}" || :

  local __sf_src="${BASH_SOURCE[1]}" || :
  local __sf_lineno="${BASH_LINENO[0]}" || :

  eval "printf 'B\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \
    \"\$__sf_id\" \"\$__sf_src\" \"\$__sf_lineno\" \"\$__sf_funcs\" \"\$__sf_esc\" >&\$SF_TRACE_FD 2>/dev/null" || :

  local __sf_rem="$__sf_cmd" || :
  while [[ "$__sf_rem" =~ ^[[:space:]]+(.*)$ ]]; do
    __sf_rem="${BASH_REMATCH[1]}" || :
  done
  local __sf_word="" || :
  while [ -n "$__sf_rem" ]; do
    if [[ "$__sf_rem" =~ ^[a-zA-Z_][a-zA-Z0-9_]*=\"[^\"]*\"(.*)$ ]]; then
      __sf_rem="${BASH_REMATCH[1]}" || :
    elif [[ "$__sf_rem" =~ ^[a-zA-Z_][a-zA-Z0-9_]*=\'[^\']*\'(.*)$ ]]; then
      __sf_rem="${BASH_REMATCH[1]}" || :
    elif [[ "$__sf_rem" =~ ^[a-zA-Z_][a-zA-Z0-9_]*=[^[:space:]]*(.*)$ ]]; then
      __sf_rem="${BASH_REMATCH[1]}" || :
    else
      if [[ "$__sf_rem" =~ ^([^[:space:]]+) ]]; then
        __sf_word="${BASH_REMATCH[1]}" || :
      fi
      break
    fi
    while [[ "$__sf_rem" =~ ^[[:space:]]+(.*)$ ]]; do
      __sf_rem="${BASH_REMATCH[1]}" || :
    done
  done

  if [ -n "$__sf_word" ]; then
    case "$__sf_word" in
      *\$*)
        eval "printf 'X\\t%s\\t?\\n' \"\$__sf_id\" >&\$SF_TRACE_FD 2>/dev/null" || :
        ;;
      *)
        type -t "$__sf_word" > "$SF_CTL/.type_tmp" 2>/dev/null || :
        local __sf_type="" || :
        read -r __sf_type < "$SF_CTL/.type_tmp" 2>/dev/null || :
        if [ "$__sf_type" = "file" ]; then
          eval "printf 'X\\t%s\\t%s\\n' \"\$__sf_id\" \"\$__sf_word\" >&\$SF_TRACE_FD 2>/dev/null" || :
        fi
        ;;
    esac
  fi
}

set -T
builtin trap '__sf_prev_arg="$_"; __sf_trap; : "$__sf_prev_arg"' DEBUG
