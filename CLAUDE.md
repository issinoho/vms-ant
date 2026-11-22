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

## Commands

```sh
tools/prepare.sh                 # always first after changing patches/ or overlay/
tools/build.sh <x86|ia64> [ALL|CLEAN]  # ANT.EXE, ANTDCL.EXE, patched lib/ant.jar
tools/test.sh <node>             # TEST_SMOKE.COM as a batch job (out/smoke-<node>.log)
tools/push.sh <node>             # upload staging/ (changed files; PUSH_MANUAL=1 adds manual/)
tools/vms.sh <node> batch <file.com>   # e.g. @[...VMSPORT]PROBE.COM "targets" LOGICALS TRADITIONAL TRACE
```

Patches change `vmsport/src/ant/<package path>.java` (from the source tarball's
`src/main/`); make them with `diff -u a/<path> b/<path>`, a `Subject:` line and the
reason above the diff. `ANT_VMS_TRACE` makes ANT.EXE and ANTDCL.EXE show what they run;
`JAVA$EXEC_TRACE` shows every process Java starts; a `<script language="javascript">`
target (Java 8's Nashorn) can call Ant's classes directly to debug.

## VMS and Java pitfalls

- **Java takes Unix paths only** (`/DISK$USER/USERNAME/...`).
- **The JDK's images are `JAVA.EXE`, `JAVAC.EXE`...**: a bare `java` cannot be run (N4).
- **A forked program's exit value is a Unix exit code** through the VM launcher, the low
  byte of the VMS status through the DCL launcher (N5).
- **Java deletes only the newest version** unless JAVA$DELETE_ALL_VERSIONS is TRUE (N2).
- **A DCL procedure started straight from Java fails at random** (%DCL-E-OPENIN, N8), and
  its output reaches Java without line ends, an empty record ending it (N9): DCL goes
  through ANTDCL.EXE.
- **`st = $status` resets `$SEVERITY`**: take the severity from `st .and. 7`.
- **A DCL line has a token limit** (%DCL-W-TKNOVF): long file lists go in an @argfile.
- **`'sym'` substitution of a symbol starting with `$` in a PIPE** reads as a label: run
  foreign-command symbols by name.
- **A batch job starts in SYS$LOGIN**, not the work directory: procedures set their own
  default from `f$environment("procedure")`.
- From the family: use `tools/vms.sh`, never raw `ssh`; never `WAIT` over ssh; never edit
  a running bash script; kill by explicit PID.

## Commits

Commit in logical steps with messages that explain the VMS reason for each change. Don't
push without the user asking.
