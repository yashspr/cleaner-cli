#!/bin/bash
# Pristine fork: relocatable data directories.
# Fork-only file; see CHANGES-FORK.md.
#
# Upstream keeps its state in ~/.config/mole, ~/.cache/mole and
# ~/Library/Logs/mole. A program that embeds this CLI can move each one, so
# nothing is written to (or read from) those folders:
#   PRISTINE_CONFIG_DIR     whitelists, purge_paths, clean-list.txt, status prefs
#   PRISTINE_CACHE_DIR      scan and analyze caches, fallback temp directory
#   PRISTINE_LOG_DIR        mole.log, operations.log, deletions.log (history)
#   PRISTINE_PROTECT_PATHS  colon-separated folders cleanup must never touch
# Each path must be absolute; an invalid value is ignored with a warning and
# the upstream default applies. Unset, behaviour is exactly upstream's.
#
# The three data directories and the protected folders, with everything in
# them, are never removed by cleanup (upstream protects ~/Library/Logs/mole the
# same way). A data directory inside a folder that cleanup sweeps, such as
# ~/Library/Logs/<app>/engine, needs its parent listed in
# PRISTINE_PROTECT_PATHS as well.
#
# Also here, since every command loads this file: pristine_shared_vendor_name,
# which keeps uninstall from claiming a company's shared folders.

if [[ -n "${PRISTINE_PATHS_LOADED:-}" ]]; then
    return 0
fi
readonly PRISTINE_PATHS_LOADED=1

_pristine_valid_dir() {
    local value="$1"
    [[ "$value" == /* && "$value" != "/" && ! "$value" =~ [[:cntrl:]] ]] || return 1
    case "$value" in
        *'/../'* | */.. | *'/./'* | */.) return 1 ;;
    esac
    return 0
}

PRISTINE_PROTECTED_ROOTS=()

_pristine_init_paths() {
    local name value
    for name in PRISTINE_CONFIG_DIR PRISTINE_CACHE_DIR PRISTINE_LOG_DIR; do
        value="${!name:-}"
        [[ -n "$value" ]] || continue
        if _pristine_valid_dir "$value"; then
            [[ "$value" == */ ]] && export "$name=${value%/}"
            PRISTINE_PROTECTED_ROOTS+=("${value%/}")
        else
            echo "Ignoring $name: not an absolute path" >&2
            unset "$name"
        fi
    done

    [[ -n "${PRISTINE_PROTECT_PATHS:-}" ]] || return 0
    local -a extra=()
    IFS=: read -r -a extra <<< "$PRISTINE_PROTECT_PATHS"
    for value in ${extra[@]+"${extra[@]}"}; do
        [[ -n "$value" ]] || continue
        if _pristine_valid_dir "$value"; then
            PRISTINE_PROTECTED_ROOTS+=("${value%/}")
        else
            echo "Ignoring protected path: $value" >&2
        fi
    done
}
_pristine_init_paths

# pristine_path_protected PATH → 0 when PATH is a data directory or protected
# folder, or inside one. Called from should_protect_path.
#
# Case is ignored: macOS volumes are case-insensitive by default, and some
# targets are built from an app's name rather than read from the disk, so
# ".../Application Support/Obsidian" can name the folder a user protected as
# ".../obsidian". On a case-sensitive volume this keeps a little more, which
# is the safe side.
pristine_path_protected() {
    local path="${1%/}" root found=1 restore_case=0
    [[ -n "$path" && ${#PRISTINE_PROTECTED_ROOTS[@]} -gt 0 ]] || return 1
    if ! shopt -q nocasematch; then
        shopt -s nocasematch
        restore_case=1
    fi
    for root in "${PRISTINE_PROTECTED_ROOTS[@]}"; do
        if [[ "$path" == "$root" || "$path" == "$root"/* ]]; then
            found=0
            break
        fi
    done
    if [[ $restore_case -eq 1 ]]; then
        shopt -u nocasematch
    fi
    return "$found"
}

# pristine_shared_vendor_name NAME → 0 when NAME is a company's folder name
# that several of its apps share (~/Library/Caches/Microsoft holds Office's,
# Teams' and AutoUpdate's caches). Uninstall shortens a channel build's name
# ("Zed Nightly" → "Zed") and claims folders by the short name; one that comes
# out as a company name must not, or every app of that company loses its data.
# Called from find_app_files.
PRISTINE_SHARED_VENDOR_NAMES="adobe amazon apple autodesk corel google jetbrains logitech meta microsoft mozilla oracle parallels vmware"
pristine_shared_vendor_name() {
    local name
    mole_ascii_lowercase name "$1"
    [[ " $PRISTINE_SHARED_VENDOR_NAMES " == *" $name "* ]]
}

# pristine_tool_row ROOT LABEL [SIZE_KB|unknown] → in a JSON preview, list a
# tool's own cleanup (npm cache clean, brew cleanup, docker prune…) as a row,
# keyed by ROOT: the folder that step checks against the whitelist before it
# runs. Upstream shows these steps as a "would clean" line only, so a user
# could neither see them nor turn them off. Excluding ROOT (unticking the row)
# makes the real run skip the step, through that same whitelist check.
#
# The row's path is a key for that check, never a deletion target. SIZE_KB
# defaults to the size of ROOT (measured under HOME only); a step that prunes
# only part of ROOT, or whose bytes other rows already list, passes "unknown".
# Called from the dry-run branch of each such step; a no-op outside
# `pristine clean --json --dry-run`. Always returns 0.
pristine_tool_row() {
    local root="${1%/}" label="${2:-}" size="${3:-}" size_known=true
    [[ "${PRISTINE_JSON:-}" == "true" && "${DRY_RUN:-false}" == "true" && "$root" == /* ]] || return 0
    declare -F record_dry_run_cleanup_target > /dev/null 2>&1 || return 0
    # A kept root is no row, as for every other kept path (the step's own
    # check already skipped it; this covers brew cleanup's Cellar key).
    is_path_whitelisted "$root" && return 0
    if [[ -z "$size" ]]; then
        case "$label" in
            # A prune keeps what's still used; npm's rows under ~/.npm already list its cache.
            "npm cache" | "pnpm cache" | "uv cache" | conda* | "Nix store garbage") size=unknown ;;
        esac
    fi
    if [[ "$size" == "unknown" ]]; then
        size=0
        size_known=false
    elif [[ ! "$size" =~ ^[0-9]+$ ]]; then
        if ! declare -F _owner_cache_size_kb > /dev/null 2>&1 || ! size=$(_owner_cache_size_kb "$root" 2> /dev/null); then
            size=0
            size_known=false
        fi
    fi
    _MOLE_DRY_RUN_TARGET_PREVALIDATED=true record_dry_run_cleanup_target "$root" "$size" 1 "$size_known" > /dev/null 2>&1 || true
    return 0
}

# Homebrew's Cellar: the key for `brew cleanup`'s row. Upstream checks
# ~/Library/Caches/Homebrew before that step, but the cache is a row of its own
# (its downloads); the Cellar is where the old versions brew cleanup removes are.
pristine_homebrew_cellar() {
    local brew_bin
    brew_bin=$(command -v brew 2> /dev/null) || return 1
    [[ "$brew_bin" == /*/bin/brew ]] || return 1
    printf '%s/Cellar\n' "${brew_bin%/bin/brew}"
}

# The row for `brew cleanup`, from its own dry run: what it would free outside
# the Homebrew cache (old versions, Homebrew's own old Ruby). A dry run that
# failed or timed out still lists the row, without a size, since the real run
# still runs the step. Nothing to remove: no row.
pristine_homebrew_row() {
    local preview_rc="$1" preview_file="$2" cellar size
    cellar=$(pristine_homebrew_cellar) || return 0
    if [[ "$preview_rc" -ne 0 ]]; then
        pristine_tool_row "$cellar" "Homebrew cleanup" unknown
        return 0
    fi
    grep -q '^Would remove: ' "$preview_file" 2> /dev/null || return 0
    size=$(awk -v cache="$HOME/Library/Caches/Homebrew/" '
        index($0, "Would remove: ") == 1 {
            p = substr($0, 15)
            if (index(p, cache) == 1) next
            if (!match(p, /\([^()]*\)$/)) next
            n = split(substr(p, RSTART + 1, RLENGTH - 2), parts, ", ")
            s = parts[n]
            if (!match(s, /^[0-9.]+/)) next
            v = substr(s, 1, RLENGTH) + 0
            u = substr(s, RLENGTH + 1)
            if (u == "B") v /= 1024
            else if (u == "MB") v *= 1024
            else if (u == "GB") v *= 1048576
            else if (u == "TB") v *= 1073741824
            else if (u != "KB") next
            kb += v
        }
        END { printf "%d\n", kb }' "$preview_file" 2> /dev/null) || size=unknown
    pristine_tool_row "$cellar" "Homebrew cleanup" "$size"
    return 0
}

# Real run: the Homebrew cleanup row was unticked (its Cellar is excluded, or a
# whitelisted version sits in it), so `brew cleanup` doesn't run.
pristine_homebrew_kept() {
    local cellar
    cellar=$(pristine_homebrew_cellar) || return 1
    is_path_whitelisted "$cellar" || return 1
    log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$cellar" "whitelist"
    return 0
}
