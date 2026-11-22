$! BUILD.COM [ALL|CLEAN] - build the VMS parts of the Ant tree this [.VMSPORT] is in:
$!
$!   [.BIN]ANT.EXE     the launcher (ant.c, vms_crtl_init.c)
$!   [.BIN]ANTDCL.EXE  runs the DCL procedures Ant writes (antdcl.c, NOTES N8)
$!   [.LIB]ANT.JAR     with the classes compiled from the patched sources in
$!                     [.VMSPORT.SRC.ANT] (listed in PATCHED.LIS) put back in;
$!                     the upstream jar is kept in [.VMSPORT.PRISTINE]
$!
$! CLEAN puts the upstream jar back and deletes what ALL makes.
$! Java comes from SYS$STARTUP:OPENJDK$SETUP.COM when JAVAC is not defined.
$ set noon
$ on control_y then goto done
$ target = f$edit(p1,"upcase,trim")
$ if target .eqs. "" then target = "ALL"
$ proc = f$environment("procedure")
$ port = f$parse(proc,,,"device") + f$parse(proc,,,"directory")
$! ODS-5 keeps the case the directory was made with: compare in upper case.
$ home = f$edit(port,"upcase") - ".VMSPORT]" + "]"
$ olddef = f$environment("default")
$ set default 'home'
$ write sys$output "BUILD: ''target' in ''home' on ''f$getsyi("arch_name")' ''f$getsyi("version")'"
$ show time
$ errors = 0
$!
$! ---- CLEAN -------------------------------------------------------------------
$ if target .eqs. "CLEAN"
$ then
$!  /REPLACE: [.LIB] already has a ;1, so a plain COPY is "not superseded".
$   if f$search("[.vmsport.pristine]ant.jar") .nes. ""
$   then
$     copy/nolog/replace [.vmsport.pristine]ant.jar;0 [.lib]ant.jar
$     if .not. $status
$     then
$       write sys$output "%BUILD-E-COPY, the upstream ant.jar was not put back"
$       errors = errors + 1
$     endif
$   endif
$   purge/nolog [.lib]ant.jar
$   if f$search("[.bin]ant.exe") .nes. "" then delete/nolog [.bin]ant.exe;*
$   if f$search("[.bin]antdcl.exe") .nes. "" then delete/nolog [.bin]antdcl.exe;*
$   if f$search("[.vmsport.obj]*.*") .nes. "" then delete/nolog [.vmsport.obj]*.*;*
$   if f$search("[.vmsport.classes...]*.class") .nes. "" then -
       delete/nolog [.vmsport.classes...]*.class;*
$   goto done
$ endif
$!
$! ---- the images --------------------------------------------------------------
$ if f$search("[.vmsport]obj.dir") .eqs. "" then create/directory [.vmsport.obj]
$ ccq = "/names=(as_is,shortened)/warnings=(disable=(emptyfile))/object=[.vmsport.obj]"
$! The Alpha's default is G_FLOAT (family lesson); harmless elsewhere.
$ if f$getsyi("arch_name") .eqs. "Alpha" then ccq = ccq + "/float=ieee_float"
$ cc'ccq' [.vmsport]ant.c
$ if .not. $status then errors = errors + 1
$ cc'ccq' [.vmsport]vms_crtl_init.c
$ if .not. $status then errors = errors + 1
$ cc'ccq' [.vmsport]antdcl.c
$ if .not. $status then errors = errors + 1
$ if errors .gt. 0
$ then
$   write sys$output "%BUILD-E-CC, the images did not compile"
$   goto done
$ endif
$ link/executable=[.bin]ant.exe/notraceback [.vmsport.obj]ant.obj,vms_crtl_init.obj
$ if .not. $status
$ then
$   write sys$output "%BUILD-E-LINK, ANT.EXE did not link"
$   errors = errors + 1
$   goto done
$ endif
$ purge/nolog [.bin]ant.exe
$ write sys$output "BUILD: [.BIN]ANT.EXE"
$! ANTDCL.EXE: without vms_crtl_init (Java passes its one argument through execv).
$ link/executable=[.bin]antdcl.exe/notraceback [.vmsport.obj]antdcl.obj
$ if .not. $status
$ then
$   write sys$output "%BUILD-E-LINK, ANTDCL.EXE did not link"
$   errors = errors + 1
$   goto done
$ endif
$ purge/nolog [.bin]antdcl.exe
$ write sys$output "BUILD: [.BIN]ANTDCL.EXE"
$!
$! ---- the patched ant.jar -----------------------------------------------------
$ if f$type(javac) .eqs. "" then @SYS$STARTUP:OPENJDK$SETUP.COM
$ if f$search("[.vmsport]pristine.dir") .eqs. "" then create/directory [.vmsport.pristine]
$ if f$search("[.vmsport]classes.dir") .eqs. "" then create/directory [.vmsport.classes]
$ if f$search("[.vmsport.pristine]ant.jar") .eqs. "" then -
     copy/nolog [.lib]ant.jar [.vmsport.pristine]ant.jar
$! The source files go to javac in an argument file: on one DCL line they
$! are longer than a command element may be (%DCL-W-TKNOVF).
$ nfiles = 0
$ open/read/error=nolist lis [.vmsport]patched.lis
$ create [.vmsport]javac.lis
$ open/append args [.vmsport]javac.lis
$ next_line:
$   read/end_of_file=last_line lis line
$   line = f$edit(line,"compress,trim")
$   if line .eqs. "" then goto next_line
$   write args "vmsport/src/ant/", f$element(2," ",line)
$   nfiles = nfiles + 1
$   goto next_line
$ last_line:
$ close lis
$ close args
$ if nfiles .eq. 0 then goto done
$ if f$search("[.vmsport.classes...]*.class") .nes. "" then -
     delete/nolog [.vmsport.classes...]*.class;*
$ write sys$output "BUILD: javac for ant.jar, ''nfiles' file(s):"
$ type [.vmsport]javac.lis
$! Against the upstream jar, so a class compiled before cannot hide an error.
$ define/user sys$error sys$output
$ javac "-nowarn" "-encoding" "UTF-8" "-source" "8" "-target" "8" -
        "-cp" "vmsport/pristine/ant.jar:lib/*" "-d" "vmsport/classes" "@vmsport/javac.lis"
$ if .not. $status .or. f$search("[.vmsport.classes...]*.class") .eqs. ""
$ then
$   write sys$output "%BUILD-E-JAVAC, the patched classes did not compile"
$   errors = errors + 1
$   goto done
$ endif
$ copy/nolog/replace [.vmsport.pristine]ant.jar;0 [.lib]ant.jar
$ purge/nolog [.lib]ant.jar
$ define/user sys$error sys$output
$ jar "uf" "lib/ant.jar" "-C" "vmsport/classes" "."
$ if .not. $status
$ then
$   write sys$output "%BUILD-E-JAR, could not update lib/ant.jar"
$   errors = errors + 1
$   goto done
$ endif
$ write sys$output "BUILD: lib/ant.jar patched"
$ goto done
$ nolist:
$ write sys$output "%BUILD-E-NOLIST, [.VMSPORT]PATCHED.LIS is missing (run tools/prepare.sh)"
$ errors = errors + 1
$!
$ done:
$ set default 'olddef'
$ show time
$ if errors .eq. 0 then write sys$output "BUILD: done"
$ if errors .ne. 0 then write sys$output "%BUILD-E-FAILED, ''errors' error(s)"
$ exit
