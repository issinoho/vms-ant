# CLAUDE.md

Guidance for working in this repository: a port of Apache Ant to OpenVMS (x86-64 and
IA64) that stores only our changes over the upstream binary distribution, the same
way as vms-maven. Read docs/PLAN.md first; docs/DECISIONS.md and docs/NOTES.md hold
what has been proposed, settled and found.

## Ground rules

- **Never edit `staging/`, `cache/` or `out/`.** They are regenerated. Every VMS change is
  either a patch (`patches/NNNN-*.patch`, listed in `patches/series`) or a new file in
  `overlay/`.
- **Ant is Java: a patch changes the source of a class in lib/ant.jar**, taken from the
  signed source distribution; it is compiled on the node (no JDK on the laptop). Guard
  VMS-only behaviour with `Os.isFamily("openvms")` so it can go upstream.
- **Committed files must not contain real node details.** Use `<ia64-host>`, `<x86-host>`
  and `DISK$USER:[USERNAME.VMS_ANT]`. Real values live only in the git-ignored
  `tools/nodes.conf`.

## Commands (Phase 0)

```sh
tools/push.sh <node>             # upload staging/apache-ant-<v>/ (changed files only)
tools/vms.sh <node> batch <file.com>   # e.g. @[...VMSPORT]PROBE.COM "targets" LOGICALS TRADITIONAL
```

## VMS and Java pitfalls

- **Java takes Unix paths only** (`/DISK$USER/USERNAME/...`).
- **The JDK's images are `JAVA.EXE`, `JAVAC.EXE`...**: a bare `java` cannot be run (N4).
- **A forked program's exit value is a Unix exit code** through the VM launcher, the low
  byte of the VMS status through the DCL launcher (N5).
- **Java deletes only the newest version** unless JAVA$DELETE_ALL_VERSIONS is TRUE (N2).
- **`'sym'` substitution of a symbol starting with `$` in a PIPE** reads as a label: run
  foreign-command symbols by name.
- **A batch job starts in SYS$LOGIN**, not the work directory: procedures set their own
  default from `f$environment("procedure")`.
- From the family: use `tools/vms.sh`, never raw `ssh`; never `WAIT` over ssh; never edit
  a running bash script; kill by explicit PID.

## Commits

Commit in logical steps with messages that explain the VMS reason for each change. Don't
push without the user asking.
