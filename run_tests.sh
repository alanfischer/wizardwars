#!/bin/bash
# Runs WizardWars' own test suite (src/tests/run_tests.tscn) and exits non-zero if it fails.
# It boots as a scene, not a `-s` script main-loop, so the project's autoloads (Log,
# NetworkManager, …) are registered and usable by tests.
#
# Dependencies test themselves. Each extern/*-godot submodule is its own project with its own
# suite and runner — pmove-godot/run_tests.sh, hop-godot/test-project, goldnet-godot/tests,
# goldsrc-godot/tests — so run those in their own repo when you change one.
set -uo pipefail

# Resolve the Godot binary: $GODOT override, then the two common install paths.
GODOT="${GODOT:-}"
if [ -z "$GODOT" ] || [ ! -x "$GODOT" ]; then
    for candidate in \
        "/Applications/Godot.app/Contents/MacOS/Godot" \
        "$HOME/Applications/Godot.app/Contents/MacOS/Godot"; do
        if [ -x "$candidate" ]; then GODOT="$candidate"; break; fi
    done
fi
if [ ! -x "$GODOT" ]; then
    echo "Godot binary not found. Set GODOT=/path/to/Godot" >&2
    exit 127
fi

cd "$(dirname "$0")"

status=0
log="$(mktemp)"
if ! "$GODOT" --headless --path . res://src/tests/run_tests.tscn 2>&1 | tee "$log"; then
    status=1   # pipefail: this is Godot's status, not tee's
fi

# A GDScript runtime error (a bad call, a wrong-typed index) kills only the frame it happens in:
# the test's remaining assertions never run, the suite counts no failure, and the run goes green
# holding a broken test. The assertion counts cannot see it, so the output is the only witness --
# and a clean run prints no SCRIPT ERROR at all, which makes it a reliable tripwire.
if grep -q "SCRIPT ERROR" "$log"; then
    echo
    echo "SCRIPT ERROR in the suite -- a test hit a runtime error and silently dropped its" >&2
    echo "remaining assertions, so its result means nothing. First occurrences:" >&2
    grep -m 5 -A2 "SCRIPT ERROR" "$log" >&2
    status=1
fi
rm -f "$log"

echo
if [ "$status" -eq 0 ]; then
    echo "All tests passed."
else
    echo "Tests FAILED." >&2
fi
exit "$status"
