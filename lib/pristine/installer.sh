#!/bin/bash
# Pristine fork: machine-readable `installer`.
# Fork-only file; bin/installer.sh sources it and calls
# pristine_installer_main_hook at the top of main(). See CHANGES-FORK.md.
#
#   installer --json --dry-run                     list candidates (+ would-free totals)
#   installer --json [--exclude-from F | --only-from F]   remove without the menu
#
# Selection replaces the interactive menu (show_installer_menu): every
# candidate is selected unless excluded, or only the listed ones. Removal then
# runs upstream's plan/confirm/execute path unchanged, including the
# identity and size re-check before each delete. Under --json, stdin holds a
# single newline: the Enter that upstream's final confirmation needs (EOF
# there is cancel).

_PRISTINE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pristine/common.sh
source "$_PRISTINE_LIB_DIR/common.sh"

declare -a PRISTINE_INSTALLER_ARGS=()
PRISTINE_INSTALLER_SELECTED=0

pristine_installer_main_hook() {
    local flags="--json --exclude-from --only-from"
    pristine_parse_flags installer "$flags" "$@"
    PRISTINE_INSTALLER_ARGS=(${PRISTINE_ARGS[@]+"${PRISTINE_ARGS[@]}"})
    pristine_extend_help show_installer_help "$flags"

    if [[ "$PRISTINE_JSON" != "true" && (-n "$PRISTINE_EXCLUDE_FILE" || -n "$PRISTINE_ONLY_FILE") ]]; then
        echo "--exclude-from / --only-from need --json for installer" >&2
        exit 1
    fi
    [[ "$PRISTINE_JSON" == "true" ]] || return 0

    pristine_json_begin
    exec 0<<< "" # Enter for the final confirmation; read after that gets EOF
    pristine_install_operation_events ""

    # shellcheck disable=SC2329  # Called by upstream code under its original name.
    pristine_wrap_function perform_installers && perform_installers() {
        pristine_json_emit "{\"type\":\"start\",\"schema_version\":$PRISTINE_JSON_SCHEMA_VERSION,\"command\":\"installer\",\"dry_run\":$(pristine_mole_dry_run_json),\"excluded_paths\":${#PRISTINE_EXCLUDE_PATHS[@]},\"only_paths\":${#PRISTINE_ONLY_PATHS[@]}}"
        local rc=0
        _pristine_orig_perform_installers "$@" || rc=$?
        pristine_installer_emit_summary "$rc"
        return "$rc"
    }

    # Never call the original: its menu takes over the terminal and clears
    # the EXIT trap.
    # shellcheck disable=SC2329  # Called by upstream code under its original name.
    show_installer_menu() {
        pristine_installer_select
    }

    # shellcheck disable=SC2329  # Called by upstream code under its original name.
    pristine_wrap_function record_installer_delete_failure && record_installer_delete_failure() {
        local path reason
        pristine_json_quote "${1:-}"
        path="$PRISTINE_JQ"
        pristine_json_quote "${2:-}"
        reason="$PRISTINE_JQ"
        pristine_json_emit "{\"type\":\"failure\",\"path\":$path,\"reason\":$reason}"
        _pristine_orig_record_installer_delete_failure "$@"
    }
}

# Emit one item per candidate and set MOLE_SELECTION_RESULT. Returns 1 (the
# upstream "nothing selected" status) when the selection is empty.
pristine_installer_select() {
    local -a picked=()
    local i path selected ext j_path j_source j_type
    PRISTINE_INSTALLER_SELECTED=0

    for ((i = 0; i < ${#INSTALLER_PATHS[@]}; i++)); do
        path="${INSTALLER_PATHS[$i]}"
        selected=true
        if [[ ${#PRISTINE_ONLY_PATHS[@]} -gt 0 || -n "$PRISTINE_ONLY_FILE" ]]; then
            pristine_path_listed "$path" ${PRISTINE_ONLY_PATHS[@]+"${PRISTINE_ONLY_PATHS[@]}"} || selected=false
        elif [[ ${#PRISTINE_EXCLUDE_PATHS[@]} -gt 0 ]]; then
            pristine_path_listed "$path" "${PRISTINE_EXCLUDE_PATHS[@]}" && selected=false
        fi
        [[ "$selected" == "true" ]] && picked+=("$i")

        ext="${path##*.}"
        ext=$(printf '%s' "$ext" | LC_ALL=C tr '[:upper:]' '[:lower:]')
        pristine_json_quote "$path"
        j_path="$PRISTINE_JQ"
        pristine_json_quote "${INSTALLER_SOURCES[$i]:-}"
        j_source="$PRISTINE_JQ"
        pristine_json_quote "$ext"
        j_type="$PRISTINE_JQ"
        pristine_json_emit "{\"type\":\"item\",\"path\":$j_path,\"kind\":$j_type,\"source\":$j_source,\"size_bytes\":$(pristine_json_int "${INSTALLER_SIZES[$i]:-}"),\"size_kb\":$(pristine_json_size_kb_from_bytes "${INSTALLER_SIZES[$i]:-}"),\"selected\":$selected}"
    done

    PRISTINE_INSTALLER_SELECTED=${#picked[@]}
    if [[ ${#picked[@]} -eq 0 ]]; then
        MOLE_SELECTION_RESULT=""
        return 1
    fi
    local IFS=,
    MOLE_SELECTION_RESULT="${picked[*]}"
    return 0
}

pristine_installer_emit_summary() {
    local rc="$1" status
    case "$rc" in
        0) status="complete" ;;
        1) status="nothing_selected" ;;
        2) status="nothing_found" ;;
        "$INSTALLER_EXIT_INCOMPLETE") status="incomplete" ;;
        "$INSTALLER_EXIT_SCAN_FAILED") status="scan_failed" ;;
        *)
            if mole_rc_timeout "$rc"; then
                status="cancelled"
            else
                status="interrupted"
            fi
            ;;
    esac
    local scan_failure="null"
    if [[ -n "${INSTALLER_SCAN_FAILURE_PATH:-}" ]]; then
        scan_failure=$(pristine_json_str "$INSTALLER_SCAN_FAILURE_PATH")
    fi
    pristine_json_emit "{\"type\":\"summary\",\"dry_run\":$(pristine_mole_dry_run_json),\"status\":\"$status\",\"exit_code\":$(pristine_json_int "$rc"),\"candidates\":${#INSTALLER_PATHS[@]},\"selected\":$PRISTINE_INSTALLER_SELECTED,\"removed\":$(pristine_json_int "${total_deleted:-0}"),\"size_kb\":$(pristine_json_int "${total_size_freed_kb:-0}"),\"failed\":$(pristine_json_int "${total_delete_failed:-0}"),\"scan_failure_path\":$scan_failure}"
}
