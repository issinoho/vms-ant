$! VMS_INSTALLCHECK.COM <tree-dir-name> <INSTALL|SMOKE|REMOVE> - install the ANT
$! kit and verify it, run the smoke test against the installed ANT, then remove it.
$! INSTALL and REMOVE change the system (PCSI database, SYS$COMMON:[ANT],
$! SYS$STARTUP:ANT$STARTUP.COM, the system logical ANT$ROOT); REMOVE leaves it
$! as it was.  tools/installcheck.sh runs the three steps in turn.
$ set noon
$ set process/parse_style=extended
$ arch = f$edit(f$getsyi("ARCH_NAME"), "UPCASE")
$ base = "I64VMS"
$ if arch .eqs. "X86_64" then base = "X86VMS"
$! A batch job starts in SYS$LOGIN: take the tree from this procedure's directory.
$ proc = f$environment("PROCEDURE")
$ tree = f$parse(proc,,,"DEVICE") + f$parse(proc,,,"DIRECTORY") - "]" + "." + p1 + "]"
$ step = f$edit(p2, "UPCASE")
$ if step .eqs. "SMOKE" then goto smoke
$ if step .eqs. "REMOVE" then goto remove
$!
$ kitdir = tree - "]" + ".KIT_''arch']"
$ write sys$output "=== INSTALL from ", kitdir
$ t0 = f$time()
$ product install ANT /producer=ISSINOHO /base_system='base' /source='kitdir' /options=noconfirm
$ write sys$output "=== install status ", $status, " (", t0, " - ", f$time(), ")"
$ product show product ANT /producer=ISSINOHO
$ write sys$output "=== VERIFY"
$ write sys$output "startup procedure: [", f$search("SYS$STARTUP:ANT$STARTUP.COM"), "]"
$ write sys$output "ANT$ROOT: [", f$trnlnm("ANT$ROOT"), "]"
$ @ANT$ROOT:[000000]ANT$SETUP.COM
$ write sys$output "setup status: ", $status
$ show symbol ant
$! The files have their real names again (ANT$CASE.COM): no jar is upper case.
$ directory/noheading/notrailing ANT$ROOT:[000000]*.*,ANT$ROOT:[BIN]*.*
$ directory/noheading/notrailing/protection/owner ANT$ROOT:[BIN]*.EXE,ANT$ROOT:[LIB]ant.jar,ant-launcher.jar
$ write sys$output "manual: [", f$search("ANT$ROOT:[MANUAL]index.html"), "]"
$ njar = 0
$ nupper = 0
$count:
$ jf = f$search("ANT$ROOT:[LIB]*.jar;", 1)
$ if jf .eqs. "" then goto counted
$ njar = njar + 1
$ jn = f$parse(jf,,,"NAME") + f$parse(jf,,,"TYPE")
$ if jn .eqs. f$edit(jn, "UPCASE") then nupper = nupper + 1
$ goto count
$counted:
$ write sys$output "lib jars: ''njar', upper case: ''nupper'"
$ write sys$output "=== ANT -version"
$ pipe ant -version
$ write sys$output "ant -version status: ", $status
$ delete/symbol/global ant
$ exit 1
$!
$smoke:
$ write sys$output "=== SMOKE TEST on the installed ANT"
$ smoke = tree - "]" + ".VMSPORT]TEST_SMOKE.COM"
$ @'smoke' ANT$ROOT:[BIN]ANT.EXE
$ exit 1
$!
$remove:
$ write sys$output "=== REMOVE"
$ product remove ANT /producer=ISSINOHO /options=noconfirm
$ write sys$output "=== remove status ", $status
$ write sys$output "ANT$ROOT after removal: [", f$trnlnm("ANT$ROOT"), "]"
$ write sys$output "files after removal: [", f$search("SYS$COMMON:[ANT...]*.*"), "]"
$ write sys$output "directory after removal: [", f$search("SYS$COMMON:[000000]ANT.DIR"), "]"
$ write sys$output "startup after removal: [", f$search("SYS$STARTUP:ANT$STARTUP.COM"), "]"
$ product show product ANT /producer=ISSINOHO
$ exit 1
