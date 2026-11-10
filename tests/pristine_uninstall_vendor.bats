#!/usr/bin/env bats
# Pristine fork: an app's shortened name is never a company's shared folder
# (lib/pristine/paths.sh, pristine_shared_vendor_name). See CHANGES-FORK.md.

load helpers/common

setup_file() {
    mole_test_setup_home pristine-uninstall-vendor
}

teardown_file() {
    mole_test_teardown_home
}

setup() {
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
    find "$HOME" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2> /dev/null || true
    source "$PROJECT_ROOT/lib/core/base.sh"
    source "$PROJECT_ROOT/lib/core/log.sh"
    source "$PROJECT_ROOT/lib/core/app_protection.sh"
}

listed() {
    grep -Fxq "$1" <<< "$result"
}

@test "uninstalling Microsoft Edge offers Edge's folders, not Microsoft's" {
    local support="$HOME/Library/Application Support" caches="$HOME/Library/Caches"
    mkdir -p "$support/Microsoft Edge" "$support/Microsoft/Teams" "$caches/Microsoft/AutoUpdate" \
        "$caches/Microsoft Edge" "$HOME/Library/Logs/Microsoft"
    printf 'x' > "$support/Microsoft/Teams/settings.json"

    result=$(find_app_files "com.microsoft.edgemac" "Microsoft Edge")

    listed "$support/Microsoft Edge" || return 1
    listed "$caches/Microsoft Edge" || return 1
    ! listed "$support/Microsoft" || return 1
    ! listed "$caches/Microsoft" || return 1
    ! listed "$HOME/Library/Logs/Microsoft" || return 1
}

@test "a channel build never shortens to a company name, and other products still do" {
    local caches="$HOME/Library/Caches"
    mkdir -p "$caches/Google" "$caches/Zed"

    result=$(find_app_files "com.example.googledev" "Google Dev")
    ! listed "$caches/Google" || return 1

    result=$(find_app_files "dev.zed.Zed-Nightly" "Zed Nightly")
    listed "$caches/Zed" || return 1
}

@test "the sibling check keeps Microsoft Edge's full name" {
    source "$PROJECT_ROOT/lib/uninstall/batch.sh"
    local stripped
    _uninstall_strip_version_suffix_into stripped "Microsoft Edge"
    [[ "$stripped" == "Microsoft Edge" ]] || return 1
    _uninstall_strip_version_suffix_into stripped "Microsoft Edge Beta"
    [[ "$stripped" == "Microsoft Edge" ]] || return 1
}
