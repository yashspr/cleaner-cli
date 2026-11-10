#!/usr/bin/env bats
# Pristine fork: PRISTINE_CONFIG_DIR / PRISTINE_CACHE_DIR / PRISTINE_LOG_DIR
# and PRISTINE_PROTECT_PATHS (lib/pristine/paths.sh). See CHANGES-FORK.md.

load helpers/common

bats_require_minimum_version 1.5.0

setup_file() {
    mole_test_setup_home pristine-data-dirs
    MOLE_LSREGISTER_PATH=""
    export MOLE_LSREGISTER_PATH
}

teardown_file() {
    mole_test_teardown_home
}

setup() {
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
    rm -rf "${HOME:?}"/*
    rm -rf "$HOME/Library" "$HOME/.config" "$HOME/.cache"
    mkdir -p "$HOME/Library/Caches" "$HOME/Library/Logs"

    APP_SUPPORT="$HOME/Library/Application Support/com.example.host"
    APP_CACHES="$HOME/Library/Caches/com.example.host"
    APP_LOGS="$HOME/Library/Logs/com.example.host"
}

make_mock_bin() {
    MOCK_BIN="$HOME/mock-bin"
    mkdir -p "$MOCK_BIN"
    cat > "$MOCK_BIN/brew" << 'MOCK'
#!/bin/bash
case "${1:-}" in
    --cache) echo "$HOME/Library/Caches/Homebrew" ;;
    --prefix) echo "$HOME/homebrew" ;;
esac
exit 0
MOCK
    printf '#!/bin/bash\nexit 1\n' > "$MOCK_BIN/xcrun"
    printf '#!/bin/bash\nexit 1\n' > "$MOCK_BIN/sudo"
    printf '#!/bin/bash\nexit 1\n' > "$MOCK_BIN/lsof"
    printf '#!/bin/bash\nprintf "  PID  PPID COMM ARGS\\n"\n' > "$MOCK_BIN/ps"
    chmod +x "$MOCK_BIN"/*
}

@test "clean with data dirs writes nothing to the upstream folders" {
    local other="$HOME/Library/Caches/com.example.other"
    mkdir -p "$other" "$APP_CACHES/WebKit"
    dd if=/dev/zero of="$other/a.bin" bs=1024 count=64 2> /dev/null
    dd if=/dev/zero of="$APP_CACHES/WebKit/b.bin" bs=1024 count=64 2> /dev/null
    make_mock_bin

    run --separate-stderr env HOME="$HOME" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=1 PATH="$MOCK_BIN:$PATH" \
        PRISTINE_CONFIG_DIR="$APP_SUPPORT/engine" \
        PRISTINE_CACHE_DIR="$APP_CACHES/engine" \
        PRISTINE_LOG_DIR="$APP_LOGS/engine" \
        PRISTINE_PROTECT_PATHS="$APP_SUPPORT:$APP_CACHES:$APP_LOGS" \
        "$PROJECT_ROOT/pristine" clean --dry-run --json

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"{\"type\":\"item\",\"path\":\"$other\","* ]] || return 1
    [[ "$output" != *"{\"type\":\"item\",\"path\":\"$APP_CACHES"* ]] || return 1
    [[ "$output" == *"{\"type\":\"operation\",\"action\":\"SKIPPED\",\"path\":\"$APP_CACHES\",\"detail\":\"protected\""* ]] || return 1
    [[ -f "$APP_LOGS/engine/mole.log" ]] || return 1
    [[ ! -e "$HOME/.config/mole" && ! -e "$HOME/.cache/mole" && ! -e "$HOME/Library/Logs/mole" ]] || return 1
}

@test "a clean never removes the data dirs or protected folders" {
    local gone="$HOME/Library/Logs/com.example.other"
    mkdir -p "$gone" "$APP_LOGS/engine" "$HOME/Library/Caches/engine-cache"
    printf 'x' > "$gone/f"
    printf 'x' > "$APP_LOGS/engine/operations.log"
    printf 'x' > "$HOME/Library/Caches/engine-cache/f"

    cat > "$HOME/run.sh" << EOF
set -euo pipefail
source "\$PROJECT_ROOT/bin/clean.sh"
pristine_clean_main_hook --json
DRY_RUN=false
files_cleaned=0
total_size_cleaned=0
total_items=0
CURRENT_SECTION="Test"
start_section_spinner() { :; }
stop_section_spinner() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
note_activity() { :; }
safe_clean "$HOME"/Library/Logs/* "User app logs"
safe_clean "$HOME/Library/Caches/engine-cache" "Engine cache"
EOF
    run --separate-stderr env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        PRISTINE_CACHE_DIR="$HOME/Library/Caches/engine-cache" \
        PRISTINE_LOG_DIR="$APP_LOGS/engine" \
        PRISTINE_PROTECT_PATHS="$APP_LOGS" \
        /bin/bash --noprofile --norc "$HOME/run.sh"

    [ "$status" -eq 0 ] || return 1
    [[ ! -e "$gone" ]] || return 1
    [[ -f "$APP_LOGS/engine/operations.log" ]] || return 1
    [[ -f "$HOME/Library/Caches/engine-cache/f" ]] || return 1
}

@test "data dirs redirect config, history and caches" {
    # shellcheck disable=SC2016  # Expanded by the child bash.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        PRISTINE_CONFIG_DIR="$APP_SUPPORT/engine/" \
        PRISTINE_CACHE_DIR="$APP_CACHES/engine" \
        PRISTINE_LOG_DIR="$APP_LOGS/engine" \
        /bin/bash --noprofile --norc -c '
            source "$PROJECT_ROOT/lib/core/common.sh"
            source "$PROJECT_ROOT/lib/core/history.sh"
            source "$PROJECT_ROOT/lib/manage/whitelist.sh"
            source "$PROJECT_ROOT/lib/manage/purge_paths.sh"
            printf "%s\n" "$PRISTINE_CONFIG_DIR" "$WHITELIST_CONFIG_CLEAN" "$PURGE_PATHS_CONFIG" \
                "$(history_operations_log_file)" "$(history_deletions_log_file)"'

    [ "$status" -eq 0 ] || return 1
    [[ "${lines[0]}" == "$APP_SUPPORT/engine" ]] || return 1
    [[ "${lines[1]}" == "$APP_SUPPORT/engine/whitelist" ]] || return 1
    [[ "${lines[2]}" == "$APP_SUPPORT/engine/purge_paths" ]] || return 1
    [[ "${lines[3]}" == "$APP_LOGS/engine/operations.log" ]] || return 1
    [[ "${lines[4]}" == "$APP_LOGS/engine/deletions.log" ]] || return 1
}

@test "a protected folder is matched without case, and nothing beside it is" {
    # Uninstall builds ".../Application Support/<App Name>" from the app's name;
    # on a case-insensitive volume that is the folder the user protected under
    # the name on disk.
    local kept="$HOME/Library/Application Support/obsidian"
    # shellcheck disable=SC2016  # Expanded by the child bash.
    run --separate-stderr env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PRISTINE_PROTECT_PATHS="$kept" \
        /bin/bash --noprofile --norc -c '
            source "$PROJECT_ROOT/lib/core/common.sh"
            base="$HOME/Library/Application Support"
            for p in "$base/obsidian" "$base/Obsidian" "$base/OBSIDIAN/" "$base/Obsidian/plugins/x" \
                "$base/Obsidian2" "$base/Obsid" "$base"; do
                if should_protect_path "$p"; then echo "kept $p"; else echo "free $p"; fi
            done
            # The caller'"'"'s own setting is left as it was.
            shopt -q nocasematch && echo "nocasematch on" || echo "nocasematch off"'

    [ "$status" -eq 0 ] || return 1
    local base="$HOME/Library/Application Support"
    [[ "${lines[0]}" == "kept $base/obsidian" ]] || return 1
    [[ "${lines[1]}" == "kept $base/Obsidian" ]] || return 1
    [[ "${lines[2]}" == "kept $base/OBSIDIAN/" ]] || return 1
    [[ "${lines[3]}" == "kept $base/Obsidian/plugins/x" ]] || return 1
    [[ "${lines[4]}" == "free $base/Obsidian2" ]] || return 1
    [[ "${lines[5]}" == "free $base/Obsid" ]] || return 1
    [[ "${lines[6]}" == "free $base" ]] || return 1
    [[ "${lines[7]}" == "nocasematch off" ]] || return 1
}

@test "an invalid data dir is ignored and the upstream default applies" {
    # shellcheck disable=SC2016  # Expanded by the child bash.
    run --separate-stderr env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        PRISTINE_LOG_DIR="relative/logs" PRISTINE_PROTECT_PATHS="/:$HOME/../x" \
        /bin/bash --noprofile --norc -c '
            source "$PROJECT_ROOT/lib/core/common.sh"
            source "$PROJECT_ROOT/lib/core/history.sh"
            printf "%s|%s\n" "${PRISTINE_LOG_DIR:-unset}" "${#PRISTINE_PROTECTED_ROOTS[@]}"
            history_operations_log_file'

    [ "$status" -eq 0 ] || return 1
    [[ "${lines[0]}" == "unset|0" ]] || return 1
    [[ "${lines[1]}" == "$HOME/Library/Logs/mole/operations.log" ]] || return 1
    [[ "$stderr" == *"Ignoring PRISTINE_LOG_DIR"* ]] || return 1
}

# Upstream merges can add new hard-coded state paths. Every one the CLI's
# commands use must go through the overrides; Mole's own install/update/remove
# management, root's private temp dir and help text that names the upstream
# folders (`mo remove`'s usage, `mo slim`'s whitelist note) are left alone on
# purpose.
@test "no command reads or writes the upstream folders directly" {
    local hits
    hits=$(cd "$PROJECT_ROOT" && grep -rnE '(\.config|\.cache|Library/Logs)"?/mole\b' mole bin lib |
        grep -vE 'PRISTINE_(CONFIG|CACHE|LOG)_DIR:-' |
        grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' |
        grep -vE '^lib/manage/(update|remove)\.sh:' |
        grep -vE 'root_home|/var/root/' |
        grep -vE '^lib/core/app_protection\.sh:[0-9]+:[[:space:]]*\*/Library/Logs/mole \|' |
        grep -vE '^mole:[0-9]+:Remove Mole from this Mac\. ' |
        grep -vE '^bin/slim\.sh:[0-9]+:[[:space:]]*echo "Apps protected by ' || true)
    if [[ -n "$hits" ]]; then
        printf 'unrouted state path:\n%s\n' "$hits" >&2
        return 1
    fi

    hits=$(cd "$PROJECT_ROOT" && grep -rn --include='*.go' -E '"\.(config|cache)", "mole"' cmd | grep -v '_test\.go:' || true)
    [[ $(wc -l <<< "$hits") -eq 2 ]] || {
        printf 'Go state paths changed; route new ones through pristineDataDir:\n%s\n' "$hits" >&2
        return 1
    }
    grep -q 'pristineDataDir("PRISTINE_CACHE_DIR")' "$PROJECT_ROOT/cmd/analyze/cache.go" || return 1
    grep -q 'pristineDataDir("PRISTINE_CONFIG_DIR")' "$PROJECT_ROOT/cmd/status/prefs.go" || return 1
}
