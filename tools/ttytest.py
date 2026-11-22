#!/usr/bin/env python3
"""ttytest.py <node> - run ANT interactively on <node> and check what a terminal shows.

The batch suite (test.sh) runs Ant with no terminal; this logs in to the node over
ssh in a pseudo-terminal (132x40), runs the built ANT.EXE from DCL in
[.VMSPORT.TESTS.SMOKE], and checks the screen (pyte), the raw output, DCL's status
and the process's subprocesses:
  version     ant -version
  build       a build's output, whole lines, no escape sequences; success status
  dcl         DCL commands' output (ANTDCL.EXE) on the terminal, a line each
  ctrl-c      CTRL/C while Ant waits in Java: back to DCL, Java exited 130 (as
              ANT.EXE reports it), no subprocess left
  ctrl-y      the same for CTRL/Y (ANT.EXE passes it to Java as SIGINT)
  ctrl-c-dcl  CTRL/C while Ant waits in a DCL command (ANTDCL.EXE's subprocess)
              $STATUS after each is shown, not checked (vms-maven NOTES N24)
  ctrl-y-back afterwards CTRL/Y interrupts DCL again

Needs pexpect and pyte on the host (tools/ttytest.sh finds a python that has them).
Output: out/tty-<node>.log; exit status 0 only if every check passes.
TTYTEST_TRACE=1 also writes the raw terminal output to out/tty-<node>.raw.
Adapted from vms-maven's tools/ttytest.py.
"""
import os
import re
import sys
import time

import pexpect
import pyte

TOP = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROMPT = 'TTY> '
ROWS, COLS = 40, 132
SGR = re.compile(rb'\x1b\[[0-9;]*m')


def read_conf(node):
    for line in open(os.path.join(TOP, 'tools', 'nodes.conf')):
        f = line.split()
        if f and not f[0].startswith('#') and f[0] == node:
            return f
    sys.exit('ttytest: unknown node %s' % node)


def upstream():
    conf = {}
    for line in open(os.path.join(TOP, 'upstream.conf')):
        m = re.match(r'(\w+)=(.*)', line.strip())
        if m:
            conf[m.group(1)] = m.group(2).strip('"')
    return conf


class Session:
    def __init__(self, node):
        _, arch, host, port, user, workdir, _ = read_conf(node)
        self.workdir = workdir
        self.screen = pyte.Screen(COLS, ROWS)
        self.stream = pyte.ByteStream(self.screen)
        self.raw = b''          # output since the last mark()
        self.rawlog = None
        self.child = pexpect.spawn(
            'ssh', ['-tt', '-p', port, '-i',
                    os.path.expanduser(os.environ.get('VMS_SSH_KEY', '~/.ssh/vms_ed25519')),
                    '-o', 'BatchMode=yes', '%s@%s' % (user, host)],
            env=dict(os.environ, TERM='vt100'), dimensions=(ROWS, COLS), timeout=60)

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            try:
                data = self.child.read_nonblocking(65536, timeout=0.2)
            except pexpect.TIMEOUT:
                continue
            except pexpect.EOF:
                return
            self.raw += data
            if self.rawlog:
                self.rawlog.write(data)
                self.rawlog.flush()
            self.stream.feed(data)

    def until(self, pred, seconds):
        end = time.time() + seconds
        while time.time() < end and not pred():
            self.pump(0.3)
        return pred()

    def mark(self):
        self.raw = b''
        self.screen.reset()

    def text(self):
        return self.raw.decode('latin-1')

    def prompted(self):
        """DCL's prompt is the last thing written."""
        return self.text().rstrip(' \x00').endswith(PROMPT.rstrip())

    def dcl(self, command, seconds=60):
        """Run a DCL command and wait for the prompt; the output is in self.raw."""
        self.mark()
        self.child.send(command + '\r')
        self.pump(0.3)
        return self.until(self.prompted, seconds)

    def symbol(self, expr):
        self.dcl('write sys$output "=[", %s, "]="' % expr)
        m = re.search(r'=\[(.*?)\]=', self.text().split('\n', 1)[-1])
        return m.group(1) if m else None

    def dump(self):
        return '\n'.join('%2d|%s' % (i, l.rstrip())
                         for i, l in enumerate(self.screen.display) if l.strip())


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    node = sys.argv[1]
    up = upstream()
    tree = (up['UPSTREAM_NAME'] + '-' + up['UPSTREAM_VERSION']).replace('.', '_').upper()
    os.makedirs(os.path.join(TOP, 'out'), exist_ok=True)
    log = open(os.path.join(TOP, 'out', 'tty-%s.log' % node), 'w')
    results = []

    def check(name, ok, s, detail=''):
        results.append(ok)
        line = '%s %s%s' % ('PASS' if ok else 'FAIL', name, (' (%s)' % detail) if detail else '')
        print(line, flush=True)
        log.write(line + '\n')
        if not ok:
            log.write(s.dump() + '\n')
        log.flush()

    def info(text):
        print('INFO ' + text, flush=True)
        log.write('INFO ' + text + '\n')

    s = Session(node)
    if os.environ.get('TTYTEST_TRACE'):
        s.rawlog = open(os.path.join(TOP, 'out', 'tty-%s.raw' % node), 'wb')
    s.child.expect([r'::', r'\$ ', pexpect.TIMEOUT], timeout=60)
    s.pump(2)
    s.child.send('set prompt="%s"\r' % PROMPT)
    s.pump(2)
    for cmd in ('set default %s.%s.VMSPORT.TESTS.SMOKE]' % (s.workdir[:-1], tree),
                'set terminal/page=%d/width=%d' % (ROWS, COLS),
                'set process/parse_style=extended',
                'if f$type(java) .eqs. "" then @SYS$STARTUP:OPENJDK$SETUP.COM',
                'ant :== $%s.%s.BIN]ANT.EXE' % (s.workdir[:-1], tree),
                'define/nolog ant_vms_trace 1'):
        s.dcl(cmd)

    s.dcl('ant -version', 300)
    check('version', 'Apache Ant(TM) version ' + up['UPSTREAM_VERSION'] in s.text(), s)

    # A build: whole lines (no empty line after each), plain, success.
    s.dcl('ant clean java', 300)
    plain = not SGR.search(s.raw)
    lines = s.text().replace('\r', '').split('\n')
    doubled = any(a.strip() and not b.strip() and c.strip() and 'BUILD' not in c
                  for a, b, c in zip(lines, lines[1:], lines[2:]) if '[echo]' in a)
    check('build', 'BUILD SUCCESSFUL' in s.text() and '[MixedCase Arg]' in s.text()
          and plain and not doubled, s,
          'escape sequences' if not plain else 'an empty line after each' if doubled else '')
    check('build-status', s.symbol('$severity') == '1', s)

    # DCL commands through ANTDCL.EXE, their output in Ant's log on the terminal.
    s.dcl('ant tty-dcl', 300)
    check('dcl', 'BUILD SUCCESSFUL' in s.text() and '[exec] DCL on a terminal' in s.text()
          and re.search(r'\[exec\]\s+\d+-[A-Z]{3}-\d{4}', s.text()) is not None, s)

    # CTRL/C and CTRL/Y while Ant waits: Java runs its shutdown hooks and exits
    # 130 (ANT.EXE reports "wait status %X00008200" under ANT_VMS_TRACE), and
    # nothing is left running; also while a DCL command runs under ANTDCL.EXE.
    for name, target, ready, key in (('ctrl-c', 'wait-java', 'Waiting in Java', '\x03'),
                                     ('ctrl-y', 'wait-java', 'Waiting in Java', '\x19'),
                                     ('ctrl-c-dcl', 'wait-dcl', 'Waiting in DCL', '\x03')):
        s.mark()
        s.child.send('ant %s\r' % target)
        started = s.until(lambda: ready in s.text(), 300)
        s.pump(5)
        s.child.send(key)
        back = s.until(s.prompted, 60)
        stopped = 'BUILD SUCCESSFUL' not in s.text()
        check(name, started and back and stopped, s,
              'not started' if not started else 'no prompt' if not back
              else 'ran to the end' if not stopped else '')
        m = re.search(r'Java ended, wait status (%X[0-9A-F]+)', s.text())
        check(name + '-java-130', bool(m) and m.group(1) == '%X00008200', s,
              'wait status %s' % (m.group(1) if m else 'not reported'))
        info('%s-status %s' % (name, s.symbol('$status')))
        time.sleep(2)
        sub = s.symbol('f$getjpi("","PRCCNT")')
        check(name + '-nothing-left', sub == '0', s, '%s subprocesses' % sub)

    s.dcl('deassign ant_vms_trace')
    s.mark()
    s.child.send('read sys$command x /prompt="type CTRL/Y: "\r')
    s.until(lambda: 'type CTRL/Y' in s.text(), 20)
    s.child.send('\x19')
    check('ctrl-y-back', s.until(lambda: 'Interrupt' in s.text() and s.prompted(), 20), s)

    s.child.send('logout\r')
    s.pump(3)
    passed = results.count(True)
    line = 'TTY: %d passed, %d failed' % (passed, len(results) - passed)
    print(line)
    log.write(line + '\n')
    sys.exit(0 if all(results) else 1)


if __name__ == '__main__':
    main()
