# shellfault design

Date: 2026-11-11
Status: draft, waiting for approval

## Intent

Shell scripts that change state (installers, provisioning, backups, deploys, migrations) are usually tested
by running them once to the end. In practice they get interrupted: Ctrl-C, a dropped SSH session, a full
disk, an OOM kill, a `curl` that fails halfway through. A script that is interrupted and then run again has
to reach the same end state as one clean run. Most scripts never get tested for that, and the resulting
bugs (stale lock files, half-written config, lines appended twice, `mkdir` that fails on the second run,
failures swallowed by `set -e` holes) show up on someone's server instead.

shellfault finds those bugs. It runs a Bash script once to record a reference end state. It then runs it
many more times, each time breaking it at a different point, and runs it again to completion to see whether
it recovers. Every failure it reports comes with a recorded case that can be replayed exactly.

The repository is also a portfolio project. It should show careful work with Bash internals (traps,
signals, subshells), systems programming (process groups, namespaces, copy-on-write cloning), and testing
methodology, and it should be useful enough that people outside the project run it.

## Goals

1. Crash testing: stop the script after each successive command boundary, rerun it, and compare the
   recovered end state with the reference.
2. Failure injection: make one call to an external command fail, observe whether the script reports the
   failure, then rerun it and compare.
3. Isolation: never let a trial touch real system state by default, and account for side effects outside
   the workspace instead of ignoring them.
4. Reproducibility: every finding records the fault location, the command, the execution context and the
   resulting state, and `shellfault replay` reproduces it.
5. Programmable scenarios: users describe fixtures, state rules, stubs and which faults to try in Lua.
6. Usable in CI: one command, an exit code that fails the build on findings, machine-readable reports.

## Non-goals

- POSIX `sh`, dash, zsh or ksh scripts. Bash only for now; other shells can come later.
- Checking that a script is correct when nothing goes wrong. That is the job of bats and the user's own
  tests. shellfault does not replace bats or ShellCheck.
- Repairing scripts or suggesting fixes.
- Power-loss and durability testing. Killing a process leaves the page cache intact, so shellfault cannot
  find missing `fsync` bugs. Tools such as LazyFS cover that.
- Stopping a script in the middle of a single external command (for example after `cp` has written half a
  file). v1 works at command boundaries only; see "Later".

## Anti-goals

These would make the project a failure even if it technically works.

- Reporting a bug that replay cannot reproduce. A false positive costs the tool its credibility, so any
  trial whose run diverged from the reference before the fault point is reported as inconclusive, never as
  a bug.
- Damaging the machine it runs on. Safe defaults come first: effectful commands are stubbed, containment is
  on wherever the platform supports it, and running as root without containment is refused.
- Requiring the user to rewrite or annotate their script. Instrumentation is injected from outside.
- Being too slow to use. A 200-line script should finish its default run in minutes, not hours.
- Being hard to install. Users get one static binary per platform; they do not need Zig, Lua or Nix.

## Constraints

- macOS is the primary development machine. Linux support is a first-class target, tested on Fedora 44
  (Bash 5.3), Ubuntu 24.04 (Bash 5.2) and Ubuntu 22.04 (Bash 5.1).
- The macOS system Bash is 3.2, and scripts must be testable under it.
- Zig is pinned to one exact version, 0.17.1 (the current release on 2026-11-11). Fedora packages 0.16.0, so
  the pin comes from the Nix flake, not from distribution packages. Zig's standard library changes between
  releases, so code is written against the pinned version's sources, not against older examples.
- Which language GitHub shows as the main one does not matter (owner, 2026-11-11).
- Commit rules: `<type>: <4-6 word description>`, subject only, the owner as sole author, no trailers.

## Stack

Owner's decision (2026-11-11): Bash, Zig, Lua and Nix.

| Part | Language | Why this language |
|---|---|---|
| Instrumentation preload and stub runtime | Bash, 3.2 compatible | it runs inside the target script, so it has to be Bash |
| Engine and CLI: orchestration, process supervision, cloning, state capture, comparison, cases, reports, containment | Zig 0.17.1 | direct system calls (`setpgid`, `clonefile`, `FICLONE`, `unshare`, `mount`), fast hashing, real parallelism, one static binary |
| Scenarios | Lua 5.4, embedded in the engine | a small, safe language for fixtures, rules, oracles and search policy; no interpreter for users to install |
| Dev environment, pinned toolchain, Bash version matrix, builds | Nix flake | the same Zig, Bash versions, bats and ShellCheck on macOS, Linux and CI |
| Tests | Zig tests for the engine, bats-core for end-to-end behavior | |

The Lua interpreter is compiled from the upstream Lua 5.4 C sources by `build.zig`, fetched as a pinned
dependency in `build.zig.zon`, so the repository does not vendor C code. The engine embeds the preload and
stub runtime with `@embedFile` and writes them into the session directory at startup, so the release is a
single file.

## How it works

### Instrumentation (Bash)

shellfault never edits the target script. The engine sets `BASH_ENV` to the preload file, so any
non-interactive Bash it starts (the target, and Bash scripts the target calls) sources the preload first.
The preload:

- installs a `DEBUG` trap with `set -T`, so the trap also fires inside functions and subshells;
- gives every command boundary a stable ID (described below), and in the reference run appends one trace
  line per boundary: ID, `BASH_SOURCE`, `LINENO`, the `FUNCNAME` stack and `BASH_COMMAND`;
- in a fault trial, checks each boundary against the target and fires the fault when it matches;
- defines the wrapper functions used for failure injection and stubs;
- seeds `RANDOM` from the run seed, while the engine sets `TZ=UTC`, `LC_ALL=C` and `SOURCE_DATE_EPOCH` in
  the run's environment, so that runs are as deterministic as possible.

The engine and the preload talk through environment variables (`SF_*`) and files in a per-run control
directory: the trace, the fault record, and the effects journal. The preload never reads anything it did
not get from the engine.

The preload must work under Bash 3.2. A probe on 2026-11-11 confirmed that 3.2 and 5.3 behave the same for
the features used: `DEBUG` with `set -T` in subshells and command substitutions, and functions named by
absolute path (`/bin/cp() { ...; }`). The same probe showed that `extdebug`-based command skipping is
unreliable (`return` inside the trap returns from the enclosing function), so the design does not use it.

### Boundary IDs

A plain counter does not work, because a subshell's increments are lost when it exits and a fork copies the
parent's count. Each boundary is identified by its lineage: the boundary index in the top-level process,
then, for code running in a subshell, the parent boundary that created it and the index inside the
subshell. For example, `14` is the 14th command of the script, and `14/3` is the 3rd command inside a
command substitution started by command 14.

v1 crash points cover the top-level process and subshells that run while the parent waits (`$(...)`,
`( ... )`, functions). Pipeline elements and background jobs run concurrently, so their order is not
deterministic. In v1 they are not crash points themselves; they are killed together with their process
group. Child Bash scripts started by the target count as one external command in v1.

Because loops repeat lines, one source line can produce thousands of boundaries. The default selection
policy tests the first and last occurrence of each source location and reports how many it skipped.
`--exhaustive` tests all of them, `--sample N --seed S` tests a reproducible random subset, and a scenario
can replace the policy with a Lua function.

### Runs and trials (Zig engine)

A test session goes through these steps:

1. **Fixture.** Build the initial state once: a copy of a fixture directory, or the scenario's fixture
   function, or an empty directory. Each trial gets its own copy, cloned copy-on-write where the filesystem
   supports it (`clonefile` on APFS, the `FICLONE` ioctl on Btrfs and XFS) and copied otherwise.
2. **Reference.** Run the script twice from fresh copies. If the two end states differ after the scenario's
   ignore and normalize rules, stop and show the difference, because a script that is nondeterministic on
   its own cannot be crash-tested until the user adds rules or stubs.
3. **Rerun check.** Run the script a second time on top of a reference end state. If that run fails or
   changes the state, report `RERUN`. This catches the most common bug for almost no cost.
4. **Trials.** For each selected fault, start from a fresh copy, run the script with the fault armed, then
   run it again with no fault (the recovery run), and capture the end state.
5. **Verdict and record.** Compare the recovered end state with the reference, assign a verdict, and write
   a case directory if the verdict is not `PASS`.

The reference runs, the rerun check, faulted runs and recovery runs all use the same workspace setup, stubs
and containment, so differences come from the fault and nothing else.

The engine starts every run in a new process group (`setpgid` between fork and exec) and enforces a
timeout per phase. When a phase ends, it kills the whole group. On Linux it also marks itself a child
subreaper (`PR_SET_CHILD_SUBREAPER`), so daemons that double-fork out of the group still come back to it
and get killed. macOS has no subreaper, so there the engine finds leftovers by an `SF_RUN_ID` marker in their
environment and reports any it cannot kill. A session must never leave processes behind. Trials run in
parallel with `-j N`, each in its own workspace and process group.

### Crash mode

A crash fault at boundary N fires in the trap that runs just before command N, so commands before N have
finished and command N never starts. One extra point, `end`, fires after the last command and before the
`EXIT` trap. The preload writes the fault record, then signals its own process group. The signal is
configurable:

- `KILL` (default): nothing in the script gets to run, the same as an OOM kill or a `kill -9`.
- `TERM`, `INT` or `HUP`: the script's own traps run, which tests cleanup handlers. If the group is still
  alive after a grace period, the engine sends `KILL`.

### Failure-injection mode

From the reference trace, the engine knows every external command the script ran and how many times. For a
failure trial targeting call k of command `cp`, the preload defines a wrapper function `cp` (and `/bin/cp`
and similar absolute paths when the trace shows them) that counts calls. On call k it fails. Two kinds of
failure are available:

- `before` (default): the command does not run and returns a nonzero status (default 1) with an error
  message on stderr;
- `after`: the command runs, then the wrapper returns a nonzero status anyway, which simulates a command
  that did its work but reported an error, such as a timeout after a write.

Wrappers only catch calls the instrumented Bash makes by name or path. Calls through `command`, `exec`,
`env`, `xargs` or `find -exec`, and calls made by non-Bash child processes, are not intercepted in v1. The
report lists the external commands it saw but could not wrap.

### Verdicts

| Verdict | Meaning | Modes |
|---|---|---|
| `PASS` | the recovered state matches the reference, and in failure mode the failure was reported or handled | both |
| `SILENT` | the faulted run exited 0 although a command failed and the state was wrong | failure |
| `STUCK` | the recovery run exited nonzero | both |
| `DRIFT` | the recovery run exited 0 but the state differs from the reference | both |
| `DOUBLE` | an effect declared "once" happened more than once across the faulted and recovery runs | both |
| `ESCAPED` | the trial wrote outside its workspace (where containment can detect it) | both |
| `DIVERGED` | the trial's trace did not match the reference before the fault point; inconclusive, not a bug | both |
| `TIMEOUT` | a phase ran past its time limit | both |
| `RERUN` | a second run over a finished state failed or changed it | baseline |

`SILENT`, `STUCK`, `DRIFT`, `DOUBLE`, `ESCAPED` and `RERUN` are findings and make the exit code nonzero. A
scenario's `check` function (see "Scenarios") can turn a verdict the engine computed into `PASS` or into a
finding, for scripts whose correct end state is not simply "equal to the reference".

### State capture and comparison

The end state of a trial has three parts:

1. A manifest of the workspace: for each path, its type, mode, size, SHA-256 of the content, and symlink
   target. Modification times are left out by default.
2. Probe output: commands the scenario declares, whose stdout counts as state. Examples are
   `sqlite3 app.db .dump` and `crontab -l` run against a stub.
3. The effects journal (next section).

Each run has its own workspace path, and scripts often write absolute paths into files (a `PATH` line in
`~/.profile`, a config file, a symlink). Before hashing, the engine therefore replaces every occurrence of
the run's workspace path, as given and as resolved (macOS resolves `/var` to `/private/var`), with a fixed
token in file contents and symlink targets, so two equivalent runs compare equal. Scenarios can also ignore
paths by glob and can pass a file's content through a Lua normalizer before hashing, for files that contain
timestamps or PIDs. Diffs report added, removed and changed paths, with a unified
diff for small text files.

## Isolation and side effects

A directory snapshot cannot capture everything a script does, so isolation has three layers.

### Layer 1: the workspace (all platforms)

Each trial runs in its own directory under the session's output folder. `HOME`, `TMPDIR` and the `XDG_*`
directories point inside it, and the script's working directory is the workspace. Scripts that only touch
paths relative to these are fully covered by layer 1.

### Layer 2: stubs and the effects journal (all platforms)

Commands that act on the world outside the workspace (`curl`, `wget`, `ssh`, `scp`, `git push`, `systemctl`,
`apt-get`, `dnf`, `brew`, `docker`, `useradd`, `crontab`, `sudo` and so on) are stubbed during trials by
default. A stub does not run the real command. It appends the call (argv, working directory and a hash of
stdin) to the effects journal, prints scripted output if the scenario provides some, and returns 0.

Stubs can be stateful. A scenario can point a stub at a Bash file that defines it as a function keeping its
state in the workspace, such as a fake `useradd` that fails if the user already exists in a fake passwd
file. In this way the outside system becomes part of the compared state, and a script that runs `useradd`
twice after a crash fails the same way it would on a real machine. v1 ships the generic recording stub and
lets scenarios define their own. Built-in models for common commands come later.

Scenarios mark some effects as `once`, for example sending an email, charging a card or posting a release.
If a `once` effect appears more than once across a faulted run and its recovery run, the verdict is
`DOUBLE`.

The stub list is a default deny list plus the scenario's own entries. `--allow CMD` lets a real command
through, for instance a local `git commit` inside the workspace.

### Layer 3: containment (platform dependent)

| Backend | Platform | What it does |
|---|---|---|
| `none` | any | layers 1 and 2 only |
| `unshare` | Linux | the engine calls `unshare(2)` for user, mount and network namespaces and mounts the root filesystem as an overlay with a writable upper layer; writes outside the workspace land in the upper layer and are reported as `ESCAPED` with exact paths |
| `container` | Linux, macOS with Docker or Podman | runs the trial in a container from a chosen image; for scripts that need real package managers |
| `sandbox` | macOS | runs the trial under `sandbox-exec` with a generated profile that denies writes outside the workspace and denies network; writes outside fail with a permission error instead of being diverted |

The default is `unshare` on Linux and `sandbox` on macOS, each falling back to `none` with a warning if a
check at startup fails. shellfault refuses to run as root with the `none` backend unless `--unsafe` is given.

Two risks need spikes before the backends are built. Ubuntu 24.04 restricts unprivileged user namespaces
through AppArmor, so `unshare` may fail there without a profile. `sandbox-exec` is deprecated but still
present on macOS 27.2 (checked 2026-11-11), and its behavior has to be confirmed.

## Scenarios (Lua)

A scenario is a Lua file, by convention `shellfault.lua` next to the script. The engine runs it in a
sandboxed Lua state: no `os.execute`, `io.popen`, `load` of binary chunks or file access outside the
scenario's directory. Every hook is optional.

```lua
return {
  script  = "install.sh",
  args    = { "--prefix", "$HOME/.local" },

  -- initial state: a directory to copy, or a function using the sf API
  fixture = function(sf)
    sf.mkdir("etc"); sf.copy("fixtures/app.conf", "etc/app.conf")
  end,

  ignore    = { "var/log/*", "*.pid" },
  normalize = {
    ["etc/app.conf"] = function(text) return (text:gsub("generated=[^\n]*", "generated=X")) end,
  },
  probes    = { db = "sqlite3 var/lib/app/db.sqlite .dump" },

  stubs     = {
    useradd = { bash = "stubs/useradd.bash" },   -- stateful stub written in Bash
    curl    = { stdout = "ok\n" },               -- recording stub with scripted output
  },
  once      = { { cmd = "curl", match = "-X POST https://hooks%.example%.com/" } },
  optional  = { { cmd = "curl", match = "https://stats%.example%.com/" } },

  -- which faults to try, given every point and call from the reference run
  select = function(points, calls) return points:first_and_last_per_line(), calls:all() end,

  -- override a verdict for scripts whose correct end state is not "equal to the reference"
  check = function(trial) if trial.verdict == "DRIFT" and trial.diff:only("cache/*") then return "PASS" end end,
}
```

`optional` marks calls whose failure the script may tolerate with a different end state. For those calls
the faulted run is not judged (`SILENT` is not reported), but the recovery run must still reach the
reference. Patterns are Lua patterns.

## Reproducibility

Every non-`PASS` trial writes a case directory:

```
cases/0007-crash-KILL-14_3/
  case.json         record of the trial (below)
  fixture.sha256    hash of the initial state
  trace.log         boundary trace of the faulted run, up to the fault
  faulted.out       stdout and stderr of the faulted run
  recovery.out      stdout and stderr of the recovery run
  effects.log       effects journal
  state.manifest    end-state manifest
  state.diff        difference from the reference
  workspace/        the recovered workspace, kept with --keep
```

`case.json` holds the shellfault version and git commit, the Bash path and version, the OS and kernel, a
hash of the scenario file, the mode, the signal or the failure kind and exit status, the boundary ID, the
source file and line, the function stack, the command text, the external command and call number (failure
mode), the seed, the time limits and an environment snapshot. Variables whose names match `*TOKEN*`,
`*SECRET*`, `*PASSWORD*` or `*KEY*` are redacted, because cases are meant to be shared in bug reports.

`shellfault replay CASE` rebuilds the fixture, runs the same trial and checks that it reproduces the same
verdict and the same diff. A replay that does not reproduce is reported as flaky. `--shell` opens a shell
in the workspace at the moment of the crash or at the end of the recovery run, for inspection.

## Command-line interface

```
shellfault run [options] [SCRIPT] [-- ARGS...]
    -f, --scenario FILE      Lua scenario (default ./shellfault.lua if present)
        --fixture DIR        initial state to copy, when there is no scenario
    -m, --mode MODE          crash | fail | both (default both)
    -s, --signal SIG         KILL | TERM | INT | HUP (crash mode, default KILL)
    -j, --jobs N             trials run in parallel, each in its own workspace
        --exhaustive         test every boundary, not first and last per source line
        --sample N --seed S  test a reproducible random subset
        --contain BACKEND    none | unshare | container | sandbox
        --allow CMD          let a stubbed command run for real
        --timeout SECONDS    per phase
        --bash PATH          Bash used to run the target (default: the script's shebang)
    -o, --out DIR            session output (default ./shellfault-out)
        --keep               keep workspaces of failing trials
        --format FMT         text | tap | junit | json
shellfault points [SCRIPT]   list the crash points and external calls from a reference run
shellfault replay CASE [--shell]
shellfault report DIR        summarize a finished session
```

Exit status: 0 if there are no findings, 1 if there are findings, 2 for usage or setup errors.

## Testing the tool

Development is test-first. The main acceptance suite is a corpus of small scripts with known bugs, each
paired with a fixed version:

- writing a config file in place instead of to a temporary file and `mv`;
- a lock file that is never removed after a kill;
- `>>` appends that duplicate lines on rerun;
- `mkdir` without `-p`, and `ln -s` without `-f`, on rerun;
- a failure hidden by `set -e` inside `$(...)` or a function called in a condition;
- a `trap` that cleans up on `EXIT` but not on `TERM`;
- a download piped into a file that is then used even if the download failed;
- a non-idempotent effect that should be marked `once`.

Each buggy script must get its expected verdict, and each fixed one must get `PASS`. These run as bats
tests against the built binary. The engine's units (manifest, diff, boundary-ID parsing, selection, case
format, verdict logic) have Zig tests. Process tests check that no process outlives a session, including a
script that double-forks a daemon. ShellCheck must pass on all Bash code.

`nix flake check` builds the engine and runs both suites, with the preload tested under Bash 3.2, 4.4, 5.1,
5.2 and 5.3. CI runs it on GitHub's Ubuntu and macOS runners. The owner's Fedora and Ubuntu machines are
used for the Linux containment backends.

## Distribution

Releases are static binaries built by `zig build` cross-compilation for `x86_64` and `aarch64` on Linux
(musl) and macOS, attached to GitHub releases. `nix run github:VivianSobers/shellfault` also works. Users
need Bash on the machine, nothing else.

## Milestones

Each milestone ends in something that works and is committed in small steps.

0. Toolchain and spikes. The flake with Zig 0.17.1, Bash versions, bats and ShellCheck; `build.zig` that
   compiles embedded Lua and an empty CLI. Throwaway spikes: boundary IDs across subshells on 3.2 and 5.x;
   killing the run's process group from inside the trap on macOS and Linux; `unshare` with an overlay on
   Fedora and on Ubuntu 24.04; `sandbox-exec` write denial on macOS 27; `clonefile` and `FICLONE` speed.
1. Preload, process supervision, reference run, trace ingestion, state manifest, `shellfault points`, the
   `RERUN` check.
2. Crash mode, verdicts, case directories, `replay`.
3. Failure-injection mode. Release v0.1.
4. Lua scenarios: fixtures, ignores, normalizers, probes, stubs, `once` and `optional`, the effects journal,
   `select` and `check`.
5. Containment backends.
6. Parallel trials, sampling, TAP, JUnit and JSON reports, a GitHub Action wrapper, release builds.
   Release v0.2.
7. Run shellfault on well-known open-source install and setup scripts, report what it finds upstream, and
   lead the README with those findings.

## Later

- Crashes inside a single command at the system-call level, after the k-th `write` (Linux, seccomp user
  notification or ptrace in the engine).
- Pipelines, background jobs and child Bash scripts as crash points (`--deep`).
- PATH-level shims so that calls from non-Bash child processes can be failed and stubbed.
- Built-in stateful models for common commands (`useradd`, `systemctl`, `crontab`, package managers).
- Search strategies beyond first and last per line, such as coverage-guided selection of crash points.
- POSIX `sh` and other shells.

## Left to the builder

- The exact encoding of boundary IDs, the trace format and the `case.json` fields.
- The engine's module layout and the Lua API's exact function names.
- How the Lua sandbox is set up.
- The default deny list of effectful commands, beyond the examples above.
- The real-world scripts used for milestone 7.
