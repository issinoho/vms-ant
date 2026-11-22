# Notes

Findings, numbered so commits and patches can refer to them. Probe logs are from
overlay/vmsport/PROBE.COM with tests/probe/build.xml.

## N1. Stock Ant 1.10.18 runs on VSI OpenJDK 8 (x86-64, 2026-11-22)

OpenVMS x86-64 E9.2-4, VSI OpenJDK 1.8.0_502, batch job without privileges.
Started as `java "-Dant.home=<unix home>" -classpath <home>/lib/ant-launcher.jar
org.apache.tools.ant.launch.Launcher`, the distribution unchanged:

- `-version`, os family `openvms` is detected (`os.name=OpenVMS`), java.home is
  `/<sysdisk>/SYS0/SYSCOMMON/openjdk$80/jre`, user.home `/DISK$USER/username`.
- mkdir, copy, move, touch, replace, loadfile, pathconvert: case is kept
  (`MixedCase.txt`).
- zip, tar (gzip), unzip, untar, checksum: round trips, `Deep.Name.txt` becomes
  `Deep^.Name.txt` on disk and comes back as written.
- In-process `<javac>` (tools.jar from the JDK), `<jar>` twice over the same jar,
  in-VM `<java>` with `MixedCase Arg` (one argument, case kept).
- `<get>` over HTTPS from Maven Central (the JDK's cacerts).
- Exit status: `%X10000001` after BUILD SUCCESSFUL, `%X1035A00A` (error, Java's
  exit 1) after BUILD FAILED. DCL `$SEVERITY` tells them apart.
- Every Ant start takes about 8 seconds of the job's time (JVM start-up).

IA64 not tried: the node had no route (same as vms-maven N24). Alpha has only Java
1.5.0 (`JAVA$150_SETUP`), which 1.10.x cannot run (it needs Java 8).

## N2. Deleting a directory: Java deletes only the newest version

`<copy overwrite="true">` onto an existing file creates `;2`. `<delete dir>` then
removed `;2`, left `;1`, and failed: "Unable to delete directory .../out/files/a/b".
With VSI Java's `JAVA$DELETE_ALL_VERSIONS`, `JAVA$RENAME_ALL_VERSIONS` and
`JAVA$CREATE_DIR_WITH_OWNER_DELETE` defined TRUE (as vms-maven's MVN.EXE does, its
N15), the same target passes twice running. Writing a file that exists
(`<echo file>`) still adds a version (`MixedCase.txt;2` after a second run), which
only a directory version limit prevents.

## N3. Every fork goes through Runtime.exec, not VmsCommandLauncher

`Execute`'s constructor turns off the VM launcher on OpenVMS, so Ant would write
an `ANTnnnn.COM` and run that. But `<exec>` (ExecTask: `vmlauncher` defaults to
true), forked `<java>` (`ExecuteJava.setupCommandLineForVMS`: `setVMLauncher(true)`)
and forked `<javac>` (`DefaultCompilerAdapter`) all set the VM launcher back on.
So on VSI Java every fork is `Runtime.exec` of the command as given. Only Ant's own
uses of `Execute` (the environment, N6) get the DCL launcher.

## N4. java, javac and the other JDK tools are not found (no .exe)

`JavaEnvUtils.getJreExecutable/getJdkExecutable` look for `java.home/bin/java`;
the file is `JAVA.EXE`, and `addExtension` adds `.exe` only on DOS. Ant falls back
to the bare name, and VSI Java cannot run it: `<java fork>` and `<javac fork>` fail
with "Cannot run program "java" ... Child java creation error: no such file or
directory". By full path both work: `<exec executable="${java.home}/bin/java.exe">`,
`<javac fork executable="${java.home}/../bin/javac.exe">`.

## N5. The VM launcher on VSI Java: arguments intact, Unix exit codes

`Runtime.exec` of `JAVA.EXE` by path passed `MixedCase Arg`, `a/b` and `it's "q"`
through intact, under both the EXTENDED and the TRADITIONAL parse style. The exit
value is the program's own: System.exit 0, 1, 2, 3, 44 came back as 0, 1, 2, 3, 44.

Ant's `Execute.isFailure` on OpenVMS is "even is failure" (written for HP's Java,
which returned VMS statuses), so today a program that succeeds (0) is logged
"Result: 0" as a failure (and fails the build with `failonerror`), and exit 1 or 3
counts as success. The DCL launcher, by contrast, returns the low byte of the
VMS status: WRITE gave 1, `%DIRECT-W-NOFILES` 144, `%DCL-W-NOCOMD` 212. One rule
cannot serve both as they stand.

## N6. VmsCommandLauncher: DCL works, paths and quoting do not; environment empty

`<exec executable="write" vmlauncher="false">` with `sys$output` and `"Exec Works"`
printed `Exec Works`; `<env key="ANT_PROBE_VAR" value="Has Space"/>` became a
process logical with its space. A Unix path as the command (`/DISK$.../java.exe`)
gives `%DCL-W-NOCOMD`, and arguments are written unquoted (DCL splits and
upper-cases them; vms-maven docs/upstream/ant-vms-launcher-quoting.md).

`<property environment="env"/>` defines nothing: Ant runs `SHOW LOGICAL` and its
parser (`Execute.getVMSLogicals`) expects lines starting with two spaces and a
quote; today's DCL indents with three (`   "SYS$LOGIN" = "DISK$USER:[username]"
(LNM$JOB_...)`).

## N7. Forked java and javac: the -V option file splits arguments

On OpenVMS Ant passes a forked JVM's (and javac's) arguments in a file named by
`-V`, a switch of HP's JVM. VSI's JAVA.EXE still accepts it, but splits each line
at spaces: a line `Opt File` arrived as two arguments `[Opt] [File]`. javac by full
path through `-V` compiled the probe (its arguments have no spaces).

## N8. Exit values of a DCL procedure, and a start-up race (x86-64, 2026-11-22)

`<exec executable="x.com">` (the VM launcher: VSI Java passes the procedure to the
C RTL's execv, `JAVA$EXEC_TRACE` shows it) gives these exit values:

| Procedure ends with | exitValue |
|---|---|
| `$ EXIT 1`, `$ EXIT %X10000001` | 0 |
| `$ EXIT %X1035A002 + 8 * n` (the C RTL's code for exit(n)) | n |
| `$ EXIT 3` | 3 |
| `$ EXIT %X00018290` (`%DIRECT-W-NOFILES`) | 144 |
| `$ EXIT %X00038090` | 220 |
| end of file, or a bare `$ EXIT`, after a successful command | 1 |

So only an explicit `EXIT 1` reads as 0; a procedure that just ends after a success
gives 1. **And starting a procedure fails at random**: DCL cannot open its input,
`%DCL-E-OPENIN, error opening _MBAnnnn:[<default dir>].; as input`,
`-RMS-F-DEV`, exit value 196. A two-line procedure (WRITE, EXIT 1) started 15 times
in a row failed 9 times, with or without `inputstring=""`; the same contents never
mattered. Images (JAVA.EXE) started the same way never failed. VmsCommandLauncher
always runs a procedure, so every DCL `<exec>` is hit.

Consequence for D5.4: VmsCommandLauncher runs its procedure through ANTDCL.EXE,
an image beside ANT.EXE that Java starts reliably; it runs the procedure with
LIB$SPAWN and returns 0 for a success status, else a non-zero Unix code. To find
out: whether the race is the C RTL's (execv of a procedure from a plain C program)
or VSI Java's, for a report to VSI.

## N9. DCL output in Java's pipe: no line ends, and an empty record ends it

A procedure that ANTDCL.EXE (first version) ran with its output going straight to
the pipe Java reads (the mailbox `getname(1)` named) reached Ant without line ends
(`SYS$LOGIN` line and the next text joined), and `SHOW LOGICAL` with no argument,
which starts with an empty line, gave no output at all: VSI's C RTL reads a
zero-length mailbox record as end of file. The same procedure through
`PIPE antdcl x.com | SEARCH SYS$PIPE ...` was complete. (Output to a file through
PIPE also failed: getname() gave `SYS$OUTPUT:.;`, which LIB$SPAWN refuses.)
ANTDCL.EXE now gives the subprocess a mailbox of its own and copies each record
to its standard output with a line end, an empty record as an empty line; the end
is an end-of-file it writes itself when the subprocess has ended (one DCL may
write before that is skipped).

## N10. A bare DCL verb or symbol in <exec> (patch 0006, x86-64, 2026-11-22)

With patch 0006, `<exec executable="show"><arg value="time"/></exec>` and
`<exec executable="directory">` with `/nohead /notrail build.xml` run as DCL
commands without `vmlauncher="false"`, and a failing DIRECTORY gives a failure
code. `vmlauncher="true"` given keeps the VM launcher (the start fails as
before). A global foreign-command symbol defined in the job before ANT runs
(`ANTSMOKESYM == "write sys$output ""from a symbol"""`) works as an executable:
ANTDCL.EXE's LIB$SPAWN copies the symbols of its process, so the job's symbols
reach it through ANT.EXE, Java and ANTDCL.EXE. Smoke 17/17.

## N11. ANT on a terminal (x86-64, 2026-11-22)

tools/ttytest.sh (from vms-maven's, an ssh pseudo-terminal checked with pyte):
14/14. Output comes a whole line at a time with no escape sequences; DCL commands'
output (through ANTDCL.EXE) shows in Ant's `[exec]` lines. CTRL/C and CTRL/Y while
Ant waits in Java (`<sleep>`), and CTRL/C while it waits in a DCL command (`WAIT`
under ANTDCL.EXE's subprocess), all end the build: Java exits 130 (ANT.EXE's wait
status `%X00008200`), and no subprocess is left (OpenVMS deletes ANTDCL's with
Java). DCL has CTRL/Y back afterwards. `$STATUS` at the prompt was `%X00030001`
each time: DCL acts on the key once the image has ended (vms-maven N24), so it is
shown, not checked.
