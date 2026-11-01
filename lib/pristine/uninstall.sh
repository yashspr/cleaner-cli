#!/bin/bash
# Pristine fork: machine-readable `uninstall`.
# Fork-only file; bin/uninstall.sh sources it and calls
# pristine_uninstall_main_hook at the top of main(). See CHANGES-FORK.md.
#
#   uninstall --json --list                          installed apps
#   uninstall --json --dry-run APP...                per-app removal plan
#   uninstall --json --yes [--permanent] APP...      remove (Trash by default)
#
# Under --json, APP is an exact app bundle path or bundle id (not upstream's
# fuzzy name match); any unmatched or ambiguous APP selects nothing. The
# upstream scan filters (protected, system and nested apps), preview checks,
# official-uninstaller and sibling guards, and removal sinks all still run.
# Upstream's y/N and Enter confirmations are answered from stdin: `y` is fed
# only for --dry-run or an explicit --yes.

# Batch locals and uninstall globals are read through bash dynamic scoping.
# shellcheck disable=SC2154

_PRISTINE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pristine/common.sh
source "$_PRISTINE_LIB_DIR/common.sh"

declare -a PRISTINE_UNINSTALL_ARGS=()
PRISTINE_UNINSTALL_YES=false
PRISTINE_UNINSTALL_DRY_RUN=false

pristine_uninstall_main_hook() {
    local -a rest=()
    local arg
    for arg in "$@"; do
        if [[ "$arg" == "--yes" ]]; then
            PRISTINE_UNINSTALL_YES=true
        else
            rest+=("$arg")
        fi
    done
    pristine_parse_flags uninstall "--json --admin" ${rest[@]+"${rest[@]}"}
    PRISTINE_UNINSTALL_ARGS=(${PRISTINE_ARGS[@]+"${PRISTINE_ARGS[@]}"})
    pristine_extend_help show_uninstall_help "--json --admin"
    PRISTINE_HELP_FLAGS+=" --yes"

    [[ "$PRISTINE_JSON" == "true" ]] || return 0

    local list_mode=false app_count=0
    [[ "${MOLE_DRY_RUN:-0}" == "1" ]] && PRISTINE_UNINSTALL_DRY_RUN=true
    for arg in ${PRISTINE_UNINSTALL_ARGS[@]+"${PRISTINE_UNINSTALL_ARGS[@]}"}; do
        case "$arg" in
            --list) list_mode=true ;;
            --dry-run | -n) PRISTINE_UNINSTALL_DRY_RUN=true ;;
            -*) ;;
            *) app_count=$((app_count + 1)) ;;
        esac
    done
    if [[ "$list_mode" != "true" ]]; then
        if [[ $app_count -eq 0 ]]; then
            echo "uninstall --json needs --list or at least one app path / bundle id" >&2
            exit 1
        fi
        if [[ "$PRISTINE_UNINSTALL_DRY_RUN" != "true" && "$PRISTINE_UNINSTALL_YES" != "true" ]]; then
            echo "uninstall --json removes apps only with --yes (or preview with --dry-run)" >&2
            exit 1
        fi
    fi

    pristine_json_begin
    if [[ "$list_mode" != "true" ]]; then
        # --yes or --dry-run is the confirmation. Upstream's batch prompt
        # accepts only a terminal (EOF is not consent), so a hook line in
        # _batch_preview_and_confirm reads this instead. stdin stays
        # /dev/null: nothing waits on a keypress.
        PRISTINE_UNINSTALL_CONFIRMED=true
    fi
    pristine_install_admin_policy
    pristine_install_operation_events ""
    pristine_json_emit "{\"type\":\"start\",\"schema_version\":$PRISTINE_JSON_SCHEMA_VERSION,\"command\":\"uninstall\",\"mode\":\"$([[ "$list_mode" == "true" ]] && printf list || printf apps)\",\"dry_run\":$PRISTINE_UNINSTALL_DRY_RUN,\"permanent\":$(pristine_uninstall_permanent_json),\"apps_requested\":$app_count}"

    # shellcheck disable=SC2329  # Called by upstream code under its original name.
    uninstall_list_apps() {
        pristine_uninstall_list_json
    }

    # shellcheck disable=SC2329  # Called by upstream code under its original name.
    match_apps_by_name() {
        pristine_uninstall_match_exact "$@"
    }

    # shellcheck disable=SC2329  # Called by upstream code under its original name.
    pristine_wrap_function _batch_scan_app_details && _batch_scan_app_details() {
        local _pristine_rc=0
        _pristine_orig__batch_scan_app_details "$@" || _pristine_rc=$?
        [[ $_pristine_rc -eq 0 ]] && pristine_uninstall_emit_plan
        return "$_pristine_rc"
    }

    # shellcheck disable=SC2329  # Called by upstream code under its original name.
    pristine_wrap_function _mole_delete_log && _mole_delete_log() {
        local j_path
        pristine_json_quote "${4:-}"
        j_path="$PRISTINE_JQ"
        pristine_json_emit "{\"type\":\"delete\",\"mode\":$(pristine_json_str "${1:-}"),\"status\":$(pristine_json_str "${3:-}"),\"size_kb\":$(pristine_json_int "${2:-}"),\"path\":$j_path}"
        _pristine_orig__mole_delete_log "$@"
    }

    # shellcheck disable=SC2329  # Called by upstream code under its original name.
    pristine_wrap_function _batch_render_summary && _batch_render_summary() {
        _pristine_orig__batch_render_summary "$@"
        pristine_uninstall_emit_summary
    }
}

pristine_uninstall_permanent_json() {
    local arg
    for arg in ${PRISTINE_UNINSTALL_ARGS[@]+"${PRISTINE_UNINSTALL_ARGS[@]}"}; do
        [[ "$arg" == "--permanent" ]] && {
            printf true
            return
        }
    done
    [[ "${MOLE_DELETE_MODE:-trash}" == "permanent" ]] && printf true || printf false
}

pristine_uninstall_load_apps() {
    local apps_file=""
    apps_file=$(scan_applications) || return 1
    [[ -f "$apps_file" ]] || return 1
    local rc=0
    load_applications "$apps_file" || rc=$?
    rm -f "$apps_file" # SAFE: scan_applications temp listing
    return "$rc"
}

pristine_uninstall_list_json() {
    if ! pristine_uninstall_load_apps; then
        echo "Application scan failed" >&2
        return 1
    fi
    local row epoch app_path app_name bundle_id size last_used size_kb
    local j_path j_name j_bid j_last
    for row in ${apps_data[@]+"${apps_data[@]}"}; do
        IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb <<< "$row"
        pristine_json_quote "$app_path"
        j_path="$PRISTINE_JQ"
        pristine_json_quote "$app_name"
        j_name="$PRISTINE_JQ"
        pristine_json_quote "$bundle_id"
        j_bid="$PRISTINE_JQ"
        pristine_json_quote "$last_used"
        j_last="$PRISTINE_JQ"
        [[ "$size_kb" =~ ^[0-9]+$ && "$size_kb" -gt 0 ]] || size_kb=""
        pristine_json_emit "{\"type\":\"app\",\"path\":$j_path,\"name\":$j_name,\"bundle_id\":$j_bid,\"size_kb\":$(pristine_json_int "$size_kb"),\"last_used\":$j_last,\"last_used_epoch\":$(pristine_json_int "$epoch")}"
    done
    pristine_json_emit "{\"type\":\"summary\",\"mode\":\"list\",\"apps\":${#apps_data[@]}}"
    return 0
}

# Exact selection: each query must name one scanned app by bundle path or
# bundle id. Fail closed on any miss or ambiguity.
pristine_uninstall_match_exact() {
    selected_apps=()
    local -a picked=()
    local query row epoch app_path app_name bundle_id size last_used size_kb
    local hits hit_row failed=false
    for query in "$@"; do
        [[ ${#query} -gt 1 ]] && query="${query%/}"
        hits=0
        hit_row=""
        for row in ${apps_data[@]+"${apps_data[@]}"}; do
            IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb <<< "$row"
            if [[ "$app_path" == "$query" || (-n "$bundle_id" && "$bundle_id" == "$query") ]]; then
                hits=$((hits + 1))
                hit_row="$row"
            fi
        done
        if [[ $hits -eq 1 ]]; then
            picked+=("$hit_row")
        else
            failed=true
            pristine_json_emit "{\"type\":\"error\",\"code\":\"$([[ $hits -eq 0 ]] && printf unmatched || printf ambiguous)\",\"query\":$(pristine_json_str "$query"),\"matches\":$hits}"
        fi
    done
    [[ "$failed" == "true" ]] && return 0
    selected_apps=(${picked[@]+"${picked[@]}"})
}

# JSON array of the paths in a base64 newline-separated list.
pristine_uninstall_b64_paths_json() {
    local decoded="" line out=""
    if [[ -n "${1:-}" ]]; then
        decoded=$(printf '%s' "$1" | base64 -D 2> /dev/null) || decoded=""
    fi
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        pristine_json_quote "$line"
        [[ -n "$out" ]] && out+=","
        out+="$PRISTINE_JQ"
    done <<< "$decoded"
    printf '[%s]' "$out"
}

# Reads the batch locals app_details, blocked_apps and manual_removal_apps.
pristine_uninstall_emit_plan() {
    local detail name path bundle_id total_kb enc_files enc_system sensitive needs_sudo is_brew cask
    local enc_diag enc_review rest
    for detail in ${app_details[@]+"${app_details[@]}"}; do
        IFS='|' read -r name path bundle_id total_kb enc_files enc_system sensitive needs_sudo is_brew cask enc_diag enc_review rest <<< "$detail"
        local j_cask="null"
        [[ "$is_brew" == "true" && -n "$cask" ]] && j_cask=$(pristine_json_str "$cask")
        pristine_json_emit "{\"type\":\"plan\",\"name\":$(pristine_json_str "$name"),\"path\":$(pristine_json_str "$path"),\"bundle_id\":$(pristine_json_str "$bundle_id"),\"size_kb\":$(pristine_json_int "$total_kb"),\"needs_admin\":$(pristine_json_bool "$needs_sudo"),\"brew_cask\":$j_cask,\"sensitive_data\":$(pristine_json_bool "$sensitive"),\"files\":$(pristine_uninstall_b64_paths_json "$enc_files"),\"system_files\":$(pristine_uninstall_b64_paths_json "$enc_system"),\"review_only\":$(pristine_uninstall_b64_paths_json "$enc_review")}"
    done

    local blocked vendor
    for detail in ${blocked_apps[@]+"${blocked_apps[@]}"}; do
        IFS='|' read -r blocked vendor <<< "$detail"
        pristine_json_emit "{\"type\":\"blocked\",\"name\":$(pristine_json_str "$blocked"),\"reason\":\"official_uninstaller\",\"vendor\":$(pristine_json_str "$vendor")}"
    done
    for detail in ${manual_removal_apps[@]+"${manual_removal_apps[@]}"}; do
        pristine_json_emit "{\"type\":\"blocked\",\"name\":$(pristine_json_str "$detail"),\"reason\":\"manual_removal\",\"vendor\":null}"
    done
}

# Reads the batch locals success_count, failed_count, total_size_freed,
# failed_items and running_at_uninstall_apps.
pristine_uninstall_emit_summary() {
    local failures="" item
    for item in ${failed_items[@]+"${failed_items[@]}"}; do
        [[ -n "$failures" ]] && failures+=","
        failures+=$(pristine_json_str "$item")
    done
    local running=""
    for item in ${running_at_uninstall_apps[@]+"${running_at_uninstall_apps[@]}"}; do
        [[ -n "$running" ]] && running+=","
        running+=$(pristine_json_str "$item")
    done
    pristine_json_emit "{\"type\":\"summary\",\"mode\":\"apps\",\"dry_run\":$PRISTINE_UNINSTALL_DRY_RUN,\"removed\":$(pristine_json_int "${success_count:-0}"),\"failed\":$(pristine_json_int "${failed_count:-0}"),\"size_kb\":$(pristine_json_int "${total_size_freed:-0}"),\"failures\":[$failures],\"still_running\":[$running]}"
}
