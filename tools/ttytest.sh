#!/usr/bin/env bash
# ttytest.sh <node> - run tools/ttytest.py (ANT on a terminal) with a python that has
# pexpect and pyte: $TTYTEST_PYTHON, else cache/venv (python3 -m venv cache/venv;
# cache/venv/bin/pip install pexpect pyte), else python3.
top=$(cd "$(dirname "$0")/.." && pwd)
py=${TTYTEST_PYTHON:-}
[ -n "$py" ] || { [ -x "$top/cache/venv/bin/python" ] && py=$top/cache/venv/bin/python; } || true
"$top/tools/push.sh" "${1:?usage: ttytest.sh <node>}" >/dev/null
exec "${py:-python3}" "$top/tools/ttytest.py" "$@"
