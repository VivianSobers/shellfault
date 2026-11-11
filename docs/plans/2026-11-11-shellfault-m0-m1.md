# shellfault milestones 0 and 1 implementation plan

> For workers: each task is self-contained. Read the Global Constraints and your task, follow the steps in
> order (test first), and run every command in the foreground. Steps use checkboxes for tracking.

**Goal:** a `shellfault` binary that runs a Bash script in an isolated workspace with injected
instrumentation, lists its crash points and external calls (`shellfault points`), and reports scripts that
are not safe to run twice (`shellfault run`, baseline only).

**Architecture:** a Zig engine (CLI, process supervision, workspace cloning, manifests, trace parsing,
session orchestration) embeds a Bash preload that the target script sources through `BASH_ENV`. The preload
writes a boundary trace into a control directory; the engine reads it. Lua is compiled in now and used from
milestone 4. Nix pins the toolchain and the Bash version matrix.

**Tech stack:** Zig 0.17.1, Lua 5.4.8 (C sources built by `build.zig`), Bash 3.2 to 5.3, bats-core,
ShellCheck, Nix flakes, GitHub Actions.

**Spec:** `docs/specs/2026-11-11-shellfault-design.md`

## Global constraints

- Zig exactly 0.17.1. Before using any `std` API, read its source in the pinned toolchain
  (`$(zig env | jq -r .lib_dir)/std`). Do not copy code written for older Zig releases.
- If the pinned `std` requires an `Io` handle for file or process work, add `io: std.Io` as the second
  parameter (after the allocator) of every engine function below that does I/O, consistently. Likewise,
  where this plan names `std.process.EnvMap`, use the pinned `std`'s environment map type if it was renamed.
- The preload must run under Bash 3.2: no `BASHPID`, `{fd}` redirections, associative arrays, `mapfile`,
  `${var,,}`, `printf -v` with arrays, `wait -n`, or `EPOCHREALTIME`.
- The preload never changes what the script observes: `$?`, `$_`, positional parameters, `set -e`
  behavior, and file descriptors 0 to 9 stay as they would be without it.
- ShellCheck passes on every `.bash`, `.sh` and `.bats` file (`shellcheck -x`).
- Commits: subject only, `<type>: <4-6 words>`, types feat, fix, refactor, test, docs, chore, perf, ci,
  build. No body, no trailers, no tool or assistant names anywhere in the repository. Use the exact message
  each task gives.
- One logical change per commit, with tests passing.
- Exit codes of `shellfault`: 0 no findings, 1 findings, 2 usage or setup error.

## Review focus

The inputs most likely to break a user's first run that the spec does not spell out, each pinned by a test
in the task named:

1. A script that sets its own `DEBUG` trap: tracing silently stops. Expected: shellfault reports the line
   where instrumentation was lost and keeps going. Test in Task 4.
2. File names with spaces, tabs, newlines or non-UTF-8 bytes, and symlinks pointing outside the workspace.
   Expected: exact round-trip in the manifest, symlinks never followed. Test in Task 7.
3. A script that reads stdin or waits for a TTY. Expected: stdin is `/dev/null`, the run finishes. Test in
   Task 5.
4. Script paths and arguments containing spaces or glob characters. Expected: passed through unchanged.
   Test in Task 9.
5. A script that relies on `$?` right after a command, or on `set -e` exiting. Expected: identical behavior
   with and without the preload. Test in Task 4.

---

## File structure

```
flake.nix, flake.lock          toolchain, Bash matrix, checks
build.zig, build.zig.zon       engine build, Lua dependency, test steps
src/main.zig                   entry: parse args, dispatch subcommand, map errors to exit codes
src/cli.zig                    argument parsing into Options
src/lua.zig                    embedded Lua state wrapper
src/preload.bash               instrumentation sourced through BASH_ENV (embedded)
src/supervise.zig              run a command in its own process group with timeout and cleanup
src/workspace.zig              run directories, fixture cloning, run environment
src/manifest.zig               workspace manifest: build, serialize, parse, diff
src/trace.zig                  parse the preload's trace into boundaries and external calls
src/points.zig                 crash-point selection
src/session.zig                fixture, reference x2, determinism check, rerun check
tests/preload/*.bats           preload run directly under every Bash in the matrix
tests/e2e/*.bats               the built binary against the corpus
tests/corpus/<case>/{buggy,fixed}.sh
tests/helpers.bash             shared bats helpers
docs/spikes.md                 spike results (Task 3)
.github/workflows/ci.yml
```

---

### Task 1: Nix toolchain and Bash matrix

**Files:**
- Create: `flake.nix`, `flake.lock`, `nix/bash.nix`, `scripts/toolchain-check.sh`

**Interfaces:**
- Produces: `nix develop` shell with `zig` 0.17.1, `bats`, `shellcheck`, `jq`, and `SF_TEST_BASHES` set to a
  colon-separated list of Bash binaries; `nix build .#bashes` producing `bin/bash-4.4`, `bin/bash-5.1`,
  `bin/bash-5.2`, `bin/bash-5.3`, plus `bin/bash-3.2` where it builds.

- [ ] **Step 1: Write `scripts/toolchain-check.sh`**, which exits nonzero unless `zig version` prints
  `0.17.1`, `bats --version` and `shellcheck --version` succeed, and every path in `SF_TEST_BASHES` runs
  `-c 'echo $BASH_VERSION'` and prints a version matching its file name.
- [ ] **Step 2: Run it outside the dev shell.** Expected: FAIL.
- [ ] **Step 3: Write `flake.nix`** for `aarch64-darwin`, `x86_64-linux` and `aarch64-linux`. Zig comes from
  `github:mitchellh/zig-overlay` if it has 0.17.1, otherwise from the official tarballs on ziglang.org with
  pinned hashes. `nix/bash.nix` builds Bash from the GNU release tarballs (3.2.57, 4.4.18, 5.1.16, 5.2.37,
  5.3 latest patch level) with `CFLAGS=-std=gnu89 -Wno-error`; if 3.2 still fails to build on a system,
  leave it out there and on macOS add `/bin/bash` (3.2) to `SF_TEST_BASHES` instead.
- [ ] **Step 4: Run** `nix develop -c scripts/toolchain-check.sh` on macOS and on Linux. Expected: PASS on
  both, with the Bash list printed.
- [ ] **Step 5: Commit** `build: add nix toolchain and bash matrix`

### Task 2: Engine skeleton with embedded Lua

**Files:**
- Create: `build.zig`, `build.zig.zon`, `src/main.zig`, `src/cli.zig`, `src/lua.zig`,
  `tests/helpers.bash`, `tests/e2e/cli.bats`

**Interfaces:**
- Produces:
  - `zig build` → `zig-out/bin/shellfault`; `zig build test` runs all Zig tests; `zig build e2e` builds,
    then runs `bats tests/e2e`.
  - `cli.parse(gpa: Allocator, argv: []const []const u8) !Options`, where `Options` is a tagged union
    `{ version, points: RunOptions, run: RunOptions }` and `RunOptions` has `script: []const u8`,
    `args: []const []const u8`, `fixture: ?[]const u8`, `out: []const u8` (default `shellfault-out`),
    `timeout_s: u32` (default 60), `bash: ?[]const u8`. Parse errors return `error.Usage` with a message.
  - `lua.State.init(gpa) !State`, `State.evalNumber(src: [:0]const u8) !f64`, `State.deinit()`.
  - `tests/helpers.bash`: `sf()` runs `$SF_BIN` (default `zig-out/bin/shellfault`); `mkscript NAME BODY`
    writes an executable script with `#!/usr/bin/env bash` into `$BATS_TEST_TMPDIR`.

- [ ] **Step 1: Write failing tests.**
  `src/lua.zig`: `test "embedded lua evaluates arithmetic"` expects `evalNumber("return 1 + 2") == 3`.
  `src/cli.zig`: `test "parses run with args after --"` expects `run` with `script = "a b.sh"` and
  `args = {"x", "--y"}` from `{"run", "a b.sh", "--", "x", "--y"}`; `test "unknown command is usage
  error"`.
  `tests/e2e/cli.bats`: `shellfault --version` exits 0 and prints `shellfault 0.0.0 (Lua 5.4.8)`;
  `shellfault frobnicate` exits 2 and prints `unknown command: frobnicate` on stderr.
- [ ] **Step 2: Run** `zig build test` and `zig build e2e`. Expected: FAIL (missing files or symbols).
- [ ] **Step 3: Implement.** Add Lua with `zig fetch --save=lua https://www.lua.org/ftp/lua-5.4.8.tar.gz`;
  `build.zig` compiles every `src/*.c` of Lua except `lua.c` and `luac.c` into a static library, links libc,
  and exposes `lua.h`/`lauxlib.h`/`lualib.h` to `src/lua.zig` through `@cImport`. Release builds for Linux
  target musl.
- [ ] **Step 4: Run** both commands. Expected: PASS.
- [ ] **Step 5: Commit** `feat: add engine skeleton with lua`

### Task 3: Spikes (done by the coordinator, not a worker)

Throwaway experiments; only `docs/spikes.md` is committed. Each spike records the command, the Bash or OS
version, the observed output and the decision it implies.

- [ ] S1 boundary IDs: on Bash 3.2 and 5.3, record the `DEBUG` trap's `BASH_SUBSHELL`, `$$`, and (5.3)
  `BASHPID` for `$(...)`, `( )`, functions, `a | b`, `a &`, and process substitution. Decide how the preload
  tells a pipeline element or background job from the main process on 3.2.
- [ ] S2 group kill: from inside the trap, `kill -s KILL 0` and `kill -s TERM 0` when the engine started the
  run with `setpgid(0,0)`; confirm the engine survives and children die, on macOS and Linux.
- [ ] S3 `unshare(2)` user+mount+net namespaces with an overlay over `/` on Fedora 44 and Ubuntu 24.04
  (AppArmor `kernel.apparmor_restrict_unprivileged_userns`).
- [ ] S4 `sandbox-exec` on macOS 27.2: a profile that denies `file-write*` outside one directory and denies
  `network*`; confirm the error a denied write returns.
- [ ] S5 `clonefile` on APFS and `FICLONE` on Fedora's filesystem: time to clone a 10,000-file tree versus a
  plain copy.
- [ ] Revise Tasks 4 and 5 below if S1 or S2 contradict them, then commit
  `docs: record spike results and decisions`.

### Task 4: Bash preload with boundary tracing

**Files:**
- Create: `src/preload.bash`, `tests/preload/trace.bats`, `tests/preload/transparency.bats`

**Interfaces:**
- Consumes: environment set by the engine: `SF_CTL` (control directory), `SF_MODE` (`reference` in this
  milestone; other values come in milestone 2), `SF_SEED` (integer), `SF_TRACE_FD` (default `87`).
- Produces: `$SF_CTL/trace.log`, one record per line, fields separated by a TAB:
  - `B id source line funcs command`: a boundary. `id` is `N` in the main process and `P/N` inside a
    subshell started at boundary `P` (nesting repeats, for example `14/3/2`). `funcs` is `FUNCNAME` from
    innermost to outermost joined by `,`, empty at top level. In `command`, `\` becomes `\\`, TAB `\t`,
    newline `\n`.
  - `X id name`: the boundary `id` runs external command `name` (as resolved by `type -t` = `file`; the
    first word after leading `NAME=value` assignments). If the first word contains `$`, `name` is `?`.
  - `W id source line debug-trap-replaced`: the script set its own `DEBUG` trap at that line.
- Behavior: only the process whose `$$` equals `SF_ROOT` traces; the preload exports `SF_ROOT=$$` when it is
  unset, so child Bash scripts stay silent. Pipeline elements and background jobs do not emit `B` records
  (per S1). `RANDOM` is seeded with `SF_SEED`. A `trap` function wraps the builtin: any call that names
  `DEBUG` writes the `W` record and is then passed to `builtin trap` unchanged; all other calls pass through
  unchanged, including `trap -p` and `trap -l`.

- [ ] **Step 1: Write failing tests**, each run under every Bash in `SF_TEST_BASHES` with
  `BASH_ENV=src/preload.bash`:
  - `trace.bats`: `test "top-level commands get sequential ids"` (script `a=1; true; echo hi >/dev/null`
    gives ids `1 2 3`); `test "command substitution gets nested ids"` (`x=$(true; true)` at boundary 1
    gives `1`, `1/1`, `1/2`); `test "function body commands carry the function name"` (`f(){ true; }; f`
    gives a record with `funcs` = `f`); `test "external command is recorded"` (`/bin/ls >/dev/null` and
    `ls >/dev/null` both produce `X` with `ls` or `/bin/ls`); `test "newline and tab in command are
    escaped"`; `test "child bash script is not traced"`; `test "pipeline elements emit no boundaries"`;
    `test "replacing the DEBUG trap is reported"` (script runs `trap 'true' DEBUG` on line 2; expect a `W`
    record with line `2`).
  - `transparency.bats`: `test "exit status visible after command"` (`false; echo $?` prints `1`);
    `test "set -e still exits"` (`set -e; false; echo no` prints nothing, exit 1); `test "dollar underscore
    preserved"`; `test "positional parameters preserved"`; `test "fd 3 to 9 untouched"` (script writes to
    fd 9 opened by the caller); `test "same RANDOM sequence for same seed"`.
- [ ] **Step 2: Run** `bats tests/preload`. Expected: FAIL.
- [ ] **Step 3: Implement `src/preload.bash`.** Lineage without `BASHPID`: keep `__sf_depth`,
  `__sf_prefix`, `__sf_n`; when `BASH_SUBSHELL` is greater than `__sf_depth`, the trap is in a new subshell,
  so set `__sf_prefix` to the current full id, reset `__sf_n` and store the new depth. Open the trace once
  with `exec 87>>"$SF_CTL/trace.log"` (fd from `SF_TRACE_FD`). Install the trap last, so the preload
  itself is not traced. Every command in the trap ends in `|| :`.
- [ ] **Step 4: Run** `bats tests/preload` and `shellcheck -x src/preload.bash`. Expected: PASS on every
  Bash in the matrix.
- [ ] **Step 5: Commit** `feat: add preload boundary tracing`

### Task 5: Process supervision

**Files:**
- Create: `src/supervise.zig`

**Interfaces:**
- Produces:
  - `pub const Spec = struct { argv: []const []const u8, env: *const std.process.EnvMap, cwd: []const u8,
    stdout_path: []const u8, stderr_path: []const u8, timeout_ms: u32, run_id: []const u8 }`
  - `pub const Exit = union(enum) { code: u8, signal: u8 }`
  - `pub const Result = struct { exit: Exit, timed_out: bool, leftovers: u32, duration_ms: u64 }`
  - `pub fn run(gpa: Allocator, spec: Spec) !Result`
- Behavior: the child calls `setpgid(0, 0)` before exec; stdin is `/dev/null`; `SF_RUN_ID=<run_id>` is added
  to its environment. When the main child exits or the timeout passes, the engine sends `TERM` to the group,
  waits 2 seconds, then sends `KILL`. On Linux the engine sets `PR_SET_CHILD_SUBREAPER` once at startup and
  reaps and kills adopted descendants. On macOS it scans same-user processes (`sysctl` `KERN_PROC_ALL` and
  `KERN_PROCARGS2`) for `SF_RUN_ID=<run_id>` and kills them. `leftovers` counts processes that were still
  alive after the group kill.

- [ ] **Step 1: Write failing Zig tests:** `test "reports exit code"` (`sh -c 'exit 3'` → `.code = 3`);
  `test "reports killing signal"` (`sh -c 'kill -9 $$'` → `.signal = 9`); `test "timeout kills the
  group"` (`sh -c 'sleep 100 & sleep 100'`, timeout 300 ms → `timed_out`, and the child `sleep` pid it wrote
  to a file is gone); `test "double-forked daemon does not survive"` (`sh -c '(setsid sleep 300 &) ;
  exit 0'` on Linux, `(sleep 300 &)` with `nohup` on macOS → pid gone after `run` returns); `test "stdin is
  dev null"` (`sh -c 'read x; echo done'` finishes with exit 1 within the timeout); `test "output goes to
  the given files"`.
- [ ] **Step 2: Run** `zig build test`. Expected: FAIL.
- [ ] **Step 3: Implement `run`** with `fork`/`execve` from `std.posix` (not `std.process.Child`, which does
  not expose `setpgid` between fork and exec).
- [ ] **Step 4: Run** `zig build test` on macOS and Linux. Expected: PASS on both, with no `sleep`
  processes left (`pgrep -f 'sleep 300'` prints nothing).
- [ ] **Step 5: Commit** `feat: supervise runs in process groups`

### Task 6: Workspaces and fixture cloning

**Files:**
- Create: `src/workspace.zig`

**Interfaces:**
- Produces:
  - `pub const Run = struct { root: []const u8, ws: []const u8, ctl: []const u8 }`, laid out as
    `<session>/runs/<name>/ws` (the workspace, the script's working directory) and
    `<session>/runs/<name>/ctl` (control directory, never inside `ws`).
  - `pub fn create(gpa, session_dir: []const u8, name: []const u8, fixture: ?[]const u8) !Run`: makes the
    directories and clones `fixture` into `ws` (empty if null).
  - `pub fn cloneTree(src: []const u8, dst: []const u8) !CloneKind` with
    `CloneKind = enum { clonefile, ficlone, copy }`: `clonefile(2)` on macOS; on Linux, walk the tree and
    try the `FICLONE` ioctl per file, falling back to a byte copy. Modes and symlinks are preserved;
    symlinks are copied as links, never followed.
  - `pub fn env(gpa, run: Run, base: *const std.process.EnvMap, seed: u64) !std.process.EnvMap`: copies
    `base`, then sets `HOME=<ws>/.sf-home`, `TMPDIR=<ws>/.sf-tmp`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`,
    `XDG_CACHE_HOME`, `XDG_STATE_HOME` under `.sf-home`, `TZ=UTC`, `LC_ALL=C`,
    `SOURCE_DATE_EPOCH=315532800`, `SF_CTL=<ctl>`, `SF_SEED=<seed>`, and removes `SF_ROOT`. Creates the
    directories.
  - `pub const default_ignores = [_][]const u8{".sf-tmp/**"}`.

- [ ] **Step 1: Write failing Zig tests:** `test "clone preserves content mode and symlinks"` (file `0755`,
  a symlink to `../outside` copied as a link); `test "clone of missing fixture is an error"`; `test "env
  points home and tmp into the workspace"`; `test "ctl is outside ws"`.
- [ ] **Step 2: Run** `zig build test`. Expected: FAIL.
- [ ] **Step 3: Implement** as specified.
- [ ] **Step 4: Run** `zig build test` on macOS and Linux. Expected: PASS; the clone test also prints which
  `CloneKind` was used.
- [ ] **Step 5: Commit** `feat: add workspaces and fixture cloning`

### Task 7: Workspace manifest and diff

**Files:**
- Create: `src/manifest.zig`

**Interfaces:**
- Produces:
  - `pub const Kind = enum { file, dir, symlink, other }`
  - `pub const Entry = struct { path: []const u8, kind: Kind, mode: u16, size: u64, sha256: [32]u8,
    link: []const u8 }`. For directories `size` and `sha256` are zero; for symlinks `sha256` is zero and
    `link` holds the target.
  - `pub const Manifest = struct { entries: []Entry }` sorted by `path` bytewise.
  - `pub fn build(gpa, root: []const u8, ignores: []const []const u8) !Manifest`. Ignore patterns are globs
    on the relative path, where `*` does not cross `/` and `**` does.
  - `pub fn write(m: Manifest, writer) !void` and `pub fn parse(gpa, text: []const u8) !Manifest`. One line
    per entry: `kind mode size sha256hex path link`, TAB-separated, `mode` in octal; in `path` and `link`,
    bytes `\`, TAB, newline, and any byte outside 0x20 to 0x7e are written as `\\`, `\t`, `\n`, `\xHH`.
  - `pub const Change = struct { path: []const u8, what: enum { added, removed, kind, mode, content, link } }`
  - `pub fn diff(gpa, a: Manifest, b: Manifest) ![]Change`, sorted by path. Modification times are never
    compared.

- [ ] **Step 1: Write failing Zig tests:** `test "identical trees have no changes"`; `test "detects added
  removed and content changes"`; `test "mode change is reported"`; `test "symlink is recorded not
  followed"` (link to `/etc` yields one `symlink` entry and nothing below it); `test "ignore globs"`
  (`.sf-tmp/**` and `*.log` exclude what they should and nothing else); `test "awkward names round
  trip"` (names containing a space, a TAB, a newline and byte `0xff` survive `write` then `parse`).
- [ ] **Step 2: Run** `zig build test`. Expected: FAIL.
- [ ] **Step 3: Implement** with `std.crypto.hash.sha2.Sha256`, streaming file content.
- [ ] **Step 4: Run** `zig build test`. Expected: PASS.
- [ ] **Step 5: Commit** `feat: add workspace manifest and diff`

### Task 8: Trace parsing and point selection

**Files:**
- Create: `src/trace.zig`, `src/points.zig`

**Interfaces:**
- Consumes: the trace format from Task 4.
- Produces:
  - `pub const Boundary = struct { id: []const u8, source: []const u8, line: u32, funcs: []const u8,
    command: []const u8 }` (command unescaped)
  - `pub const Call = struct { id: []const u8, name: []const u8 }`
  - `pub const Warning = struct { id: []const u8, source: []const u8, line: u32, what: []const u8 }`
  - `pub const Trace = struct { boundaries: []Boundary, calls: []Call, warnings: []Warning }`
  - `pub fn parse(gpa, text: []const u8) !Trace`; a malformed line returns `error.BadTrace` and the parser
    records its line number.
  - `pub fn firstAndLastPerLine(gpa, bs: []const Boundary) ![]const Boundary`: for each `(source, line)`,
    the first and the last boundary in trace order (one if they are the same), in trace order.

- [ ] **Step 1: Write failing Zig tests:** `test "parses all record kinds"`; `test "unescapes command"`;
  `test "bad line is an error with its number"`; `test "loop line keeps first and last"` (five boundaries
  on line 3 and one on line 4 give three results, in order).
- [ ] **Step 2: Run** `zig build test`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `zig build test`. Expected: PASS.
- [ ] **Step 5: Commit** `feat: parse traces and select points`

### Task 9: Session baseline, `points` and `run`

**Files:**
- Create: `src/session.zig`, `tests/e2e/points.bats`, `tests/e2e/baseline.bats`,
  `tests/corpus/append-twice/{buggy,fixed}.sh`, `tests/corpus/mkdir-no-p/{buggy,fixed}.sh`,
  `tests/corpus/nondeterministic/script.sh`
- Modify: `src/main.zig` (dispatch `points` and `run`)

**Interfaces:**
- Consumes: `cli.RunOptions`, `workspace.create/env/default_ignores`, `supervise.run`, `manifest.build/diff`,
  `trace.parse`, `points.firstAndLastPerLine`.
- Produces:
  - `pub const Baseline = struct { reference: manifest.Manifest, trace: trace.Trace,
    rerun: ?RerunFinding }`, `RerunFinding = union(enum) { failed: supervise.Exit,
    changed: []manifest.Change }`.
  - `pub fn baseline(gpa, opts: cli.RunOptions) !Baseline`: creates `<out>/session-<UTC timestamp>/`, writes
    the preload there, runs the script twice from fresh fixture clones (`ref1`, `ref2`) with
    `BASH_ENV=<preload>`, `SF_MODE=reference` and seed 1. If either reference run fails, returns
    `error.ReferenceFailed`; if the two manifests differ, returns `error.Nondeterministic`. Then clones
    `ref1`'s workspace into `rerun`, runs the script there, and fills `rerun`.
  - The Bash used is `opts.bash`, else the interpreter named on the script's `#!` line (`/usr/bin/env bash`
    resolves `bash` on `PATH`), else `bash` on `PATH`.
  - `shellfault points`: prints one line per selected boundary, `id  source:line  command`, then
    `external: name (N calls)` per distinct external command, then each warning as
    `warning: source:line: DEBUG trap replaced; later points are not covered`. Exit 0.
  - `shellfault run`: prints `RERUN: second run failed (exit N)` or `RERUN: second run changed the
    workspace` followed by the changes, exit 1; otherwise `baseline ok: K crash points, M external
    commands` and exit 0. `error.Nondeterministic` prints `two clean runs differ:` with the changes and exits
    2; `error.ReferenceFailed` prints the exit and the last 20 lines of stderr and exits 2.

- [ ] **Step 1: Write the corpus.** `append-twice/buggy.sh` appends `line` to `list.txt`; `fixed.sh` appends
  only if the line is missing. `mkdir-no-p/buggy.sh` runs `mkdir data`; `fixed.sh` runs `mkdir -p data`.
  `nondeterministic/script.sh` writes `$RANDOM$$` and the output of `date +%s%N` to `stamp`.
- [ ] **Step 2: Write failing bats tests:** `baseline.bats`: `test "append twice is a RERUN finding"`
  (exit 1, output has `RERUN: second run changed the workspace` and `list.txt`); `test "mkdir without -p
  is a RERUN finding"` (exit 1, `RERUN: second run failed`); `test "fixed scripts pass the baseline"`
  (exit 0); `test "nondeterministic script stops with exit 2"`; `test "failing reference stops with exit
  2"`; `test "script path and args with spaces and globs"` (script at `dir with space/s*.sh` given arg
  `a b*` writes `$1` to a file; the file holds exactly `a b*`); `test "no processes left after run"`
  (script starts `sleep 300 &`; afterwards `pgrep -f 'sleep 300'` finds nothing). `points.bats`: `test
  "points lists boundaries and externals"`; `test "points warns when DEBUG trap is replaced"`.
- [ ] **Step 3: Run** `zig build e2e`. Expected: FAIL.
- [ ] **Step 4: Implement** `session.zig` and the dispatch in `main.zig`.
- [ ] **Step 5: Run** `zig build test e2e` on macOS and Linux. Expected: PASS.
- [ ] **Step 6: Commit** `feat: add baseline points and rerun`

### Task 10: Checks and CI

**Files:**
- Modify: `flake.nix` (add `checks`)
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Produces: `nix flake check` runs `zig build test`, `zig build e2e`, `bats tests/preload` against every
  Bash in the matrix, and `shellcheck -x` over all shell files. CI runs `nix flake check` on
  `ubuntu-latest` and `macos-latest` for pushes and pull requests to `main`.

- [ ] **Step 1: Add the checks**, then break one shell file on purpose (an unquoted `$var`) and run
  `nix flake check`. Expected: FAIL naming that file. Revert the break.
- [ ] **Step 2: Run** `nix flake check` on macOS and Linux. Expected: PASS.
- [ ] **Step 3: Add the workflow** with `DeterminateSystems/nix-installer-action` and
  `DeterminateSystems/magic-nix-cache-action`.
- [ ] **Step 4: Commit** `ci: run flake checks on push`

## Execution notes

- Workers run on `vivianasus`, one git worktree per task, against a bare
  repository on that machine that the coordinator syncs with the Mac. Tasks 1 and 2 go first and in order;
  Task 3 runs alongside them; Tasks 4 to 8 can run in parallel worktrees once Task 2 is merged; Task 9
  needs 4 to 8; Task 10 is last.
- macOS-specific parts (Task 1 on Darwin, Task 5's process scan, Task 6's `clonefile`) are verified by the
  coordinator on the Mac before merge.
- The coordinator reruns every test command itself before merging a task, and checks commit subjects
  against the Global Constraints.
