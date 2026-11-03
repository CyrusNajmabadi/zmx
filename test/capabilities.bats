#!/usr/bin/env bats
# Real daemon checks complement the parser and capability host unit tests.

load test_helper

@test "invalid capability names fail before attach or run creates a session" {
  for command in attach run; do
    for names in missing osc7501,osc7501 osc7 osc7501, ,osc7501; do
      run "$ZMX" "$command" --capabilities="$names" rejected
      [ "$status" -ne 0 ]
      [[ "$output" == *capability* || "$output" == *capabilities* ]]
      [ ! -S "$ZMX_DIR/rejected" ]
    done
  done
}

@test "missing and repeated capability flags fail before creating a session" {
  for command in attach run; do
    run "$ZMX" "$command" --capabilities
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires a comma-separated list"* ]]
    run "$ZMX" "$command" --capabilities --help
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires a comma-separated list"* ]]
    run "$ZMX" "$command" --capabilities= --capabilities=osc7501 rejected
    [ "$status" -ne 0 ]
    [[ "$output" == *"only be specified once"* ]]
    [ ! -S "$ZMX_DIR/rejected" ]
  done
}

@test "invalid run capabilities fail without waiting for piped input" {
  python3 -B "$BATS_TEST_DIRNAME/capabilities.py" invalid-stdin "$ZMX" 3>&-
}

@test "nested attach rejects a capability selection without switching sessions" {
  run env ZMX_SESSION=not-running "$ZMX" attach --capabilities=osc7501 rejected
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires attaching from outside a zmx session"* ]]
  [ ! -S "$ZMX_DIR/rejected" ]
}

@test "omitted optional selection ignores the environment and preserves required behavior" {
  python3 -B "$BATS_TEST_DIRNAME/capabilities.py" required "$ZMX" 3>&-
}

@test "libzmx default selection ignores capability environment" {
  (cd "$REPO_DIR" && zig build test-fixtures)
  python3 -B "$BATS_TEST_DIRNAME/capabilities.py" library-default "$ZMX" 3>&-
}

@test "libzmx runs OSC 7 and OSC 7501 together through the capability API" {
  (cd "$REPO_DIR" && zig build test-fixtures)
  python3 -B "$BATS_TEST_DIRNAME/capabilities.py" compiled "$ZMX" 3>&-
}

@test "CLI run enables optional capabilities with both flag forms" {
  python3 -B "$BATS_TEST_DIRNAME/capabilities.py" cli-separate "$ZMX" 3>&-
  python3 -B "$BATS_TEST_DIRNAME/capabilities.py" cli-equals "$ZMX" 3>&-
}

@test "CLI attach passes labels and capabilities to the new daemon" {
  python3 -B "$BATS_TEST_DIRNAME/capabilities.py" cli-attach "$ZMX" 3>&-
}
