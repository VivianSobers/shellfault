# Spike results

Throwaway experiments run on 2026-11-11 before building, to test the design's riskiest assumptions. Machines:
macOS 27.2 with the system Bash 3.2, Fedora 44 (kernel 7.0.10, Bash 5.3, btrfs), Ubuntu 24.04 (kernel 7.0.0,
Bash 5.2).

## S1: boundary IDs across subshells

A `DEBUG` trap with `set -T` that logs `BASH_SUBSHELL`, `BASHPID` (5.3) and `BASH_COMMAND`, run over
command substitution, `( )`, functions, pipelines, background jobs and process substitution.

| Construct | Where the trap fires | `BASH_SUBSHELL` |
|---|---|---|
| `x=$(echo B)`, `( echo C )` | in the child | 1 |
| function body | in the main process; the call fires twice (call and entry) | 0 |
| simple commands in a pipeline, `echo E \| cat` | in the main process, once per element, before each fork | 0 |
| simple command in the background, `echo F &` | in the main process, before the fork | 0 |
| compound command in a pipeline, `printf … \| while read …`, `{ a; b; } \| cat` | in the child, concurrently with the parent | 1 |
| compound command in the background, `{ …; } &` | in the child, concurrently | 1 |
| process substitution body, `<(echo G)` | in the child | 1 on 5.3, **0 on 3.2** |
| `while … done < <(…)` loop body | in the main process | 0 |

Results were the same on 3.2 and 5.3 apart from the process substitution row.

Decision: simple pipeline and background elements are ordinary boundaries of the main process, in order.
Children that run concurrently get IDs nested under the parent's current boundary. Two concurrent siblings
can then get the same ID, and on 3.2 a process substitution can collide with the main process's counter.
The engine therefore only offers a boundary as a crash point when its ID occurs exactly once in each of the
two reference traces with the same source, line and command. Everything else is counted and reported as
ambiguous, and is never the basis of a finding.

## S2: killing the run's process group from inside the trap

A runner started the target with job control (`set -m`), so the target led its own process group. The
target started `sleep 300 &`, then its `DEBUG` trap ran `kill -s SIG 0` before the third command.

| | macOS, Bash 3.2 | Fedora, Bash 5.3 |
|---|---|---|
| `KILL`: runner survives | yes, target status 137 | yes, 137 |
| `KILL`: command at the boundary and later ones | not run | not run |
| `KILL`: background `sleep` | dead | dead |
| `TERM`: same three checks | 143, not run, dead | 143, not run, dead |

Decision: the preload fires crash faults itself with `kill -s SIG 0`, as designed. With `TERM`, a script
whose `TERM` trap does not exit keeps running, which is realistic; the engine's grace period and `KILL`
cover it.

## S3: unprivileged namespaces and overlays on Linux

`unshare -Urmn` (user, mount and network namespaces) works without privileges on both machines. Ubuntu
24.04 has `kernel.apparmor_restrict_unprivileged_userns=0` on this machine, so AppArmor does not block it
here; a stricter Ubuntu default would.

An overlay with `/` as the lower layer fails with `EINVAL`. Mounting one overlay per top-level directory,
with upper and work directories on a tmpfs created inside the namespace, works for `/etc` on both machines.
A file written to `/etc` lands in the upper layer, can be listed by exact path, and never reaches the host.
Two problems remain:

- the overlay on `/var` fails to mount with `EINVAL` on both machines;
- `mkdir /usr/local/x` fails with `EPERM` although the `/usr` overlay mounted, most likely because copying
  up a directory owned by the host's root is not allowed from an unprivileged user namespace.

Decision: the `unshare` backend is feasible but needs its own investigation in milestone 5 (submounts,
copy-up of root-owned directories, possibly using `bwrap` or the full subordinate UID range). Until then the
`container` backend is the strong option on Linux.

## S4: `sandbox-exec` on macOS 27.2

`sandbox-exec` is still present. The profile has to deny first and allow after, because filters inside one
rule are combined with OR:

```
(version 1)
(allow default)
(deny file-write*)
(allow file-write* (subpath "<workspace>") (literal "/dev/null") (literal "/dev/tty") (regex #"^/dev/fd/"))
(deny network*)
```

With it, writes and `mkdir` inside the workspace, writes to `/dev/null` and command substitutions work; a
write to `$HOME` fails with `Operation not permitted` (exit 1) and `curl` cannot resolve hosts (exit 6). The
workspace path must be the resolved path (`/private/tmp/...`, not `/tmp/...`).

Decision: the `sandbox` backend works as designed. Denied writes surface as permission errors in the
script, so `ESCAPED` on macOS has to be inferred from those errors rather than from a diverted write.

## S5: copy-on-write cloning

A tree of 100 directories with 100 small files each (39 MB on APFS):

| | clone | plain copy |
|---|---|---|
| macOS APFS, `cp -c` (`clonefile`) vs `cp -R` | 0.68 s | 1.39 s |
| Fedora btrfs, `cp --reflink=always` vs `--reflink=never` | 0.23 s | 0.23 s |

Both clones were byte-identical to the source. For small files, cost is dominated by creating entries,
so cloning helps less than expected on btrfs. Decision: keep `clonefile`/`FICLONE` with a copy fallback as
planned. A single `clonefile(2)` call on the whole directory, instead of per-file clones, is likely faster
still on macOS and is worth measuring in Task 6.
