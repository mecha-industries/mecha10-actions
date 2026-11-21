#!/usr/bin/env bash
# Smoke tests for cargo-with-sccache-fallback.sh.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$script_dir/cargo-with-sccache-fallback.sh"

fail=0

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "FAIL: $msg"
    echo "  expected to contain: $needle"
    echo "  got: $haystack"
    fail=1
  else
    echo "PASS: $msg"
  fi
}

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

call_log="$work_dir/calls-1.log"
fake_cmd="$work_dir/fake-cmd-1.sh"
cat > "$fake_cmd" <<EOF
#!/usr/bin/env bash
echo "call" >> "$call_log"
echo "build ok, RUSTC_WRAPPER=\${RUSTC_WRAPPER:-<unset>}"
exit 0
EOF
chmod +x "$fake_cmd"

set +e
out=$(bash "$script" "$fake_cmd" 2>&1)
status=$?
set -e
if [[ $status -eq 0 ]]; then
  echo "PASS: exits 0 when the sccache attempt succeeds"
else
  echo "FAIL: expected exit 0, got $status"
  fail=1
fi
assert_contains "$out" "RUSTC_WRAPPER=sccache" "runs the first attempt with sccache enabled"
calls=$(wc -l < "$call_log")
if [[ "$calls" -eq 1 ]]; then
  echo "PASS: only invokes the command once when it succeeds"
else
  echo "FAIL: expected 1 call, got $calls"
  fail=1
fi

call_log="$work_dir/calls-2.log"
fake_cmd="$work_dir/fake-cmd-2.sh"
cat > "$fake_cmd" <<EOF
#!/usr/bin/env bash
echo "call" >> "$call_log"
if [[ -n "\${RUSTC_WRAPPER:-}" ]]; then
  echo "sccache: error: Server startup failed: cache storage failed to read: Unexpected (permanent) at read => \"Our services aren't available right now\""
  exit 2
fi
echo "build ok without sccache"
exit 0
EOF
chmod +x "$fake_cmd"

set +e
out=$(bash "$script" "$fake_cmd" 2>&1)
status=$?
set -e
if [[ $status -eq 0 ]]; then
  echo "PASS: exits 0 after falling back to a no-sccache retry"
else
  echo "FAIL: expected exit 0, got $status"
  fail=1
fi
assert_contains "$out" "build ok without sccache" "retry succeeds without sccache"
assert_contains "$out" "sccache appears unavailable" "warns about the sccache fallback"
calls=$(wc -l < "$call_log")
if [[ "$calls" -eq 2 ]]; then
  echo "PASS: invokes the command twice (sccache attempt + fallback retry)"
else
  echo "FAIL: expected 2 calls, got $calls"
  fail=1
fi

call_log="$work_dir/calls-3.log"
fake_cmd="$work_dir/fake-cmd-3.sh"
cat > "$fake_cmd" <<EOF
#!/usr/bin/env bash
echo "call" >> "$call_log"
echo "error[E0308]: mismatched types"
exit 1
EOF
chmod +x "$fake_cmd"

set +e
out=$(bash "$script" "$fake_cmd" 2>&1)
status=$?
set -e
if [[ $status -eq 1 ]]; then
  echo "PASS: propagates the real failure's exit code"
else
  echo "FAIL: expected exit 1, got $status"
  fail=1
fi
assert_contains "$out" "mismatched types" "reports the real compile error"
calls=$(wc -l < "$call_log")
if [[ "$calls" -eq 1 ]]; then
  echo "PASS: does not retry a real (non-sccache) failure"
else
  echo "FAIL: expected 1 call, got $calls"
  fail=1
fi

repo_dir="$work_dir/fake-repo-4"
mkdir -p "$repo_dir/.cargo"
git init -q "$repo_dir"
cat > "$repo_dir/.cargo/config.toml" <<'EOF'
[build]
rustc-wrapper = "sccache"
EOF

call_log="$work_dir/calls-4.log"
sccache_call_log="$work_dir/sccache-calls-4.log"
fake_sccache="$work_dir/fake-sccache-4.sh"
cat > "$fake_sccache" <<EOF
#!/usr/bin/env bash
echo "call" >> "$sccache_call_log"
exit 1
EOF
chmod +x "$fake_sccache"

fake_cmd="$work_dir/fake-cmd-4.sh"
cat > "$fake_cmd" <<EOF
#!/usr/bin/env bash
echo "call" >> "$call_log"
config_file="$repo_dir/.cargo/config.toml"
wrapper_active=0
if [[ -n "\${RUSTC_WRAPPER:-}" ]]; then
  wrapper_active=1
elif [[ -f "\$config_file" ]] && grep -q "rustc-wrapper" "\$config_file"; then
  wrapper_active=1
fi
if [[ "\$wrapper_active" -eq 1 ]]; then
  if ! "$fake_sccache"; then
    echo "sccache: error: Server startup failed: cache storage failed to read: Unexpected (permanent) at read"
    exit 2
  fi
fi
echo "build ok, wrapper_active=\$wrapper_active"
exit 0
EOF
chmod +x "$fake_cmd"

set +e
out=$(cd "$repo_dir" && bash "$script" "$fake_cmd" 2>&1)
status=$?
set -e
if [[ $status -eq 0 ]]; then
  echo "PASS: retry succeeds once config.toml's wrapper is bypassed"
else
  echo "FAIL: expected exit 0, got $status (this is the LAB-2094/LAB-2095 regression if it fails)"
  fail=1
fi
assert_contains "$out" "build ok, wrapper_active=0" "retry actually runs with the wrapper inactive"
sccache_calls=$(wc -l < "$sccache_call_log" 2>/dev/null || echo 0)
if [[ "$sccache_calls" -eq 1 ]]; then
  echo "PASS: fake sccache binary is invoked only on the first attempt, never on retry"
else
  echo "FAIL: expected fake sccache to be called once (first attempt only), got $sccache_calls - config.toml wrapper was not bypassed on retry"
  fail=1
fi

if [[ -f "$repo_dir/.cargo/config.toml" ]]; then
  restored_contents="$(cat "$repo_dir/.cargo/config.toml")"
  if [[ "$restored_contents" == *'rustc-wrapper = "sccache"'* ]]; then
    echo "PASS: .cargo/config.toml is restored with its original content after the script exits"
  else
    echo "FAIL: .cargo/config.toml exists but its content differs from the original"
    fail=1
  fi
else
  echo "FAIL: .cargo/config.toml was not restored after the script exited"
  fail=1
fi

repo_dir2="$work_dir/fake-repo-6"
mkdir -p "$repo_dir2/.cargo"
git init -q "$repo_dir2"
cat > "$repo_dir2/.cargo/config.toml" <<'EOF'
[build]
rustc-wrapper = "sccache"
EOF

fake_cmd6="$work_dir/fake-cmd-6.sh"
cat > "$fake_cmd6" <<EOF
#!/usr/bin/env bash
if [[ -n "\${RUSTC_WRAPPER:-}" ]]; then
  echo "sccache: error: Server startup failed: cache storage failed to read: boom"
  exit 2
fi
echo "error[E0433]: unresolved import"
exit 1
EOF
chmod +x "$fake_cmd6"

set +e
out=$(cd "$repo_dir2" && bash "$script" "$fake_cmd6" 2>&1)
status=$?
set -e
if [[ $status -eq 1 ]]; then
  echo "PASS: propagates the retry's real (non-sccache) failure exit code"
else
  echo "FAIL: expected exit 1, got $status"
  fail=1
fi

if [[ -f "$repo_dir2/.cargo/config.toml" ]]; then
  restored_contents2="$(cat "$repo_dir2/.cargo/config.toml")"
  if [[ "$restored_contents2" == *'rustc-wrapper = "sccache"'* ]]; then
    echo "PASS: .cargo/config.toml is restored even when the retry attempt fails"
  else
    echo "FAIL: .cargo/config.toml exists after a failed retry but its content differs"
    fail=1
  fi
else
  echo "FAIL: .cargo/config.toml was not restored after a failed retry"
  fail=1
fi

call_log="$work_dir/calls-7.log"
clean_log="$work_dir/clean-calls-7.log"
fake_cmd="$work_dir/fake-cmd-7.sh"
cat > "$fake_cmd" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "clean" ]]; then
  echo "call" >> "$CLEAN_LOG"
  exit 0
fi
echo "call" >> "$CALL_LOG"
calls=$(wc -l < "$CALL_LOG")
if [[ "$calls" -eq 1 ]]; then
  echo "error: /target/debug/deps/libserde_derive-abc123.so: /lib/x86_64-linux-gnu/libc.so.6: version \`GLIBC_2.39' not found (required by /target/debug/deps/libserde_derive-abc123.so)"
  exit 1
fi
echo "build ok after clean"
exit 0
EOF
chmod +x "$fake_cmd"

set +e
out=$(CALL_LOG="$call_log" CLEAN_LOG="$clean_log" bash "$script" "$fake_cmd" 2>&1)
status=$?
set -e
if [[ $status -eq 0 ]]; then
  echo "PASS: exits 0 after cleaning and retrying past a glibc-mismatch failure"
else
  echo "FAIL: expected exit 0, got $status"
  fail=1
fi
assert_contains "$out" "build ok after clean" "retry succeeds after cargo clean"
assert_contains "$out" "different glibc" "warns about the stale-glibc cache"
clean_calls=$(wc -l < "$clean_log" 2>/dev/null || echo 0)
if [[ "$clean_calls" -eq 1 ]]; then
  echo "PASS: runs \`cargo clean\` exactly once before retrying"
else
  echo "FAIL: expected 1 clean call, got $clean_calls"
  fail=1
fi
build_calls=$(wc -l < "$call_log")
if [[ "$build_calls" -eq 2 ]]; then
  echo "PASS: invokes the build command twice (failing attempt + post-clean retry)"
else
  echo "FAIL: expected 2 build calls, got $build_calls"
  fail=1
fi

call_log="$work_dir/calls-8.log"
clean_log="$work_dir/clean-calls-8.log"
fake_cmd="$work_dir/fake-cmd-8.sh"
cat > "$fake_cmd" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "clean" ]]; then
  echo "call" >> "$CLEAN_LOG"
  exit 0
fi
echo "call" >> "$CALL_LOG"
calls=$(wc -l < "$CALL_LOG")
if [[ "$calls" -eq 1 ]]; then
  echo "error[E0463]: can't find crate for \`tokio_macros\`"
  exit 1
fi
echo "build ok after clean"
exit 0
EOF
chmod +x "$fake_cmd"

set +e
out=$(CALL_LOG="$call_log" CLEAN_LOG="$clean_log" bash "$script" "$fake_cmd" 2>&1)
status=$?
set -e
if [[ $status -eq 0 ]]; then
  echo "PASS: exits 0 after cleaning and retrying past a missing-crate (E0463) failure"
else
  echo "FAIL: expected exit 0, got $status"
  fail=1
fi
assert_contains "$out" "build ok after clean" "retry succeeds after cargo clean"
assert_contains "$out" "differently-scoped job" "warns about the stale cross-job cache"
clean_calls=$(wc -l < "$clean_log" 2>/dev/null || echo 0)
if [[ "$clean_calls" -eq 1 ]]; then
  echo "PASS: runs \`cargo clean\` exactly once before retrying"
else
  echo "FAIL: expected 1 clean call, got $clean_calls"
  fail=1
fi
build_calls=$(wc -l < "$call_log")
if [[ "$build_calls" -eq 2 ]]; then
  echo "PASS: invokes the build command twice (failing attempt + post-clean retry)"
else
  echo "FAIL: expected 2 build calls, got $build_calls"
  fail=1
fi

call_log="$work_dir/calls-9.log"
clean_log="$work_dir/clean-calls-9.log"
fake_cmd="$work_dir/fake-cmd-9.sh"
cat > "$fake_cmd" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "clean" ]]; then
  echo "call" >> "$CLEAN_LOG"
  exit 0
fi
echo "call" >> "$CALL_LOG"
calls=$(wc -l < "$CALL_LOG")
if [[ "$calls" -eq 1 ]]; then
  printf '\x1b[1m\x1b[91merror[E0463]\x1b[0m\x1b[1m: can'"'"'t find crate for `zeroize_derive`\x1b[0m\n'
  exit 1
fi
echo "build ok after clean"
exit 0
EOF
chmod +x "$fake_cmd"

set +e
out=$(CALL_LOG="$call_log" CLEAN_LOG="$clean_log" bash "$script" "$fake_cmd" 2>&1)
status=$?
set -e
if [[ $status -eq 0 ]]; then
  echo "PASS: exits 0 after cleaning and retrying past a color-coded missing-crate (E0463) failure"
else
  echo "FAIL: expected exit 0, got $status (ANSI escape codes are likely defeating the pattern match)"
  fail=1
fi
assert_contains "$out" "build ok after clean" "retry succeeds after cargo clean"
assert_contains "$out" "differently-scoped job" "warns about the stale cross-job cache despite ANSI color codes"
clean_calls=$(wc -l < "$clean_log" 2>/dev/null || echo 0)
if [[ "$clean_calls" -eq 1 ]]; then
  echo "PASS: runs \`cargo clean\` exactly once before retrying"
else
  echo "FAIL: expected 1 clean call, got $clean_calls"
  fail=1
fi
build_calls=$(wc -l < "$call_log")
if [[ "$build_calls" -eq 2 ]]; then
  echo "PASS: invokes the build command twice (failing attempt + post-clean retry)"
else
  echo "FAIL: expected 2 build calls, got $build_calls"
  fail=1
fi

# LAB-5254: `cargo llvm-cov nextest ...` instruments binaries into
# target/llvm-cov-target, a separate tree from the plain `target/` build
# clippy/doctests share - stacking disk usage across the clippy_test job's
# back-to-back steps until the runner runs out of space. The script should
# delete target/llvm-cov-target right after any `llvm-cov nextest`
# invocation of its own command completes (lcov.info is already flushed
# to disk by then), on both success and failure.
repo_dir10="$work_dir/fake-repo-10"
mkdir -p "$repo_dir10/target/llvm-cov-target"
touch "$repo_dir10/target/llvm-cov-target/marker"
git init -q "$repo_dir10"

fake_cmd10="$work_dir/fake-cmd-10.sh"
cat > "$fake_cmd10" <<'EOF'
#!/usr/bin/env bash
echo "build ok"
exit 0
EOF
chmod +x "$fake_cmd10"

set +e
out=$(cd "$repo_dir10" && bash "$script" "$fake_cmd10" llvm-cov nextest --lib --all-features --lcov --output-path lcov.info 2>&1)
status=$?
set -e
if [[ $status -eq 0 ]]; then
  echo "PASS: exits 0 for a successful llvm-cov nextest invocation"
else
  echo "FAIL: expected exit 0, got $status"
  fail=1
fi
if [[ ! -d "$repo_dir10/target/llvm-cov-target" ]]; then
  echo "PASS: cleans up target/llvm-cov-target after a successful llvm-cov nextest run"
else
  echo "FAIL: target/llvm-cov-target still present after a successful llvm-cov nextest run"
  fail=1
fi

repo_dir11="$work_dir/fake-repo-11"
mkdir -p "$repo_dir11/target/llvm-cov-target"
touch "$repo_dir11/target/llvm-cov-target/marker"
git init -q "$repo_dir11"

fake_cmd11="$work_dir/fake-cmd-11.sh"
cat > "$fake_cmd11" <<'EOF'
#!/usr/bin/env bash
echo "error[E0308]: mismatched types"
exit 1
EOF
chmod +x "$fake_cmd11"

set +e
out=$(cd "$repo_dir11" && bash "$script" "$fake_cmd11" llvm-cov nextest --lib 2>&1)
status=$?
set -e
if [[ $status -eq 1 ]]; then
  echo "PASS: propagates a real failure's exit code for an llvm-cov nextest invocation"
else
  echo "FAIL: expected exit 1, got $status"
  fail=1
fi
if [[ ! -d "$repo_dir11/target/llvm-cov-target" ]]; then
  echo "PASS: still cleans up target/llvm-cov-target even when the llvm-cov nextest run fails"
else
  echo "FAIL: target/llvm-cov-target still present after a failed llvm-cov nextest run"
  fail=1
fi

# Plain `cargo llvm-cov ...` (no `nextest`, e.g.
# .github/actions/rust-coverage/action.yml) runs `cargo llvm-cov report`
# right after, reusing target/llvm-cov-target's profile data - the script
# must leave it alone in this case.
repo_dir12="$work_dir/fake-repo-12"
mkdir -p "$repo_dir12/target/llvm-cov-target"
touch "$repo_dir12/target/llvm-cov-target/marker"
git init -q "$repo_dir12"

fake_cmd12="$work_dir/fake-cmd-12.sh"
cat > "$fake_cmd12" <<'EOF'
#!/usr/bin/env bash
echo "build ok"
exit 0
EOF
chmod +x "$fake_cmd12"

set +e
out=$(cd "$repo_dir12" && bash "$script" "$fake_cmd12" llvm-cov --lcov --output-path lcov.info 2>&1)
status=$?
set -e
if [[ -d "$repo_dir12/target/llvm-cov-target" ]]; then
  echo "PASS: leaves target/llvm-cov-target alone for a plain llvm-cov invocation (no nextest)"
else
  echo "FAIL: target/llvm-cov-target was removed for a plain llvm-cov invocation without nextest"
  fail=1
fi

# A corrupted local registry index cache entry makes cargo misreport a
# registry-sourced crate as missing from a "path source" (see the script's
# own comment on PATH_SOURCE_ERROR_PATTERN for the real-world repro: two
# main.yml jobs racing a cold fetch of the same transitive dependency).
# The fix clears $CARGO_HOME/registry/index and retries - unlike the
# glibc/E0463 cases, it must NOT run `cargo clean` (that only touches
# target/, not the registry cache).
call_log="$work_dir/calls-13.log"
cargo_home13="$work_dir/fake-cargo-home-13"
mkdir -p "$cargo_home13/registry/index/some-index/.cache/ac/ti"
touch "$cargo_home13/registry/index/some-index/.cache/ac/ti/actix-codec"
fake_cmd="$work_dir/fake-cmd-13.sh"
cat > "$fake_cmd" <<'EOF'
#!/usr/bin/env bash
echo "call" >> "$CALL_LOG"
calls=$(wc -l < "$CALL_LOG")
if [[ "$calls" -eq 1 ]]; then
  echo "error: failed to download \`actix-codec v0.5.4\`"
  echo
  echo "Caused by:"
  echo "  unable to get packages from source"
  echo
  echo "Caused by:"
  echo "  failed to find actix-codec v0.5.4 in path source"
  echo "note: this is an unexpected cargo internal error"
  exit 101
fi
if [[ -d "$CARGO_HOME_FOR_TEST/registry/index" ]]; then
  echo "index cache still present on retry"
  exit 1
fi
echo "build ok after clearing the registry index cache"
exit 0
EOF
chmod +x "$fake_cmd"

set +e
out=$(CALL_LOG="$call_log" CARGO_HOME="$cargo_home13" CARGO_HOME_FOR_TEST="$cargo_home13" bash "$script" "$fake_cmd" 2>&1)
status=$?
set -e
if [[ $status -eq 0 ]]; then
  echo "PASS: exits 0 after clearing the registry index cache and retrying past a path-source failure"
else
  echo "FAIL: expected exit 0, got $status"
  fail=1
fi
assert_contains "$out" "build ok after clearing the registry index cache" "retry succeeds once the index cache is gone"
assert_contains "$out" "registry index cache looks corrupted" "warns about the corrupted registry index cache"
build_calls=$(wc -l < "$call_log")
if [[ "$build_calls" -eq 2 ]]; then
  echo "PASS: invokes the build command twice (failing attempt + post-clear retry)"
else
  echo "FAIL: expected 2 build calls, got $build_calls"
  fail=1
fi
if [[ ! -d "$cargo_home13/registry/index" ]]; then
  echo "PASS: removes \$CARGO_HOME/registry/index before retrying"
else
  echo "FAIL: \$CARGO_HOME/registry/index was not removed before retrying"
  fail=1
fi


# mecha10-api carried an extra case this reconciliation folds in: `cargo
# test ... --doc` against a scope with zero library targets hard-fails with
# a fixed message instead of "0 doctests ran" - not a real test failure, so
# it should be treated as a pass. Only applies to --doc invocations, and
# only when no other real error is mixed in.
call_log="$work_dir/calls-14.log"
fake_cmd14="$work_dir/fake-cmd-14.sh"
cat > "$fake_cmd14" <<'EOF'
#!/usr/bin/env bash
echo "call" >> "$CALL_LOG"
echo "error: no library targets found in package \`some-bin-only-crate\`"
exit 101
EOF
chmod +x "$fake_cmd14"

set +e
out=$(CALL_LOG="$call_log" bash "$script" "$fake_cmd14" test --doc --workspace 2>&1)
status=$?
set -e
if [[ $status -eq 0 ]]; then
  echo "PASS: treats a no-library-targets --doc failure as a pass"
else
  echo "FAIL: expected exit 0, got $status"
  fail=1
fi
assert_contains "$out" "nothing to doctest" "reports the no-lib-targets --doc case as a non-failure"
calls=$(wc -l < "$call_log")
if [[ "$calls" -eq 1 ]]; then
  echo "PASS: does not retry the no-library-targets --doc case"
else
  echo "FAIL: expected 1 call, got $calls"
  fail=1
fi

call_log="$work_dir/calls-15.log"
fake_cmd15="$work_dir/fake-cmd-15.sh"
cat > "$fake_cmd15" <<'EOF'
#!/usr/bin/env bash
echo "call" >> "$CALL_LOG"
echo "error: no library targets found in package \`some-bin-only-crate\`"
echo "error[E0308]: mismatched types"
exit 101
EOF
chmod +x "$fake_cmd15"

set +e
out=$(CALL_LOG="$call_log" bash "$script" "$fake_cmd15" test --doc --workspace 2>&1)
status=$?
set -e
if [[ $status -eq 101 ]]; then
  echo "PASS: still fails a --doc run when a real error is mixed in with the no-lib-targets message"
else
  echo "FAIL: expected exit 101, got $status"
  fail=1
fi

call_log="$work_dir/calls-16.log"
fake_cmd16="$work_dir/fake-cmd-16.sh"
cat > "$fake_cmd16" <<'EOF'
#!/usr/bin/env bash
echo "call" >> "$CALL_LOG"
echo "error: no library targets found in package \`some-bin-only-crate\`"
exit 101
EOF
chmod +x "$fake_cmd16"

set +e
out=$(CALL_LOG="$call_log" bash "$script" "$fake_cmd16" test --workspace 2>&1)
status=$?
set -e
if [[ $status -eq 101 ]]; then
  echo "PASS: does not apply the no-lib-targets pass-through to a non---doc invocation"
else
  echo "FAIL: expected exit 101, got $status"
  fail=1
fi

if [[ $fail -ne 0 ]]; then
  echo "One or more tests FAILED"
  exit 1
fi
echo "All cargo-with-sccache-fallback.sh tests passed"
