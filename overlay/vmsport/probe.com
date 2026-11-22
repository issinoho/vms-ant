$! PROBE.COM - Phase 0 probe of stock Ant on OpenVMS: runs each target of
$! [.VMSPORT.TESTS.PROBE]BUILD.XML in its own Ant run, through the upstream
$! launcher class, and reports exit status and output. P1: targets (default all).
$ set noon
$ oldprv = f$setprv("NOALL,NETMBX,TMPMBX")
$ set process/parse_style=extended
$! P3 = "TRADITIONAL": run Ant under the batch default parse style instead.
$ if p3 .eqs. "TRADITIONAL" then set process/parse_style=traditional
$ proc = f$environment("procedure")
$ port = f$parse(proc,,,"device") + f$parse(proc,,,"directory")
$ home = f$edit(port,"upcase") - ".VMSPORT]" + "]"
$ probe = home - "]" + ".VMSPORT.TESTS.PROBE]"
$ if f$type(java) .eqs. "" then @SYS$STARTUP:OPENJDK$SETUP.COM
$ spec = home
$ gosub to_unix
$ uhome = uspec
$ write sys$output "PROBE: ''home' (''uhome') on ''f$getsyi("arch_name")' ''f$getsyi("version")'"
$ write sys$output "PROBE: java = ''java'"
$ set default 'probe'
$! P2 = "LOGICALS": VSI Java's file-version logicals, as MVN.EXE sets them.
$ if p2 .eqs. "LOGICALS"
$ then
$   define/nolog JAVA$DELETE_ALL_VERSIONS TRUE
$   define/nolog JAVA$RENAME_ALL_VERSIONS TRUE
$   define/nolog JAVA$CREATE_DIR_WITH_OWNER_DELETE TRUE
$ endif
$! P4 = "TRACE": VSI Java's JAVA$EXEC_TRACE (every process Java starts).
$ if p4 .eqs. "TRACE" then define/nolog JAVA$EXEC_TRACE TRUE
$ ant = java + " ""-Dant.home=''uhome'"" -classpath ''uhome'/lib/ant-launcher.jar ""org.apache.tools.ant.launch.Launcher"""
$ targets = "version,info,clean,files,archives,javac,javac-fork,jar,java,java-fork,java-fork-exit,exec,exec-fail,env,get,failing,files"
$ if p1 .nes. "" then targets = p1
$ i = 0
$ loop:
$ t = f$element(i,",",targets)
$ if t .eqs. "," then goto done
$ i = i + 1
$ write sys$output "=== ''t'"
$ start = f$time()
$ if t .eqs. "version"
$ then
$   pipe ant -version > probe.out
$ else
$   pipe ant "-f" build.xml 't' > probe.out
$ endif
$ st = $status
$ type probe.out
$ write sys$output "=== ''t' status ''st' (''start' - ''f$time()')"
$ goto loop
$ done:
$ write sys$output "--- versions left by 'files':"
$ directory/nohead/notrail [.out...]*.*;*
$ set default 'home'
$ exit 1
$!
$ to_unix:
$   d = f$parse(spec,,,"device") - ":"
$   p = f$parse(spec,,,"directory") - "[" - "]" - "<" - ">"
$   p = p + "]"
$   u = ""
$ tu_loop:
$   c = f$extract(0,1,p)
$   p = f$extract(1,999,p)
$   if c .eqs. "]" then goto tu_end
$   if c .eqs. "^"
$   then
$     u = u + f$extract(0,1,p)
$     p = f$extract(1,999,p)
$     goto tu_loop
$   endif
$   if c .eqs. "." then c = "/"
$   u = u + c
$   goto tu_loop
$ tu_end:
$   uspec = "/" + d + "/" + u
$   return
