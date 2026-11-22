$! TEST_PROJECTS.COM - Ant on a small real project, [.VMSPORT.TESTS.PROJECTS]
$! (run BUILD.COM first; JUnit and Hamcrest come from Maven Central once):
$! a full build (JUnit forked, junitreport, javadoc, jar, zip, <parallel>), a
$! failing test, an up-to-date rebuild, a 20 KB classpath, and two Ant runs at
$! once as batch jobs. P1: another launcher to test.
$! Prints PASS/FAIL per test and "PROJECTS: <n> passed, <m> failed".
$! (P1 = "JOB": one of the concurrent runs, P2 its number, P3 the launcher.)
$ set noon
$ on control_y then goto done
$ oldprv = f$setprv("NOALL,NETMBX,TMPMBX")
$ set process/parse_style=extended
$ proc = f$environment("procedure")
$ port = f$parse(proc,,,"device") + f$parse(proc,,,"directory")
$ home = f$edit(port,"upcase") - ".VMSPORT]" + "]"
$ proj = home - "]" + ".VMSPORT.TESTS.PROJECTS]"
$ olddef = f$environment("default")
$ if f$type(java) .eqs. "" then @SYS$STARTUP:OPENJDK$SETUP.COM
$ ant = "$" + home - "]" + ".BIN]ANT.EXE"
$ set default 'proj'
$ if p1 .eqs. "JOB" then goto job
$ if p1 .nes. "" then ant = "$" + p1
$ passed = 0
$ failed = 0
$ write sys$output "PROJECTS: ''home' on ''f$getsyi("arch_name")' ''f$getsyi("version")'"
$ write sys$output "PROJECTS: launcher ''f$extract(1,999,ant)'"
$ if f$search("t*.out") .nes. "" then delete/nolog t*.out;*
$!
$ t = "build: forked javac, JUnit, junitreport, javadoc, jar, zip, parallel"
$ n = 1
$ pipe ant all > t1.out
$ st = $status
$ want = "Tests run: 3, Failures: 0, Errors: 0"
$ gosub has
$ ok = found
$ want = "BUILD SUCCESSFUL"
$ gosub has
$ ok = ok .and. found .and. st
$ gosub result
$!
$ t = "a failing test fails the build"
$ n = 2
$ pipe ant test "-Dfail.test=true" > t2.out
$ st = $status
$ want = "Test com.example.WordsTest FAILED"
$ gosub has
$ ok = found .and. ((st .and. 7) .eq. 2)
$ gosub result
$!
$ t = "a second build finds the classes up to date"
$ n = 3
$ pipe ant dist > t3.out
$ st = $status
$ want = "Compiling"
$ gosub has
$ ok = .not. found
$ want = "BUILD SUCCESSFUL"
$ gosub has
$ ok = ok .and. found .and. st
$ gosub result
$!
$ t = "forked javac and java with a 20 KB classpath"
$ n = 4
$ pipe ant longcp > t4.out
$ st = $status
$ want = "BUILD SUCCESSFUL"
$ gosub has
$ ok = found .and. st
$ gosub result
$!
$! Two runs at once: separate batch jobs, each with its own out directory.
$ t = "two Ant runs at once (batch jobs)"
$ n = 5
$ q = "SYS$BATCH"
$ i = 1
$ sub_loop:
$   if f$search("job''i'.log") .nes. "" then delete/nolog job'i'.log;*
$   submit/noprint/log='proj'job'i'.log/name=ANTPRJ'i'/queue='q' -
       'proc'/parameters=("JOB","''i'","''f$extract(1,999,ant)'")
$   entry'i' = $entry
$   i = i + 1
$   if i .le. 2 then goto sub_loop
$ synchronize/entry='entry1'
$ synchronize/entry='entry2'
$ copy job1.log,job2.log t5.out
$ ok = 1
$ i = 1
$ job_loop:
$   fil = "job''i'.log"
$   search/nooutput 'fil' "JOB: BUILD OK"
$   if $severity .ne. 1 then ok = 0
$   i = i + 1
$   if i .le. 2 then goto job_loop
$ fil = "t5.out"
$ st = ok
$ gosub result
$!
$ done:
$ set default 'olddef'
$ write sys$output "PROJECTS: ''passed' passed, ''failed' failed"
$ oldprv = f$setprv(oldprv)
$ exit
$!
$ job:
$ ant = "$" + p3
$ pipe ant all "-Dout=out/job''p2'" > job'p2'.out
$ st = $status
$ type job'p2'.out
$ search/nooutput job'p2'.out "BUILD SUCCESSFUL"
$ if $severity .eq. 1 .and. st then write sys$output "JOB: BUILD OK"
$ set default 'olddef'
$ exit
$!
$ result:
$   fil = "t''n'.out"
$   if ok
$   then
$     passed = passed + 1
$     write sys$output "PASS: ''t'"
$   else
$     failed = failed + 1
$     write sys$output "FAIL: ''t' (status ''st')"
$     if f$search(fil) .nes. "" then type 'fil'
$   endif
$   return
$!
$ has:
$   fil = "t''n'.out"
$   found = 0
$   if f$search(fil) .eqs. "" then return
$   search/nooutput 'fil' "''want'"
$   if $severity .eq. 1 then found = 1
$   return
