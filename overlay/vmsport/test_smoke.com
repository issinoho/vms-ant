$! TEST_SMOKE.COM - smoke test of ANT.EXE and the patched Ant in the tree this
$! [.VMSPORT] is in (run BUILD.COM first): runs targets of
$! [.VMSPORT.TESTS.SMOKE]BUILD.XML, one Ant run each, and checks the status
$! and output. P1: another launcher to test (e.g. ANT$ROOT:[BIN]ANT.EXE).
$! Prints PASS/FAIL per test and "SMOKE: <n> passed, <m> failed".
$ set noon
$ on control_y then goto done
$! Without privileges: a stray delete must fail, not take a system file.
$ oldprv = f$setprv("NOALL,NETMBX,TMPMBX")
$ set process/parse_style=extended
$ proc = f$environment("procedure")
$ port = f$parse(proc,,,"device") + f$parse(proc,,,"directory")
$ home = f$edit(port,"upcase") - ".VMSPORT]" + "]"
$ smoke = home - "]" + ".VMSPORT.TESTS.SMOKE]"
$ olddef = f$environment("default")
$ if f$type(java) .eqs. "" then @SYS$STARTUP:OPENJDK$SETUP.COM
$ ant = "$" + home - "]" + ".BIN]ANT.EXE"
$ if p1 .nes. "" then ant = "$" + p1
$ passed = 0
$ failed = 0
$ write sys$output "SMOKE: ''home' on ''f$getsyi("arch_name")' ''f$getsyi("version")'"
$ write sys$output "SMOKE: launcher ''f$extract(1,999,ant)'"
$ set default 'smoke'
$ if f$search("t*.out") .nes. "" then delete/nolog t*.out;*
$!
$! 1. ant -version: the launcher finds Java and the Ant home.
$ t = "ant -version"
$ pipe ant -version > t1.out
$ st = $status
$ want = "Apache Ant(TM) version 1.10.18"
$ gosub has
$ if found .and. st then gosub pass
$ if .not. (found .and. st) then gosub fail
$!
$! 2. Properties keep their case: the command line, ANT_ARGS, ANT_OPTS.
$ t = "properties from the command line, ANT_ARGS and ANT_OPTS"
$ ant_args = "-Dfrom.args=FromArgs"
$ ant_opts = "-Dfrom.opts=FromOpts"
$ args = "clean props -Dsmoke.prop=MixedValue"
$ gosub run
$ delete/symbol/global ant_args
$ delete/symbol/global ant_opts
$ delete/symbol/local ant_args
$ delete/symbol/local ant_opts
$!
$! 3. The same in quotes under the TRADITIONAL parse style (the batch default).
$ t = "quoted properties under the TRADITIONAL parse style"
$ set process/parse_style=traditional
$ ant_args = "-Dfrom.args=FromArgs"
$ ant_opts = "-Dfrom.opts=FromOpts"
$ args = """props"" ""-Dsmoke.prop=MixedValue"""
$ gosub run
$ delete/symbol/local ant_args
$ delete/symbol/local ant_opts
$ set process/parse_style=extended
$!
$! 4-5. Files, twice: rewritten files and a directory delete (NOTES N2).
$ t = "file tasks, case, delete dir (1)"
$ args = "files"
$ gosub run
$ t = "file tasks again over the first run's files (2)"
$ gosub run
$!
$ t = "zip, tar.gz, unzip, untar"
$ args = "archives"
$ gosub run
$ t = "javac, jar, in-VM java"
$ args = "java"
$ gosub run
$ t = "forked javac (patches 0001, 0002)"
$ args = "javac-fork"
$ gosub run
$ t = "forked java: arguments and exit codes (patches 0001-0003)"
$ args = "java-fork"
$ gosub run
$ t = "exec of a bare JDK tool name"
$ args = "exec-image"
$ gosub run
$ t = "DCL exec: quoting, qualifiers, status, a Unix path (patch 0004)"
$ args = "exec-dcl"
$ gosub run
$ t = "DCL exec: lines, an empty one, a procedure by its path (NOTES N9)"
$ args = "exec-dcl-lines"
$ gosub run
$ t = "DCL exec 20 times (ANTDCL.EXE, NOTES N8)"
$ args = "exec-dcl-repeat"
$ gosub run
$ t = "a bare DCL verb without vmlauncher runs as DCL (patch 0006)"
$ args = "exec-fallback"
$ gosub run
$ t = "a foreign command symbol of the job (patch 0006)"
$ antsmokesym == "write sys$output ""from a symbol"""
$ args = "exec-symbol"
$ gosub run
$ delete/symbol/global antsmokesym
$ t = "environment: property environment, env with quotes (patches 0004, 0005)"
$ args = "env"
$ gosub run
$!
$! A failing build: an error status, and the message.
$ t = "a failing build gives an error status"
$ n = passed + failed + 1
$ pipe ant "failing" > t'n'.out
$ st = $status
$! (Not $SEVERITY: the assignment above set it.)
$ sev = st .and. 7
$ want = "intentional failure"
$ gosub has
$ ok = found .and. sev .eq. 2
$ st = sev
$ if ok then gosub pass
$ if .not. ok then gosub fail
$!
$ done:
$ set default 'olddef'
$ write sys$output "SMOKE: ''passed' passed, ''failed' failed"
$ oldprv = f$setprv(oldprv)
$ exit
$!
$! run: ARGS in one Ant run; PASS if the status is success and the output
$! says BUILD SUCCESSFUL.
$ run:
$   n = passed + failed + 1
$   pipe ant 'args' > t'n'.out
$   st = $status
$   want = "BUILD SUCCESSFUL"
$   gosub has
$   if found .and. st then gosub pass
$   if .not. (found .and. st) then gosub fail
$   return
$!
$ pass:
$   passed = passed + 1
$   write sys$output "PASS: ''t'"
$   return
$ fail:
$   failed = failed + 1
$   write sys$output "FAIL: ''t' (status ''st')"
$   if f$type(fil) .nes. "" then if f$search(fil) .nes. "" then type 'fil'
$   return
$!
$! has: is WANT in T<n>.OUT for the current test?
$ has:
$   fil = "t" + f$string(passed + failed + 1) + ".out"
$   found = 0
$   if f$search(fil) .eqs. "" then return
$   search/nooutput 'fil' "''want'"
$   if $severity .eq. 1 then found = 1
$   return
