#!/usr/bin/env bats
# Pristine fork: admin prompt when launched without a controlling terminal
# (a GUI app spawns the CLI that way). See CHANGES-FORK.md.

load helpers/common

setup_file() {
    mole_test_setup_home pristine-sudo-dialog
}

teardown_file() {
    mole_test_teardown_home
}

setup() {
    command -v python3 > /dev/null 2>&1 || skip "python3 needed to detach from the terminal"
    STUB_DIR="$HOME/stub-bin"
    TRACE="$HOME/osascript.trace"
    rm -rf "$STUB_DIR" "$TRACE"
    mkdir -p "$STUB_DIR"
    # osascript records its arguments and returns no password (user cancelled).
    cat > "$STUB_DIR/osascript" << STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$TRACE"
exit 0
STUB
    # sudo: no cached session; -k (clear cache) succeeds like the real one.
    # shellcheck disable=SC2016  # $1 belongs to the stub script, not this shell.
    printf '#!/bin/bash\n[[ "$1" == "-k" ]] && exit 0\nexit 1\n' > "$STUB_DIR/sudo"
    chmod +x "$STUB_DIR/osascript" "$STUB_DIR/sudo"
}

# Run request_sudo_access in a new session, so /dev/tty passes the -r/-w mode
# check but cannot be opened: the state of an app-spawned process.
run_detached_request() {
    # shellcheck disable=SC2016  # The Python program is literal; nothing expands here.
    run env -u MOLE_TEST_MODE -u MOLE_TEST_NO_AUTH PATH="$STUB_DIR:$PATH" \
        PROJECT_ROOT="$PROJECT_ROOT" PRISTINE_DIALOG_TITLE="$1" \
        python3 -c '
import os, subprocess, sys
os.setsid()
sys.exit(subprocess.call(
    ["/bin/bash", "-c", "source \"$PROJECT_ROOT/lib/core/common.sh\"; request_sudo_access \"Test prompt\""],
    stdin=subprocess.DEVNULL))'
}

@test "request_sudo_access uses the native dialog without a controlling terminal" {
    run_detached_request "Pristine"
    [ "$status" -eq 1 ] || return 1 # cancelled dialog → no admin access
    [[ -f "$TRACE" ]] || return 1
    grep -qF 'with title "Pristine"' "$TRACE" || return 1
}

@test "request_sudo_access keeps the upstream title by default and strips unsafe title characters" {
    run_detached_request ""
    grep -qF 'with title "Mole"' "$TRACE" || return 1

    rm -f "$TRACE"
    run_detached_request 'X" & do shell script "touch /tmp/pwned'
    grep -qF 'with title "X  do shell script touch tmppwned"' "$TRACE" || return 1
}
