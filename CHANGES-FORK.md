# cleaner-cli: changes from Mole

This repository is a **modified version** of [Mole](https://github.com/tw93/mole) by tw93,
licensed under GPL-3.0 (see [LICENSE](LICENSE)). It is a command-line engine meant to be bundled
inside a Mac app and driven as a separate program. It is not affiliated with or endorsed by Mole
or its author.

Upstream base: `tw93/mole` v1.56.0 (`50790e8a`, 2026-09-27).

## Modifications

| Date | Change |
|---|---|
| 2026-09-27 | `clean --json`, `--exclude-from FILE`, `--admin` (machine-readable clean for the GUI) |
| 2026-09-27 | `pristine` entrypoint; `scripts/pristine-dist.sh` bundle builder |
| 2026-09-28 | Rebrand per Mole's TRADEMARK.md: own README, Mole logo images removed, admin dialog title set by the `pristine` entrypoint (`PRISTINE_DIALOG_TITLE`) |
| 2026-09-28 | Fix: `request_sudo_access` now opens `/dev/tty` to detect a terminal. `-r`/`-w` pass without a controlling terminal, so app-spawned runs never got the password dialog (upstream bug; PR candidate) |
| 2026-09-28 | `--json` for `installer`, `purge`, `optimize`, `uninstall`; shared flag/event layer in `lib/pristine/common.sh`; the `pristine` entrypoint writes the final `end` event and forwards cancellation to the whole process tree |
| 2026-09-28 | Repository renamed to `yashspr/cleaner-cli`; bundle `BUILD-INFO` source URL updated; `pristine` entrypoint's default dialog title is now "cleaner-cli" |
| 2026-09-29 | Relocatable data directories: `PRISTINE_CONFIG_DIR`, `PRISTINE_CACHE_DIR`, `PRISTINE_LOG_DIR` replace `~/.config/mole`, `~/.cache/mole`, `~/Library/Logs/mole` (shell and Go); `PRISTINE_PROTECT_PATHS` keeps folders out of cleanup (`lib/pristine/paths.sh`) |

## Releases

Fork releases are annotated tags `pristine-vX.Y.Z` (upstream's `V1.x` tags stay untouched and
keep describing Mole). Apps bundle only tagged builds:
`scripts/pristine-dist.sh --release` refuses a dirty tree or an untagged commit, and each tag
must be pushed so its corresponding source is public (GPL-3.0 §6).

| Tag | Upstream base | Notes |
|---|---|---|
| `pristine-v0.1.0` | tw93/mole v1.56.0 (`50790e8a`) | `clean --json`, `--exclude-from`, `--admin`; `pristine` entrypoint; dist script |
| `pristine-v0.2.0` | tw93/mole v1.56.0 (`50790e8a`) | rebrand; admin-dialog fix; `--json` for installer / purge / optimize / uninstall; entrypoint `end` event + cancellation |
| `pristine-v0.2.1` | tw93/mole v1.56.0 (`50790e8a`) | repo renamed to `yashspr/cleaner-cli`: README, source URL in `BUILD-INFO`, neutral default dialog title |
| `pristine-v0.3.0` | tw93/mole v1.56.0 (`50790e8a`) | relocatable data directories (`PRISTINE_CONFIG_DIR`, `PRISTINE_CACHE_DIR`, `PRISTINE_LOG_DIR`) and `PRISTINE_PROTECT_PATHS` |

Cutting a release:

```bash
git tag -a pristine-vX.Y.Z -m "pristine-vX.Y.Z: <summary> (upstream vA.B.C)"
./scripts/pristine-dist.sh --release   # → dist/pristine-cli-vX.Y.Z.tar.gz
git push origin pristine-vX.Y.Z
```

Versioning: minor for new machine interfaces or upstream merges, patch for fixes, major if the
JSON `schema_version` changes.

## Keeping upstream merges cheap

Rule: **fork logic lives in fork-only files; shared files only get hook lines.**

- Fork-only files (upstream never touches them, so they never conflict):
  `lib/pristine/*`, `pristine`, `scripts/pristine-dist.sh`, `tests/pristine_*.bats`,
  `cmd/*/pristine_*.go`, `CHANGES-FORK.md`, `.gitattributes`.
- `README.md` is the fork's own. `.gitattributes` marks it `merge=ours`, so upstream README
  edits are dropped automatically. Each clone needs `git config merge.ours.driver true` once.
- `docs/img/*` (Mole logo/screenshots) were deleted. If upstream changes or adds images there,
  the merge stops with a modify/delete conflict: resolve it with `git rm docs/img/<file>`.
- Behaviour is added by **wrapping upstream functions at runtime**
  (`pristine_wrap_function` in `lib/pristine/json.sh`): the upstream function is renamed to
  `_pristine_orig_<name>` and a fork wrapper takes its name. Upstream can rewrite those function
  bodies freely; a merge only breaks if a wrapped function is **renamed or removed** (or, where
  noted, a local variable a wrapper reads is renamed), and the fork tests catch that.
- Every edited line in a shared file ends with `# pristine-fork` (`// pristine-fork` in Go), so
  `git grep -n 'pristine-fork'` is the complete list of hook points. Where a trailing comment
  would make shfmt re-align untouched upstream lines, a `# pristine-fork: ...` line sits above
  the edited block instead.

### Hook inventory

| Shared file | Lines | Purpose |
|---|---|---|
| `bin/clean.sh`, `bin/installer.sh`, `bin/purge.sh`, `bin/optimize.sh`, `bin/uninstall.sh` | 1 `source .../lib/pristine/<cmd>.sh` line each | load fork code |
| same five files | 2 lines at the top of `main()` each | strip fork flags, install wrappers |
| `lib/core/sudo.sh` | 2 lines at the `/dev/tty` check in `request_sudo_access` | real open test, so app-spawned runs reach the native dialog |
| `lib/core/sudo.sh` | 3 lines at the `osascript` dialog | title from `PRISTINE_DIALOG_TITLE` (sanitized; default "Mole", `pristine` sets "cleaner-cli") |
| `lib/core/base.sh` | 1 `source .../lib/pristine/paths.sh` line | load the data-dir overrides for every command |
| `lib/core/app_protection.sh` | 1 line in `should_protect_path` | data dirs and `PRISTINE_PROTECT_PATHS` are never cleaned |
| `mole`, `bin/*.sh`, `lib/*/*.sh`, `cmd/analyze/cache.go`, `cmd/status/prefs.go` | each hard-coded `~/.config/mole`, `~/.cache/mole`, `~/Library/Logs/mole` | `${PRISTINE_<KIND>_DIR:-<upstream path>}`; `tests/pristine_data_dirs.bats` fails if a merge adds an unrouted one |
| `.gitignore` | `/dist/` | ignore bundle output |

`bin/uninstall.sh` sources its fork file relative to `BASH_SOURCE`, not `SCRIPT_DIR`: the
upstream libraries it loads first reassign `SCRIPT_DIR`.

### Upstream names the fork depends on

| Command | Wrapped functions | Also reads |
|---|---|---|
| all | `log_operation`, `ensure_sudo_session` (only under `--json` without `--admin`), `show_*_help` | `WHITELIST_PATTERNS`, `adopt_sudo_session` |
| clean | `start_cleanup`, `perform_cleanup`, `start_section` | `emit_deduplicated_dry_run_ledger`, `CLEAN_PREVIEW_LEDGER_FILE`, `CURRENT_SECTION`, `DRY_RUN`, `SYSTEM_CLEAN`, `total_size_cleaned`, `files_cleaned`, `total_items`, `DRY_RUN_TOTAL_PARTIAL`, `MOLE_CLEAN_SIZING_TIMEOUTS` |
| installer | `perform_installers`, `show_installer_menu` (replaced), `record_installer_delete_failure` | `INSTALLER_PATHS`, `INSTALLER_SIZES`, `INSTALLER_SOURCES`, `MOLE_SELECTION_RESULT`, `total_deleted`, `total_size_freed_kb`, `total_delete_failed`, `INSTALLER_EXIT_*`; relies on the confirmation treating EOF as Enter |
| purge | `start_purge`, `perform_purge`, `mole_purge_is_cloud_synced_path`, `log_operation_session_end`, `is_path_whitelisted` (`--only-from`) | per-item locals of `clean_project_artifacts`: `item`, `size_kb`, `size_unknown`, `is_recent`, `activity_state`, `project_root`, `artifact_type`; `PURGE_SEARCH_PATHS`, `PURGE_RUN_OUTCOME`, `PURGE_UNKNOWN_SIZE_COUNT` |
| optimize | `execute_optimization`, `optimize_outcomes_reset`, `show_system_health`, `show_optimization_summary` | `MOLE_OPTIMIZE_ACTIONS`, `MOLE_OPTIMIZE_HEALTH_NAMES`, `MOLE_OPTIMIZE_RESULT_*`, `MOLE_OPTIMIZE_OUTCOME_*`, `MOLE_OPTIMIZE_SUDO_AVAILABLE`, `OPTIMIZE_*` stats |
| uninstall | `uninstall_list_apps` and `match_apps_by_name` (replaced), `_batch_scan_app_details`, `_batch_render_summary`, `_mole_delete_log` | `apps_data`, `selected_apps`, `scan_applications`, `load_applications`; batch locals `app_details` (field order), `blocked_apps`, `manual_removal_apps`, `success_count`, `failed_count`, `total_size_freed`, `failed_items`, `running_at_uninstall_apps`; relies on the batch confirmation treating EOF as Enter |

### Branches

- `pristine/main` is the fork's mainline and the default branch: every fork change, and the
  `pristine-v*` release tags. Topic branches (`pristine/<topic>`) start from it and merge back.
- `main` mirrors upstream `main` exactly and gets no commits of its own, so GitHub's "Sync
  fork" always fast-forwards it. `git diff main pristine/main` is everything the fork changes.

### Merging upstream

```bash
git config merge.ours.driver true   # once per clone (keeps our README.md)
# Sync `main` first: GitHub's "Sync fork", or
#   git fetch upstream && git switch main && git merge --ff-only upstream/main && git push
git switch pristine/main
git merge main                   # merge, not rebase: keeps fork history and tags intact
                                 # docs/img conflict? → git rm docs/img/<file>
git grep -n 'pristine-fork'      # hook lines still in place?
MOLE_TEST_NO_AUTH=1 bats tests/pristine_*.bats   # pristine_data_dirs.bats lists new state paths to route
./scripts/check.sh --no-format
```

Then update "Upstream base" above.

## Machine interface

Always run through the **`pristine`** entrypoint. It is the same CLI as `mo`/`mole`, plus:

- For `clean`, `installer`, `purge`, `optimize` and `uninstall` with `--json`, it runs the
  command as a child and writes `{"type":"end","exit_code":N}` as the **last line** once the
  command has exited, whatever happened (success, error, cancel).
- **Cancel** by sending SIGTERM (or SIGINT) to the `pristine` process. It signals the command's
  whole process tree, deepest first, as a terminal Ctrl-C would. Expect `end` with exit code
  143; a `summary` may be missing on cancel.
- Treat the `end` event or process exit as completion, not stdout EOF: background helpers (sudo
  keepalive, brew autoremove) can hold the pipe open.
- `PRISTINE_DIALOG_TITLE` sets the title of the native admin-password dialog (default "cleaner-cli"; a GUI should set its own name).
- Data directories (all commands, shell and Go). Unset, upstream's folders are used. Each value
  must be an absolute path; anything else is ignored with a warning on stderr.

  | Variable | Replaces | Holds |
  |---|---|---|
  | `PRISTINE_CONFIG_DIR` | `~/.config/mole` | `whitelist`, `whitelist_optimize`, `purge_paths`, `clean-list.txt`, `status_prefs` |
  | `PRISTINE_CACHE_DIR` | `~/.cache/mole` | scan, app and analyze caches; fallback temp dir when `TMPDIR` is unusable |
  | `PRISTINE_LOG_DIR` | `~/Library/Logs/mole` | `mole.log`, `operations.log` and `deletions.log` (what `history` reads) |

  Cleanup never removes these directories or anything in them. `PRISTINE_PROTECT_PATHS`
  (colon-separated absolute paths) protects more folders the same way; list the parent too when
  a data dir sits in a folder cleanup sweeps (`~/Library/Caches/<app>/…`, `~/Library/Logs/<app>/…`).
  Mole's own install management (`update`, `remove`) still uses the upstream folders.
- `status --json`, `analyze --json`, `history --json` are upstream's own formats and get no `end`.

### Common flags

| Flag | Meaning |
|---|---|
| `--json` | stdout carries **only** NDJSON events (one object per line); human output moves to stderr. stdin is detached, so a run never waits for a keypress. |
| `--admin` | Allow an admin prompt (native macOS dialog when there is no terminal). **Without it a `--json` run never prompts**: it only adopts an already-cached sudo session. |
| `--exclude-from FILE` | Never touch the listed paths. |
| `--only-from FILE` | Touch only the listed paths. |

Path-list files: newline-separated absolute paths, `~/` allowed, `#` comments, trailing `/`
ignored. An unreadable file or an invalid line aborts with exit 1 before anything is scanned.
`--exclude-from` and `--only-from` cannot be combined.

### Per command

| Command | Flags | Selection model |
|---|---|---|
| `clean [--dry-run]` | `--json --admin --exclude-from` | Everything Mole would clean, minus excluded paths (joined to the whitelist in memory, so excluding a child also keeps its parents). The real run rescans. |
| `installer [--dry-run]` | `--json --exclude-from --only-from` (lists need `--json`) | The menu is replaced: all candidates minus excluded, or only listed ones. Upstream's identity + size re-check runs before each delete. Deletes are permanent unless `MOLE_DELETE_MODE=trash`. |
| `purge (--dry-run \| --yes) [--include-empty]` | `--json --exclude-from --only-from` | Upstream's unattended rule stays: artifacts modified within 7 days (or with uncertain activity) and cloud-synced ones are **never** removed unattended, even if listed. Every protection/identity/activity check still runs. |
| `optimize [--dry-run]` | `--json --admin --skip-from FILE` | All tasks, minus task ids listed in `--skip-from` (recorded as `skipped`). Task ids are in the `start` event. |
| `uninstall --list` / `uninstall (--dry-run \| --yes) [--permanent] APP…` | `--json --admin --yes` | Under `--json`, `APP` is an exact bundle path or bundle id; any unmatched/ambiguous `APP` selects nothing (`error` event, exit 1). Removal needs `--yes`. Default is Trash. |

Recommended flow: preview with `--dry-run --json`, let the user deselect, then run for real
passing the deselection (`--exclude-from`, `--only-from`, `--skip-from`, or the chosen apps).

### Events (`schema_version` 1)

Every stream starts with `start` (`schema_version`, `command`, …) and ends with `end`.

| Command | `type` | Fields |
|---|---|---|
| all | `end` | `exit_code` |
| clean, installer, purge, optimize, uninstall | `operation` | `action` (`REMOVED` / `TRASHED` / `SKIPPED` / `FAILED` / `TASK_FAILED` / …), `path`, `detail` (human size or reason), `section` (clean, optimize) |
| clean | `start` | `dry_run`, `system_clean`, `external_volume`, `excluded_paths` |
| clean | `section` | `name` |
| clean | `item` | dry run: `path`, `section`, `size_kb` (int/null), `size_known`, `item_count`, `covered_by` (string/null) |
| clean | `summary` | `dry_run`, `status` (`complete` / `cancelled` / `interrupted` / `incomplete`), `exit_code`, `size_kb`, `size_partial`, `items`, `categories`, `system_clean`, `permission_denied`, `removal_timeouts`, `free_space_kb`, `preview_file` |
| installer | `start` | `dry_run`, `excluded_paths`, `only_paths` |
| installer | `item` | `path`, `kind` (`dmg` / `pkg` / `mpkg` / `iso` / `xip` / `zip`), `source`, `size_bytes`, `size_kb`, `selected` |
| installer | `failure` | `path`, `reason` (`missing` / `changed since scan` / `delete failed` / …) |
| installer | `summary` | `dry_run`, `status` (`complete` / `nothing_selected` / `nothing_found` / `incomplete` / `scan_failed` / `cancelled` / `interrupted`), `exit_code`, `candidates`, `selected`, `removed`, `size_kb`, `failed`, `scan_failure_path` |
| purge | `start` | `dry_run`, `search_paths`, `excluded_paths`, `only_paths` |
| purge | `item` | `path`, `project`, `artifact`, `size_kb` (int/null), `activity` (`old` / `recent` / `uncertain`), `age_days`, `cloud`, `selectable` (false = never removed unattended) |
| purge | `summary` | `dry_run`, `status` (upstream `PURGE_RUN_OUTCOME`: `completed` / `incomplete` / `no_candidates` / `cancelled` / `scan_failed`), `exit_code`, `candidates`, `items`, `size_kb`, `unmeasured` |
| optimize | `health` | `data`: upstream health JSON (memory, disk, uptime, suggestions) |
| optimize | `start` | `dry_run`, `admin`, `tasks` (`[{id, label, skip}]`) |
| optimize | `task` | `id`, `label`, `status` (`applied` / `unchanged` / `skipped` / `unavailable` / `attention` / `failed`), `detail` (task messages, `; `-joined) |
| optimize | `summary` | `dry_run`, `outcomes` (count per status), `cache_cleaned_kb`, `databases_optimized`, `configs_repaired` |
| uninstall | `start` | `mode` (`list` / `apps`), `dry_run`, `permanent`, `apps_requested` |
| uninstall | `app` | list: `path`, `name`, `bundle_id`, `size_kb` (null when not yet measured), `last_used`, `last_used_epoch` |
| uninstall | `error` | `code` (`unmatched` / `ambiguous`), `query`, `matches` (number of apps that matched) |
| uninstall | `plan` | `name`, `path`, `bundle_id`, `size_kb`, `needs_admin`, `brew_cask`, `sensitive_data`, `files`, `system_files`, `review_only` |
| uninstall | `blocked` | `name`, `reason` (`official_uninstaller` / `manual_removal`), `vendor` |
| uninstall | `delete` | per removal sink call: `mode` (`trash` / `permanent`), `status` (`ok` / `dry-run` / `rejected` / `identity-changed` / `trash-failed` / …; only `ok` means removed), `size_kb`, `path` |
| uninstall | `summary` | `mode`; apps: `dry_run`, `removed`, `failed`, `size_kb`, `failures`, `still_running`; list: `apps` |

Notes:
- clean `item` rows with `covered_by` sit inside another listed row. Show them (they can be
  excluded on their own), but don't add their size to a total.
- Sizes are KiB unless named `_bytes`. Mole's human output uses decimal units (1 GB = 10⁹ bytes).
- clean `--external` dry runs emit no `item` rows yet (upstream writes that preview as text only).
- uninstall exits 0 even when every app failed: read `summary.failed`.
- `optimize`'s `login_items_audit` task scripts System Events and can raise a macOS Automation
  permission prompt; skip it with `--skip-from` if that is unwanted.
- New fields may be added within a schema version; consumers must ignore unknown fields and
  unknown `type`s. A breaking change bumps `schema_version`.
