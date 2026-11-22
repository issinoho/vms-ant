# Decisions

D1-D5 agreed with the user 2026-11-22 ("Yes agreed"). The question at the end of D5
is still open.

## D1. Ant 1.10.18 on the nodes' Java 8; the Alpha later, with 1.9.16

1.10.18 (2026-09-03) is current and needs Java 8, which the x86-64 and IA64 nodes have (VSI
OpenJDK 8). The Alpha node has Java 1.5.0 only; Ant 1.9.16 (2021, the last 1.9) runs on
Java 5, so an Alpha kit would be a separate 1.9.16 track after 1.10.18 is released,
if wanted.

## D2. Source: upstream's signed binary distribution, patched class by class

As vms-maven's D2: start from `apache-ant-<v>-bin.tar.gz` (SHA-512 and Stefan
Bodewig's signature, key from Apache's KEYS file). A fix changes one class's source,
taken from the signed source distribution `apache-ant-<v>-src.tar.gz` (same signer);
BUILD.COM compiles it on the node against `lib/*.jar` and puts the class back into
`lib/ant.jar`. Patches are written to go upstream (guarded by `os.family openvms`).

## D3. Product ANT, ANT$ROOT

PCSI product ISSINOHO ANT with the concealed rooted logical ANT$ROOT;
kit ISSINOHO-<I64VMS|X86VMS>-ANT-V1.10-18E1-1.PCSI. Tags v1.10.18-vms<N>.

## D4. The launcher is a C image, ANT.EXE

For vms-maven's reasons (its D4, N4): a DCL procedure gets its parameters
upper-cased and at most eight of them, and Ant's targets and `-D` properties are
case-sensitive. ANT.EXE (from vms-maven's mvn.c) finds ANT$ROOT and Java, takes
ANT_OPTS and ANT_ARGS, sets VSI Java's three file-version logicals unless defined
(N2), and starts `org.apache.tools.ant.launch.Launcher` with vfork/execv, which
already finds lib/ and ~/.ant/lib itself.

## D5. Forks: the VM launcher, with Unix exit codes; DCL on request

VSI Java's `Runtime.exec` passes arguments intact and returns Unix exit codes (N5),
so it is the right default, as on every other platform. Patches to ant.jar:

1. `JavaEnvUtils`: `.exe` on OpenVMS, so `java`, `javac`, `javadoc`... are found (N4).
2. Forked `<java>` and `<javac>`: a normal command line instead of the `-V` option
   file, which splits arguments at spaces (N7). (Command-line length limits to be
   tested in Phase 2 with a long classpath; if they bite, keep `-V` for the
   classpath only.)
3. `Execute.isFailure` on OpenVMS: non-zero is failure, as elsewhere (N5).
4. `VmsCommandLauncher` (`vmlauncher="false"`, for DCL verbs and procedures): quote
   each argument and each DEFINE value, and end the procedure by turning `$STATUS`
   into 0 for success, so rule 3 holds for it too (N5, N6).
   As built (Phase 1): arguments are quoted only for white space or `!`, and one
   that has a `"` already is taken as written for DCL, so qualifiers (`/SIZE`) and
   DCL strings (`<arg value='"Two words"'/>`) still work; DEFINE values are always
   quoted. The procedure runs through ANTDCL.EXE (`-Dant.openvms.dclrunner`, set by
   ANT.EXE), because starting a procedure straight from VSI's JVM fails at random
   (N8) and its output reaches Java without line ends (N9).
5. `Execute.getVMSLogicals`: parse today's SHOW LOGICAL layout (N6).

Open for the user: whether `<exec executable="mms">` (a bare name that is a DCL verb
or a foreign command) should fall back to the DCL launcher on OpenVMS when no image
of that name is found. Without it, build files must say `vmlauncher="false"`.
