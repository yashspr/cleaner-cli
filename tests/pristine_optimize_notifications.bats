#!/usr/bin/env bats
# Pristine fork: Notification Center cleanup keeps notifications from the last
# 30 days (lib/optimize/tasks.sh, opt_notification_cleanup). See CHANGES-FORK.md.

load helpers/common

setup_file() {
    mole_test_setup_home pristine-optimize-notifications
}

teardown_file() {
    mole_test_teardown_home
}

@test "notification cleanup removes only notifications older than 30 days" {
    command -v sqlite3 > /dev/null 2>&1 || skip "sqlite3 not available"
    local db="$HOME/nc.db"
    rm -f "$db"
    # delivered_date counts seconds from 2001-01-01, as macOS stores it.
    sqlite3 "$db" "CREATE TABLE record (rec_id INTEGER PRIMARY KEY, delivered_date REAL);
        INSERT INTO record VALUES (1, strftime('%s','now','-5 days') - strftime('%s','2001-01-01'));
        INSERT INTO record VALUES (2, strftime('%s','now','-40 days') - strftime('%s','2001-01-01'));"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" NC_DB="$db" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
resolve_notification_center_db() { printf '%s\n' "$NC_DB"; }
opt_existing_file_size_kb_strict() { echo 60000; }
run_with_timeout() { :; }
execute_optimization notification_cleanup
sqlite3 "$NC_DB" "SELECT rec_id FROM record ORDER BY rec_id;"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "${lines[${#lines[@]} - 1]}" == "1" ]] || { echo "$output"; return 1; }
    [[ "$output" != *$'\n'"2"* ]] || { echo "$output"; return 1; }
}
