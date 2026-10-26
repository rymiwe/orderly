#!/usr/bin/env bash
# Run every test in test/ and tests/: the Ruby suites with ruby, the page
# tests with node. Prints one line per file and exits non-zero if any failed.
# UPDATE_EXPECT=1 is passed through, so test/cards_expect_test.rb rewrites
# test/expect/cards/*.json.
set -u
cd "$(dirname "$0")/.." || exit 2
status=0
for f in test/*_test.rb tests/*_test.rb test/*_test.js tests/*_test.js; do
  [ -f "$f" ] || continue
  case "$f" in
    *.rb) cmd=(ruby "$f") ;;
    *.js) cmd=(node "$f") ;;
  esac
  if out=$("${cmd[@]}" 2>&1); then
    echo "ok   $f"
  else
    status=1
    echo "FAIL $f"
    printf '%s\n' "$out" | sed 's/^/     /'
  fi
done
exit "$status"
