$! ANT$SETUP.COM - define the ANT command for a user
$!
$! Add to LOGIN.COM (or SYS$MANAGER:SYLOGIN.COM for everyone):
$!     $ @ANT$ROOT:[000000]ANT$SETUP.COM
$!
$! Ant runs on VSI OpenJDK 8: when neither the JAVA symbol nor JAVA_HOME is
$! defined, this runs SYS$STARTUP:OPENJDK$SETUP.COM.
$! Ant's targets, options and properties are case-sensitive: use
$!     $ SET PROCESS/PARSE_STYLE=EXTENDED
$! or quote them ("-Dmy.Prop=Value").  See ANT$ROOT:[000000]README.VMS.
$!
$ if f$trnlnm("ANT$ROOT") .eqs. ""
$ then
$   write sys$error "ANT$SETUP: ANT$ROOT is not defined; run SYS$STARTUP:ANT$STARTUP.COM first"
$   exit 44
$ endif
$ ant :== "$ANT$ROOT:[BIN]ANT.EXE"
$ if f$type(java) .nes. "" .or. f$type(java_home) .nes. "" .or. f$trnlnm("JAVA_HOME") .nes. "" -
    then exit 1
$ if f$search("SYS$STARTUP:OPENJDK$SETUP.COM") .nes. ""
$ then
$   @SYS$STARTUP:OPENJDK$SETUP.COM
$ else
$   write sys$error "ANT$SETUP: no Java; ANT needs VSI OpenJDK 8 (JAVA_HOME or the JAVA symbol)"
$ endif
$ exit 1
