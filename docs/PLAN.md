# vms-ant: Apache Ant for OpenVMS, with a PCSI kit

## Goal

Apache Ant on x86-64 and IA64, on VSI OpenJDK 8, installed and removed with PRODUCT
INSTALL / PRODUCT REMOVE like the rest of the family, and used as elsewhere: `ant`
or `ant -f build.xml target` in a project directory. A sibling of vms-maven, and
built the same way (DECISIONS D2).

Ant is pure Java and already knows OpenVMS (os family `openvms`, a DCL command
launcher, `-V` option files), but that code was written for HP's Java and has
rotted (NOTES N3-N7). The work is the launcher, a handful of patched classes in
ant.jar, and the kit.

## Phase 0: feasibility (2026-11-22, done on x86-64)

PROBE.COM and tests/probe/build.xml, stock 1.10.18 on x86-64 (N1-N7): file tasks,
archives, in-process javac, jar and in-VM java work; directory deletes need VSI's
file-version logicals; every fork fails (no `.exe`), and the fork, exit-code and
environment code for OpenVMS is wrong for VSI Java. IA64 unreachable. Alpha: Java
1.5 only.

Exit: the user agrees D1-D5.

## Phase 1: repository, launcher, patches

- Family tooling from vms-maven: fetch.sh (bin + src tarballs, SHA-512 + signature),
  prepare.sh (unpacks the source files the patches touch), push.sh, build.sh,
  test.sh, vms.sh. BUILD.COM compiles the patched classes into lib/ant.jar
  (pristine copy in [.VMSPORT.PRISTINE]).
- ANT.EXE (D4).
- Patches 1-5 of D5, each with its probe target turned into a test.
- Smoke test (TEST_SMOKE.COM): the probe's targets as PASS/FAIL, plus ANT on a
  terminal and under the TRADITIONAL parse style.

Status 2026-11-22: done on x86-64 except ANT on a terminal. Tooling, ANT.EXE
(derived from vms-maven's mvn.c), ANTDCL.EXE (N8, N9), patches 0001-0005;
TEST_SMOKE.COM 15/15, twice, the second after BUILD CLEAN. IA64 still unreachable.

## Phase 2: Ant on real builds

- A multi-file project: javac with a long classpath (command-line limits, D5.2),
  junit/junitlauncher with forked tests, javadoc, `<parallel>`, `<exec>` of DCL
  procedures, `<sshexec>`-style optional tasks that need extra jars (document).
- File versions in output trees (N2): what builds leave behind; README advice.
- Two Ant runs at once; ~/.ant/lib; ANT_OPTS; CTRL/C and CTRL/Y (vms-maven N24).
- IA64 when it is reachable again.

## Phase 3: the kit

PCSI kit ISSINOHO ANT (D3): the distribution with the patched ant.jar, ANT.EXE,
ANT$STARTUP.COM, ANT$SETUP.COM (ANT symbol, needs Java), README.VMS; the manual
included. tools/kit.sh and tools/installcheck.sh on both nodes.

## Phase 4: release

The family release process: tag v1.10.18-vms1, GitHub release with both kits and
SHA256SUMS, entry in vms-grep/site/projects.json and the vms-grep README. Offer the
patches upstream (Ant Bugzilla), with vms-maven's Ant launcher report.

## Later

Alpha: Ant 1.9.16 on Java 1.5 (D1), if wanted.
