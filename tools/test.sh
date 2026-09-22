#!/bin/zsh
# Runs every headless Godot test in client/tests against the dev server.
set -u
G=/Applications/Godot-4.8-dev4.app/Contents/MacOS/Godot
cd "${0:A:h}/../client"
"$G" --headless --path . --import >/dev/null 2>&1
fail=0
for t in tests/test_*.gd; do
  name=${t:t:r}
  out=$(perl -e "alarm 300; exec @ARGV" "$G" --headless --path . -s "res://$t" 2>&1)
  if echo "$out" | grep -q 'RESULT: PASS'; then echo "PASS  $name"; else echo "FAIL  $name"; echo "$out" | grep -v '^$' | tail -15; fail=1; fi
done
exit $fail
