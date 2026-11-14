# Issue 004 — Make `deploy-stg-to-prod.sh` and `sync-prod-to-stg.sh` project-agnostic via `.env`

**Status**: Open — targeted for v.1.2.0
**Affects**: [`deploy-stg-to-prod.sh`](../../deploy-stg-to-prod.sh) — `load_env()`, `load_config()`, `rename_prefix()`, `set_header_script()`, `activate_security_plugin()`, `verify()`; [`sync-prod-to-stg.sh`](../../sync-prod-to-stg.sh) — `load_env()`, `load_config()`, `rename_prefix()`, `set_staging_prefix()`, `deactivate_security_plugins()`, `verify()`; [`lib/deploy_config.sh`](../../lib/deploy_config.sh) — **does not exist yet**
**Severity**: Medium — feature request, but both scripts currently fail at startup (see Reproduction)
**Discovered**: 2026-11-13
**Reporter**: project owner (yadepan.com)

---

## TL;DR

`deploy-stg-to-prod.sh` (staging → production) and `sync-prod-to-stg.sh` (production → staging) were written for the **yadepan** project. They are meant to read all site-specific values from a `.env` file ([`.env.example`](../../.env.example) already exists), but the implementation is incomplete:

1. Both scripts source `lib/deploy_config.sh`, which is not in the repo.
2. Both scripts call helpers that are defined nowhere: `deploy_env_get`, `load_deploy_env`, `require_deploy_keys`, `config_define`, `config_prefix`, `set_config_prefix`, `url_variants`, `url_host`.
3. Some values remain hard-coded (WordPress file exclusions, `blog_public` values, the `wp_` default prefix assumption in the plugin/option rewrites).

The task has two parts:

- **Make the config file the only source of site-specific values.** `PROD_URL`, `STG_URL` and the **target table prefix** (`PROD_TABLE_PREFIX` for deploy, `STG_TABLE_PREFIX` for sync) must be configurable.
- **Ship the missing shared loader** `lib/deploy_config.sh` so the scripts run at all.

Also update [`README.md`](../../README.md) and [`RELEASE.md`](../../RELEASE.md) for **v.1.2.0**.

Nothing in this issue changes the *behaviour* of a deploy or sync. The safety rails (`--dry-run`, `--yes`, pre-run backups, rollback paths printed at the end, `set -euo pipefail`) must survive unchanged.

---

## Reproduction

```bash
cd ~/projects/wp-server-scripts
cp .env.example .env          # fill in any real values
./deploy-stg-to-prod.sh stg prod --dry-run
# bash: .../lib/deploy_config.sh: No such file or directory
```

Even with the sourcing fixed, the first call to `deploy_env_get` fails with `command not found`, and `load_config()` fails at `config_define`.

### Values that must come from `.env`

| Script variable today | `.env` key | Notes |
|---|---|---|
| `PROD_URL` / `STG_URL` | `PROD_URL` / `STG_URL` | Required. Include scheme. |
| `BASE_DIR`, `PROD_PATH`, `STG_PATH` | same | Host paths |
| `BACKUP_DIR` | same | Rollback dumps and tarballs |
| `DB_CONTAINER`, `APP_CONTAINER` | same | Container names |
| `PROD_WP_PATH`, `STG_WP_PATH` | same | Docroots inside `APP_CONTAINER` |
| Target prefix (deploy) | `PROD_TABLE_PREFIX` | Optional; unset = keep prod's current prefix |
| Target prefix (sync) | `STG_TABLE_PREFIX` | Optional; unset = adopt prod's prefix |
| `HEADER_SCRIPT`, `HEADER_THEME_MOD` | same | Optional |
| `SECURITY_PLUGINS` (sync) | same | Optional, comma-separated slugs |
| `PROD_SECURITY_PLUGIN` (deploy) | same | Optional |
| `PROD_WP_OWNER` | same | Default `nobody:nogroup` |

### Hard-coded values still in the scripts

- `rsync --exclude 'wordfence-waf.php' --exclude 'aios-bootstrap.php'` in both scripts. These are plugin-specific and should be derived from `SECURITY_PLUGINS` / `PROD_SECURITY_PLUGIN`, or exposed as `SYNC_EXCLUDES`.
- `option update blog_public 1` (deploy) and `0` (sync). Keep as the script's intent, but name the constants at the top.
- `option_name LIKE '%user_roles'` in the meta-key rewrite. This is correct for WordPress core; leave as-is and document it.

---

## Root Cause

The `.env` migration was committed in `691b126` with the scripts calling a loader that was never written. The `.env` format described in `.env.example` (`KEY=VALUE`, optional quotes, `#` comments) has no parser behind it. The `wp-config.php` readers and writers (`config_define`, `config_prefix`, `set_config_prefix`) are also missing, so `load_config()` cannot resolve the source or target prefix.

---

## Configuration Contract

### Required keys

`PROD_URL`, `STG_URL`, `BASE_DIR`, `PROD_PATH`, `STG_PATH`, `BACKUP_DIR`, `DB_CONTAINER`, `APP_CONTAINER`, `PROD_WP_PATH`, `STG_WP_PATH`. A missing key aborts with `ERROR: <KEY> is not set in <file>`.

### Optional keys

`PROD_TABLE_PREFIX`, `STG_TABLE_PREFIX`, `HEADER_SCRIPT`, `HEADER_THEME_MOD` (default `header_scripts`), `SECURITY_PLUGINS`, `PROD_SECURITY_PLUGIN`, `PROD_WP_OWNER` (default `nobody:nogroup`).

### `.env` parsing rules

- One `KEY=VALUE` per line. Leading whitespace and an optional `export ` prefix are allowed.
- Lines starting with `#` and blank lines are ignored.
- Trim surrounding whitespace. Strip one layer of matching `'` or `"` quotes. Everything after the first `=` is the value.
- An inline `#` is **not** a comment unless it is preceded by whitespace. Values containing `#` must be quoted.
- The file is **parsed, never sourced**. No command substitution or variable expansion is performed.
- Unknown keys are ignored with a warning.
- A key with no `=` or an invalid key name (not `[A-Za-z_][A-Za-z0-9_]*`) is a fatal error.

### Shared loader

`lib/deploy_config.sh` provides:

| Function | Contract |
|---|---|
| `load_deploy_env <file>` | Parse the file into `DEPLOY_ENV_<KEY>` variables. Die if missing or unreadable. |
| `deploy_env_get <KEY> [default]` | Print the value, or the default if unset/empty. Returns 0 in both cases. |
| `require_deploy_keys <file> KEY...` | Die listing every missing key, not just the first. |
| `config_define <wp-config.php> <NAME>` | Print the literal value of `define('NAME', '...')`. Print nothing if absent. |
| `config_prefix <wp-config.php>` | Print the literal value of `$table_prefix`. Print nothing if absent or non-literal. |
| `set_config_prefix <wp-config.php> <prefix>` | Rewrite the `$table_prefix` line. Write-in-place (temp file, verify, `cat > file`). |
| `url_host <url>` | Print the host, without scheme, port or `www.`. |
| `url_variants <url>` | Print the `http`/`https` × `www`/bare variants, one per line. The first line is the canonical form. |

Parsing must be compatible with **Bash 4.0**. Do not use `declare -g`, `declare -n` or `declare -gA`. Use `printf -v "DEPLOY_ENV_${key}"` and `${!var-}`.

---

## Suggested Fix

### 1. Create `lib/deploy_config.sh`

Implement the table above. Follow the conventions in [`lib/container_resolution.sh`](../../lib/container_resolution.sh) (`# shellcheck shell=bash` header, sourced-only, no `set -e`).

### 2. Make the table prefix a deploy target

Deploy and sync both currently derive the target prefix from the *other* side. Replace with:

- deploy: `DST_PREFIX="${PROD_TABLE_PREFIX:-$DST_PREFIX_CURRENT}"`
- sync: `DST_PREFIX="${STG_TABLE_PREFIX:-$SRC_PREFIX}"`

Validate with `^[A-Za-z0-9_]+$` and reject an empty or identical-to-source prefix only when a rename is required.

### 3. Derive search-replace from the URLs with a single boundary-guarded pass

Do not replace the bare host and then the `www.` variant in two passes. The second pass would rewrite the value written by the first. Iterate the source variants and map every one to the **same** canonical target variant (`url_variants "$TARGET" | head -n1`), as the scripts already do.

### 4. Derive exclusions from configuration

Build the `rsync` exclude list from a fixed base list plus `SECURITY_PLUGINS` / `PROD_SECURITY_PLUGIN` (each slug maps to `<slug>` directory and its known drop-in file where one exists). Keep the base list (`wp-config.php`, `wp-config-docker.php`, `.htaccess`) unchanged.

### 5. Keep the safety rails intact

- `--dry-run` must print the resolved plan and exit before any write.
- `--yes` is still required for any non-dry run.
- The pre-run backup happens before `rsync`, `DROP DATABASE` or `search-replace`.
- Backup paths are printed at the end.

### 6. Out of scope

- Changing the deploy direction or the stg/prod pairing.
- Replacing `rsync` or `mariadb-dump`.
- Multi-site WordPress.
- Any yadepan-specific default value. The scripts must not ship with `yadepan` in them.

---

## Acceptance Criteria

- [ ] `lib/deploy_config.sh` exists and is sourced by both scripts without error.
- [ ] Both scripts run `--dry-run` with **no** `.env` edits beyond filling `.env.example` placeholders.
- [ ] `grep -rn yadepan` across the repo returns matches only in `docs/issues/issue004.md` and `RELEASE.md` history.
- [ ] Setting `PROD_TABLE_PREFIX=wp_` on deploy and `STG_TABLE_PREFIX=stg_` on sync produces the expected prefixes in `--dry-run` output.
- [ ] Setting `PROD_URL` / `STG_URL` changes the URLs in `--dry-run` output and in the search-replace calls.
- [ ] A missing required key aborts with a message naming **all** missing keys.
- [ ] A `.env` line containing `$(...)` or a backtick is stored as literal text and never executed.
- [ ] `bash -n` passes on all changed scripts and `lib/deploy_config.sh`.
- [ ] Non-dry run without `--yes` refuses to run.
- [ ] README and RELEASE.md updated for v.1.2.0.

---

## Documentation Deliverables

### [`README.md`](../../README.md)

- Add both scripts to the **Scripts** table.
- Add a **Deploy & Sync (staging ↔ production)** section before **Recovery Process**. Cover: `.env` location, required and optional keys, table-prefix behaviour, `--dry-run` / `--yes`, and the rollback paths.

### [`RELEASE.md`](../../RELEASE.md)

- Add a `## v.1.2.0 — Configurable Deploy & Sync` section above v.1.1.1 with `**Tag:**` and `**Date:**` lines.
- Use **Added** for the scripts, `.env` config, `lib/deploy_config.sh` and the two table-prefix keys. Use **Changed** for the removal of hard-coded values.
- Keep `## [Unreleased]` with all three headings.

---

## Workaround Until Fixed

Copy the hard-coded values from `.env.example` into a local, untracked copy of each script and edit them directly. Do not commit that copy.

---

## Verification

```bash
bash -n deploy-stg-to-prod.sh
bash -n sync-prod-to-stg.sh
bash -n lib/deploy_config.sh
./deploy-stg-to-prod.sh stg prod --dry-run
./sync-prod-to-stg.sh prod stg --dry-run
./deploy-stg-to-prod.sh prod stg --dry-run    # must exit 2 (usage)
./deploy-stg-to-prod.sh stg prod              # must refuse without --yes
```

No test suite or CI exists. The checks above are the only automated gate.

---

## Related

- [`docs/issues/issue003.md`](issue003.md) — the container-resolution helpers the deploy scripts may reuse.
- [`RELEASE.md`](../../RELEASE.md) — v.1.2.0 entry.
- [`.env.example`](../../.env.example) — the configuration template.
