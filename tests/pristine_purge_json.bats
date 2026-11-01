#!/usr/bin/env bats
# Pristine fork: purge --json / --exclude-from / --only-from.
# Scan roots come from the fixture's ~/.config/mole/purge_paths, so nothing
# outside HOME is discovered.

load helpers/common

bats_require_minimum_version 1.5.0

setup_file() {
    mole_test_setup_home pristine-purge-json
}

teardown_file() {
    mole_test_teardown_home
}

# A rebuildable npm project: upstream offers node_modules only with a lockfile
# and an install record newer than every package file.
make_project() {
    local dir="$1" age="$2"
    mkdir -p "$dir/node_modules/pkg"
    printf '{}\n' > "$dir/package.json"
    printf '{}\n' > "$dir/package-lock.json"
    dd if=/dev/zero of="$dir/node_modules/pkg/blob" bs=1024 count=16 2> /dev/null
    printf '{}\n' > "$dir/node_modules/.package-lock.json"
    if [[ "$age" == "old" ]]; then
        find "$dir" -exec touch -t 202001010000 {} +
        touch -t 202001020000 "$dir/node_modules/.package-lock.json"
    fi
}

setup() {
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
    rm -rf "${HOME:?}"/*
    rm -rf "$HOME/.config" "$HOME/.cache"
    mkdir -p "$HOME/.config/mole" "$HOME/code"
    printf '%s\n' "$HOME/code" > "$HOME/.config/mole/purge_paths"
    make_project "$HOME/code/alpha" old
    make_project "$HOME/code/beta" old
    make_project "$HOME/code/gamma" recent
}

run_purge() {
    run --separate-stderr env HOME="$HOME" MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/pristine" purge "$@"
}

@test "purge --json --dry-run lists candidates with activity and selectable flags" {
    run_purge --json --dry-run

    [ "$status" -eq 0 ] || return 1
    [[ "${lines[0]}" == '{"type":"start","schema_version":1,"command":"purge","dry_run":true,"search_paths":['*'],"excluded_paths":0,"only_paths":0}' ]] || return 1
    [[ "$output" == *"{\"type\":\"item\",\"path\":\"$HOME/code/alpha/node_modules\",\"project\":\"$HOME/code/alpha\",\"artifact\":\"node_modules\",\"size_kb\":"*'"activity":"old",'*'"cloud":false,"selectable":true}'* ]] || return 1
    [[ "$output" == *"{\"type\":\"item\",\"path\":\"$HOME/code/gamma/node_modules\""*'"selectable":false}'* ]] || return 1
    [[ "$output" == *'"type":"summary","dry_run":true,"status":"completed","exit_code":0,"candidates":3,"items":2,'* ]] || return 1
    [[ "${lines[${#lines[@]} - 1]}" == '{"type":"end","exit_code":0}' ]] || return 1
    [[ -d "$HOME/code/alpha/node_modules" && -d "$HOME/code/beta/node_modules" ]] || return 1
}

@test "purge --json --yes --exclude-from keeps the excluded artifact and the recent one" {
    printf '%s\n' "$HOME/code/beta/node_modules" > "$HOME/exclude.txt"

    run_purge --json --yes --exclude-from "$HOME/exclude.txt"

    [ "$status" -eq 0 ] || return 1
    [[ ! -e "$HOME/code/alpha/node_modules" ]] || return 1
    [[ -d "$HOME/code/beta/node_modules" ]] || return 1
    [[ -d "$HOME/code/gamma/node_modules" ]] || return 1
    [[ "$output" == *"{\"type\":\"operation\",\"action\":\"REMOVED\",\"path\":\"$HOME/code/alpha/node_modules\""* ]] || return 1
    [[ "$output" != *"\"path\":\"$HOME/code/beta/node_modules\",\"project\""* ]] || return 1
    [[ "$output" == *'"type":"summary","dry_run":false,"status":"completed","exit_code":0,"candidates":2,"items":1,'* ]] || return 1
}

@test "purge --json --yes --only-from removes only the listed artifact and never a recent one" {
    printf '%s\n%s\n' "$HOME/code/beta/node_modules" "$HOME/code/gamma/node_modules" > "$HOME/only.txt"

    run_purge --json --yes --only-from "$HOME/only.txt"

    [ "$status" -eq 0 ] || return 1
    [[ -d "$HOME/code/alpha/node_modules" ]] || return 1
    [[ ! -e "$HOME/code/beta/node_modules" ]] || return 1
    [[ -d "$HOME/code/gamma/node_modules" ]] || return 1
    [[ "$output" == *'"items":1,'* ]] || return 1
}

@test "purge --json refuses the --paths editor" {
    run env HOME="$HOME" MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/pristine" purge --json --paths
    [ "$status" -eq 1 ] || return 1
    [[ "$output" == *"cannot be combined with --json"* ]] || return 1
}
