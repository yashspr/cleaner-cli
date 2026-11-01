#!/usr/bin/env bats
# Pristine fork: optimize --json / --skip-from / --admin.

load helpers/common

bats_require_minimum_version 1.5.0

setup_file() {
    mole_test_setup_home pristine-optimize-json
}

teardown_file() {
    mole_test_teardown_home
}

all_task_ids() {
    (
        # shellcheck source=lib/optimize/catalog.sh
        source "$PROJECT_ROOT/lib/optimize/catalog.sh"
        printf '%s\n' "${MOLE_OPTIMIZE_ACTIONS[@]}"
    )
}

@test "optimize --json with every task skipped emits start, one task event each, summary and end" {
    all_task_ids > "$HOME/skip.txt"
    local task_count
    task_count=$(wc -l < "$HOME/skip.txt" | tr -d ' ')

    # Every task is skipped, so nothing runs even though this is a real run.
    run --separate-stderr env HOME="$HOME" MOLE_TEST_NO_AUTH=1 \
        "$PROJECT_ROOT/pristine" optimize --json --skip-from "$HOME/skip.txt"

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *'{"type":"start","schema_version":1,"command":"optimize","dry_run":false,"admin":false,"tasks":[{"id":"'* ]] || return 1
    [[ "$output" == *'{"type":"task","id":"cache_refresh","label":"Finder Cache Refresh","status":"skipped","detail":"'*'Skipped (deselected): Finder Cache Refresh"}'* ]] || return 1
    [[ "$(grep -c '"type":"task"' <<< "$output")" -eq "$task_count" ]] || return 1
    [[ "$output" == *"\"outcomes\":{\"applied\":0,\"unchanged\":0,\"skipped\":$task_count,"* ]] || return 1
    [[ "${lines[${#lines[@]} - 1]}" == '{"type":"end","exit_code":0}' ]] || return 1
}

@test "optimize --skip-from rejects unknown task ids before running anything" {
    printf 'cache_refresh\nnot_a_task\n' > "$HOME/skip.txt"
    run env HOME="$HOME" MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/pristine" optimize --json --skip-from "$HOME/skip.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$output" == *"Unknown optimize task id: not_a_task"* ]] || return 1
    [[ "$output" != *'"type":"task"'* ]] || return 1
}

@test "optimize --json refuses the interactive --whitelist editor" {
    run env HOME="$HOME" MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/pristine" optimize --json --whitelist
    [ "$status" -eq 1 ] || return 1
    [[ "$output" == *"cannot be combined with --json"* ]] || return 1
}
