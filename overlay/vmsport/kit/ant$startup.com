$! ANT$STARTUP.COM - system startup for Apache Ant on OpenVMS
$!
$! Installed by PCSI into SYS$STARTUP.  Defines the system logical name
$! ANT$ROOT, the installed [ANT] directory (the Ant home), concealed.
$! To run it at every boot, add this line to SYS$MANAGER:SYSTARTUP_VMS.COM:
$!
$!     $ @SYS$STARTUP:ANT$STARTUP.COM
$!
$! P1 = "INSTALL": also give the files their real names (PCSI installs them in
$!                 upper case) and print the post-installation tasks; PCSI
$!                 runs it so.
$! P1 = "REMOVE":  deassign ANT$ROOT instead (PCSI runs it so).
$!
$! Users then define the ANT command with
$!     $ @ANT$ROOT:[000000]ANT$SETUP.COM
$!
$ set noon
$ mode = f$edit(p1, "UPCASE")
$ if mode .eqs. "REMOVE"
$ then
$   if f$trnlnm("ANT$ROOT", "LNM$SYSTEM_TABLE") .nes. "" then -
        deassign/system/executive_mode ANT$ROOT
$   exit 1
$ endif
$!
$! This procedure sits in <destination>[SYS$STARTUP]; the product is in
$! <destination>[ANT].  Rooted logicals need the physical form:
$! DKA0:[SYS0.SYSCOMMON.SYS$STARTUP] -> DKA0:[SYS0.SYSCOMMON.ANT.]
$ proc = f$environment("PROCEDURE")
$ dev = f$parse(proc,,,"DEVICE","NO_CONCEAL")
$ dir = f$edit(f$parse(proc,,,"DIRECTORY","NO_CONCEAL"), "UPCASE") - "]["
$ root = dir - "SYS$STARTUP]" + "ANT.]"
$ if root .eqs. dir + "ANT.]"
$ then
$   write sys$error "ANT$STARTUP: expected to be in a [SYS$STARTUP] directory, not ''dir'"
$   exit 44
$ endif
$ root = root - ".000000"
$ define/system/executive_mode/translation_attributes=concealed ANT$ROOT 'dev''root'
$ if f$search("ANT$ROOT:[BIN]ANT.EXE") .eqs. ""
$ then
$   write sys$error "ANT$STARTUP: ANT.EXE not found under ''dev'''root'"
$   exit 44
$ endif
$ if mode .nes. "INSTALL" then exit 1
$!
$! PCSI stores every file name in upper case.  ANT$CASE.COM gives each file
$! its real name (the jars, the manual's pages), as in the distribution.
$! (The directories keep upper-case names: Ant only looks them up.)
$ @ANT$ROOT:[000000]ANT$CASE.COM
$ say = "write sys$output"
$ say ""
$ say "    Post-installation tasks for Apache Ant"
$ say ""
$ say "    At system startup: to define ANT$ROOT at every boot, add this"
$ say "    line to SYS$MANAGER:SYSTARTUP_VMS.COM:"
$ say "    $ @SYS$STARTUP:ANT$STARTUP.COM"
$ say "    For each user: to define the ANT command, add this line to"
$ say "    LOGIN.COM or SYS$MANAGER:SYLOGIN.COM:"
$ say "    $ @ANT$ROOT:[000000]ANT$SETUP.COM"
$ say "    Ant needs VSI OpenJDK 8 (SYS$STARTUP:OPENJDK$SETUP.COM)."
$ say "    The manual is ANT$ROOT:[MANUAL]index.html."
$ say ""
$ say "    PRODUCT REMOVE ANT removes the product and deassigns ANT$ROOT."
$ say ""
$ exit 1
