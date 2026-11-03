#!/usr/bin/env bats
# OSC 7501 task record and support query tests against a real daemon.

load ../test_helper

program_status_test() {
  PYTHONPATH="$REPO_DIR/test" python3 -B \
    "$BATS_TEST_DIRNAME/integration.py" \
    "$1" "$ZMX" "$BATS_TEST_TMPDIR" 3>&-
}

@test "OSC 7501 capability restores current tasks privately after reconnect" {
  program_status_test records
}

@test "OSC 7501 capability finishes an interrupted report after reconnect" {
  program_status_test pending-report
}

@test "OSC 7501 capability enables agents before attachment and after detachment" {
  program_status_test detached-capability
}

@test "disabled Program Status still forwards live reports without saving them" {
  program_status_test disabled
}
