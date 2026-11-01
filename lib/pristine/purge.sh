#!/bin/bash
# Pristine fork: machine-readable `purge`.
# Fork-only file; bin/purge.sh sources it and calls pristine_purge_main_hook
# at the top of main(). See CHANGES-FORK.md.
#
#   purge --json --dry-run [--include-empty]                  list candidates
#   purge --json --yes [--exclude-from F | --only-from F]     remove without the menu
#
# Selection keeps upstream's non-interactive rule: artifacts modified in the
# last 7 days (or whose activity is uncertain) and cloud-synced artifacts are
# never removed unattended, except that a recent artifact listed by exact path
# in --only-from counts as picked by a person, like a row ticked in upstream's
# menu (pristine_purge_picked_recent). --exclude-from joins the whitelist (dropped at
# discovery and refused again at the final remove); --only-from treats every
# other candidate as whitelisted. All discovery-time and pre-delete
# protection, identity and activity checks still run.

_PRISTINE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pristine/common.sh
source "$_PRISTINE_LIB_DIR/common.sh"

declare -a PRISTINE_PURGE_ARGS=()
PRISTINE_PURGE_TOTAL_ITEMS=""
PRISTINE_PURGE_TOTAL_KB=""
PRISTINE_PURGE_CANDIDATES=0

pristine_purge_main_hook() {
    local flags="--json --exclude-from --only-from"
    pristine_parse_flags purge "$flags" "$@"
    PRISTINE_PURGE_ARGS=(${PRISTINE_ARGS[@]+"${PRISTINE_ARGS[@]}"})
    pristine_extend_help show_help "$flags"

    if [[ "$PRISTINE_JSON" == "true" ]]; then
        local arg
        for arg in ${PRISTINE_PURGE_ARGS[@]+"${PRISTINE_PURGE_ARGS[@]}"}; do
            if [[ "$arg" == "--paths" ]]; then
                echo "--paths opens an editor and cannot be combined with --json" >&2
                exit 1
            fi
        done
    fi

    pristine_exclude_via_whitelist

    if [[ -n "$PRISTINE_ONLY_FILE" ]]; then
        # Purge consults the whitelist with exact candidate paths, at binding
        # and in safe_remove; everything outside the only-list reads as kept.
        # shellcheck disable=SC2329  # Called by upstream code under its original name.
        pristine_wrap_function is_path_whitelisted && is_path_whitelisted() {
            _pristine_orig_is_path_whitelisted "$@" && return 0
            ! pristine_path_listed "${1:-}" ${PRISTINE_ONLY_PATHS[@]+"${PRISTINE_ONLY_PATHS[@]}"}
        }
    fi

    [[ "$PRISTINE_JSON" == "true" ]] || return 0
    pristine_json_begin
    pristine_install_operation_events ""

    # shellcheck disable=SC2329  # Called by upstream code under its original name.
    pristine_wrap_function start_purge && start_purge() {
        _pristine_orig_start_purge "$@"
        pristine_purge_emit_start
    }

    # Called exactly once per candidate that survived discovery, sizing and
    # protection, while the per-item locals of clean_project_artifacts are in
    # scope (bash dynamic scoping). tests/pristine_purge_json.bats pins the
    # local names read here.
    # shellcheck disable=SC2329  # Called by upstream code under its original name.
    pristine_wrap_function mole_purge_is_cloud_synced_path && mole_purge_is_cloud_synced_path() {
        local _pristine_cloud=0
        _pristine_orig_mole_purge_is_cloud_synced_path "$@" || _pristine_cloud=$?
        if [[ -n "${1:-}" && "${item:-}" == "$1" && -n "${artifact_type+set}" ]]; then
            pristine_purge_emit_candidate "$1" "$_pristine_cloud"
        fi
        return "$_pristine_cloud"
    }

    # shellcheck disable=SC2329  # Called by upstream code under its original name.
    pristine_wrap_function log_operation_session_end && log_operation_session_end() {
        PRISTINE_PURGE_TOTAL_ITEMS="${2:-0}"
        PRISTINE_PURGE_TOTAL_KB="${3:-0}"
        _pristine_orig_log_operation_session_end "$@"
    }

    # shellcheck disable=SC2329  # Called by upstream code under its original name.
    pristine_wrap_function perform_purge && perform_purge() {
        local rc=0
        _pristine_orig_perform_purge "$@" || rc=$?
        pristine_purge_emit_summary "$rc"
        return "$rc"
    }
}

# Called from the non-interactive selection in lib/clean/project.sh (tagged
# pristine-fork). $1 candidate path, $2 its activity state. True when the
# caller listed this recent artifact by exact path in --only-from: the app
# sends only rows a person ticked. Upstream's menu allows the same, and its
# final guard already accepts a known-recent row that was picked. Uncertain
# activity is never an override, and cloud-synced rows are skipped before this
# is asked; the running-project and content protections still apply.
pristine_purge_picked_recent() {
    [[ -n "${PRISTINE_ONLY_FILE:-}" && "${2:-}" == "recent" ]] || return 1
    pristine_path_listed "${1:-}" ${PRISTINE_ONLY_PATHS[@]+"${PRISTINE_ONLY_PATHS[@]}"}
}

pristine_purge_emit_start() {
    local roots="" root
    for root in ${PURGE_SEARCH_PATHS[@]+"${PURGE_SEARCH_PATHS[@]}"}; do
        [[ -n "$roots" ]] && roots+=","
        pristine_json_quote "$root"
        roots+="$PRISTINE_JQ"
    done
    pristine_json_emit "{\"type\":\"start\",\"schema_version\":$PRISTINE_JSON_SCHEMA_VERSION,\"command\":\"purge\",\"dry_run\":$(pristine_mole_dry_run_json),\"search_paths\":[$roots],\"excluded_paths\":${#PRISTINE_EXCLUDE_PATHS[@]},\"only_paths\":${#PRISTINE_ONLY_PATHS[@]}}"
}

# $1 path, $2 cloud status (0 = cloud-synced). Reads the caller's locals:
# size_kb, size_unknown, is_recent, activity_state, project_root, artifact_type.
pristine_purge_emit_candidate() {
    local path="$1" cloud=false selectable=true
    [[ "$2" == "0" ]] && cloud=true
    [[ "${is_recent:-true}" == "true" ]] && selectable=false
    [[ "$cloud" == "true" && "${MOLE_DRY_RUN:-0}" != "1" ]] && selectable=false

    local j_size="null"
    [[ "${size_unknown:-false}" != "true" && "${size_kb:-}" =~ ^[0-9]+$ ]] && j_size="$size_kb"

    local mtime age_days="null"
    mtime=$(get_file_mtime "$path" 2> /dev/null || echo "")
    if [[ "$mtime" =~ ^[0-9]+$ && "$mtime" -gt 0 ]]; then
        age_days=$((($(date +%s) - mtime) / 86400))
        [[ $age_days -lt 0 ]] && age_days=0
    fi

    local j_path j_root j_type j_activity
    pristine_json_quote "$path"
    j_path="$PRISTINE_JQ"
    pristine_json_quote "${project_root:-}"
    j_root="$PRISTINE_JQ"
    pristine_json_quote "${artifact_type:-}"
    j_type="$PRISTINE_JQ"
    pristine_json_quote "${activity_state:-uncertain}"
    j_activity="$PRISTINE_JQ"
    PRISTINE_PURGE_CANDIDATES=$((PRISTINE_PURGE_CANDIDATES + 1))
    pristine_json_emit "{\"type\":\"item\",\"path\":$j_path,\"project\":$j_root,\"artifact\":$j_type,\"size_kb\":$j_size,\"activity\":$j_activity,\"age_days\":$age_days,\"cloud\":$cloud,\"selectable\":$selectable}"
}

pristine_purge_emit_summary() {
    local rc="$1"
    local outcome="${PURGE_RUN_OUTCOME:-}"
    [[ -n "$outcome" ]] || outcome="unknown"
    pristine_json_emit "{\"type\":\"summary\",\"dry_run\":$(pristine_mole_dry_run_json),\"status\":\"$outcome\",\"exit_code\":$(pristine_json_int "$rc"),\"candidates\":$PRISTINE_PURGE_CANDIDATES,\"items\":$(pristine_json_int "${PRISTINE_PURGE_TOTAL_ITEMS:-0}"),\"size_kb\":$(pristine_json_int "${PRISTINE_PURGE_TOTAL_KB:-0}"),\"unmeasured\":$(pristine_json_int "${PURGE_UNKNOWN_SIZE_COUNT:-0}")}"
}
