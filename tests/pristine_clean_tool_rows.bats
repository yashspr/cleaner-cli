#!/usr/bin/env bats
# Pristine fork: a tool's own cleanup (brew cleanup, npm cache clean, docker
# prune…) is a preview row that can be unticked (lib/pristine/paths.sh,
# pristine_tool_row). See CHANGES-FORK.md.

load helpers/common

bats_require_minimum_version 1.5.0

setup_file() {
    mole_test_setup_home pristine-clean-tool-rows
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
    rm -rf "$HOME/Library" "$HOME/.config" "$HOME/.cache" "$HOME/.npm"
    mkdir -p "$HOME/Library/Caches/Homebrew/downloads" "$HOME/hb/bin" "$HOME/hb/Cellar/node/20.1.0" "$HOME/.npm/_cacache"

    # A Homebrew at $HOME/hb that records every call; its dry run removes an old
    # node, a download (listed by the cache's own row) and an old Ruby.
    cat > "$HOME/hb/bin/brew" << 'MOCK'
#!/bin/bash
printf '%s\n' "$*" >> "$HOME/brew-calls"
case "${1:-}" in
    --prefix) echo "$HOME/hb" ;;
    --cache) echo "$HOME/Library/Caches/Homebrew" ;;
    cleanup)
        if [[ " $* " == *" --dry-run "* ]]; then
            printf 'Would remove: %s (1,234 files, 50.5MB)\n' "$HOME/hb/Cellar/node/20.1.0"
            printf 'Would remove: %s (30MB)\n' "$HOME/Library/Caches/Homebrew/downloads/abc--node.tar.gz"
            printf 'Would remove: %s (2.5MB)\n' "$HOME/hb/Library/Homebrew/vendor/portable-ruby/3.3"
            echo '==> This operation would free approximately 83MB of disk space.'
        fi
        ;;
esac
exit 0
MOCK
    chmod +x "$HOME/hb/bin/brew"
}

@test "a JSON preview lists brew cleanup and npm's own cleanup as rows" {
    # -c, not a here-document: JSON mode points stdin at /dev/null.
    # shellcheck disable=SC2016  # Expanded by the child bash.
    local script='
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pristine_clean_main_hook --json --dry-run
DRY_RUN=true
CURRENT_SECTION="Developer tools"
CLEAN_PREVIEW_LEDGER_FILE=$(mktemp "$HOME/ledger.XXXXXX")
start_section_spinner() { :; }
stop_section_spinner() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
clean_homebrew
clean_tool_cache "npm cache" "$HOME/.npm" npm cache clean --force
pristine_clean_emit_preview_items'

    run --separate-stderr env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$HOME/hb/bin:$PATH" \
        MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc -c "$script"

    [ "$status" -eq 0 ] || { echo "$output$stderr"; return 1; }
    # 50.5MB + 2.5MB: the download is the cache row's, not this one's.
    [[ "$output" == *"{\"type\":\"item\",\"path\":\"$HOME/hb/Cellar\",\"section\":\"Developer tools\",\"size_kb\":54272,\"size_known\":true,"* ]] ||
        { echo "$output"; return 1; }
    [[ "$output" == *"{\"type\":\"item\",\"path\":\"$HOME/.npm\",\"section\":\"Developer tools\",\"size_kb\":null,\"size_known\":false,"* ]] ||
        { echo "$output"; return 1; }
    ! grep -qx "cleanup --prune=30" "$HOME/brew-calls" || return 1
}

@test "an unticked Homebrew cleanup row keeps brew cleanup from running" {
    # shellcheck disable=SC2016  # Expanded by the child bash.
    local script='
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pristine_clean_main_hook --json
DRY_RUN=false
start_section_spinner() { :; }
stop_section_spinner() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
note_activity() { :; }
[[ -n "${KEEP:-}" ]] && WHITELIST_PATTERNS+=("$KEEP")
clean_homebrew'

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$HOME/hb/bin:$PATH" KEEP="$HOME/hb/Cellar" \
        MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc -c "$script"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    ! grep -qx "cleanup --prune=30" "$HOME/brew-calls" || { cat "$HOME/brew-calls"; return 1; }

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$HOME/hb/bin:$PATH" \
        MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc -c "$script"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -qx "cleanup --prune=30" "$HOME/brew-calls" || { cat "$HOME/brew-calls"; return 1; }
}
