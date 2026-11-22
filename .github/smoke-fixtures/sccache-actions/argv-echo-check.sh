#!/usr/bin/env bash
#
# Fixture used only by ci.yml's run-cargo-with-sccache-fallback smoke test, via that action's
# cargo-fallback-script escape hatch. Asserts that argv arrived exactly as the action's
# newline-delimited `args` input described it - including an argument containing a space - to
# prove the action's args->argv plumbing doesn't re-split or mangle anything.
set -euo pipefail

expected=(cargo build -p rust-coverage-smoke-fixture --message "hello world" --features extra)

if [[ "$#" -ne "${#expected[@]}" ]]; then
  echo "argv count mismatch: got $# want ${#expected[@]}" >&2
  printf 'got: %q\n' "$@" >&2
  exit 1
fi

i=1
for exp in "${expected[@]}"; do
  actual="${!i}"
  if [[ "$actual" != "$exp" ]]; then
    echo "argv[$i] mismatch: got '$actual' want '$exp'" >&2
    exit 1
  fi
  i=$((i + 1))
done

echo "argv preserved exactly, including the embedded-space argument"
