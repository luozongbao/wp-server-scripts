# Issue 004 — Make `deploy-stg-to-prod.sh` and `sync-prod-to-stg.sh` project-agnostic via a `.env` configuration file

**Status**: Open — targeted for v.1.2
**Affects**: [`deploy-stg-to-prod.sh`](../../deploy-stg-to-prod.sh) — `load_env()`, `load_config()`, `config_prefix()`, `rename_prefix()`, `search_replace()`, `remind()`; [`sync-prod-to-stg.sh`](../../sync-prod-to-stg.sh) — `load_config()`, `config_prefix()`, `set_staging_prefix()`, `search_replace()`, `deactivate_security_plugins()`
**Severity**: Medium — feature request; the scripts cannot be pointed at any WordPress project other than `yadepan.com`
**Discovered**: 2026-11-12
**Reporter**: project owner (yadepan.com)

---

## TL;DR

`deploy-stg-to-prod.sh` (staging → production) and `sync-prod-to-stg.sh`
(production → staging) were written for the **yadepan** project and have every
site-specific value baked in as a shell constant: host paths, container names,
container docroots, both URLs, the security-plugin list and — in one case —
the table prefix that the target is supposed to end up with.

The task is to make both scripts **project-agnostic**:

1. Move every site-specific value into a single `.env` file next to the
   scripts (`.env.example` already exists and is the template).
2. The three values explicitly called out by the owner — **`PROD_URL`**,
   **`STG_URL`** and the **target table prefix** — must be configurable.
3. Add a **real `.env` parser** (the current one greps a single key) and make
   it fail loudly on missing or malformed configuration.
4. Update [`README.md`](../../README.md) and [`RELEASE.md`](../../RELEASE.md)
   for **version 1.2**.

Nothing in this issue changes the *behaviour* of a deploy or a sync — only
**where the values come from**. The safety rails (`--dry-run`, `--yes`,
pre-deploy backups, rollback paths printed at the end) must survive unchanged.

---

## Reproduction

The scripts work correctly for yadepan and fail for every other project.

### The hard-coded values

[`deploy-stg-to-prod.sh:5-10`](../../deploy-stg-to-prod.sh#L5-L10):

```bash
BASE_DIR="/home/yadepan/yadepan"
BACKUP_DIR="/home/yadepan/backups"
DB_CONTAINER="yadepan_db"
APP_CONTAINER="yadepan_app"
PROD_URL="https://yadepan.com"
STG_URL="https://stg.yadepan.com"
```

[`sync-prod-to-stg.sh:5-14`](../../sync-prod-to-stg.sh#L5-L14) — the same six
constants, plus the container docroots:

```bash
SRC_WP_PATH="/var/www/vhosts/yadepan/html"
DST_WP_PATH="/var/www/vhosts/stg/html"
```

### Values that are not even variables

| Location | Hard-coded value | Problem |
|----------|------------------|---------|
| [`deploy-stg-to-prod.sh:68`](../../deploy-stg-to-prod.sh#L68) | `SRC_WP_PATH="/var/www/vhosts/stg/html"` / `DST_WP_PATH="/var/www/vhosts/yadepan/html"` | Docroots are derived from the yadepan OLS vhost layout |
| [`deploy-stg-to-prod.sh:161`](../../deploy-stg-to-prod.sh#L161) | `search-replace "stg.yadepan.com" "yadepan.com"` | A **second** search-replace with the literal hostnames, on top of the `$STG_URL` → `$PROD_URL` one on line 160 |
| [`deploy-stg-to-prod.sh:162-163`](../../deploy-stg-to-prod.sh#L162-L163) | `LIKE '%stg.yadepan.com%'` | The leftover-URL check is also hostname-specific |
| [`deploy-stg-to-prod.sh:203`](../../deploy-stg-to-prod.sh#L203) | `Confirm the Umami script loads on https://yadepan.com` | The reminder text hard-codes the production URL |
| [`sync-prod-to-stg.sh:16`](../../sync-prod-to-stg.sh#L16) | `SECURITY_PLUGINS=(all-in-one-wp-security-and-firewall wordfence sucuri-scanner …)` | The plugin list is a yadepan policy choice |
| [`sync-prod-to-stg.sh:137-138`](../../sync-prod-to-stg.sh#L137-L138) | `search-replace "https://yadepan.com"` / `"http://yadepan.com"` | The search-replace source strings are literal, not derived from `$PROD_URL` |
| [`deploy-stg-to-prod.sh:125`](../../deploy-stg-to-prod.sh#L125) | `chown -R nobody:nogroup "$DST_WP_PATH"` | The OLS ownership convention is hard-coded |

### The table prefix is not configurable at all

This is the item the owner called out explicitly, and it is the one with the
worst failure mode.

**`deploy-stg-to-prod.sh`** reads the production prefix *out of production's own
`wp-config.php`* and renames the imported staging tables to match
([`deploy-stg-to-prod.sh:73`](../../deploy-stg-to-prod.sh#L73) and
[`rename_prefix()` at L139-156](../../deploy-stg-to-prod.sh#L139-L156)):

```bash
SRC_PREFIX="$(config_prefix "$SRC_CFG")";     DST_PREFIX="$(config_prefix "$DST_CFG")"
```

The consequence: **the production prefix can never be changed by the deploy**.
The script can only ever move staging data *into whatever prefix production
already had*. If production's prefix should become `prod_`, the deploy does
nothing about it — and the tables are left named `stg_prefix_*` inside a
database whose `wp-config.php` still says `wp_`, i.e. a half-renamed database.

**`sync-prod-to-stg.sh`** has the mirror-image problem: staging is forced to
adopt production's prefix
([`sync-prod-to-stg.sh:79`](../../sync-prod-to-stg.sh#L79)):

```bash
DST_PREFIX="$SRC_PREFIX"
```

### `.env` support is half-implemented

`deploy-stg-to-prod.sh` has a `load_env()` function
([L80-88](../../deploy-stg-to-prod.sh#L80-L88)), but it only ever reads **one**
key:

```bash
line="$(grep -E '^HEADER_SCRIPT=' "$ENV_FILE" | tail -n1 || true)"
HEADER_SCRIPT="${line#HEADER_SCRIPT=}"
```

It ignores every other line, does not understand `export KEY=`, does not trim
whitespace, mishandles single quotes, and `sync-prod-to-stg.sh` has **no**
`.env` support whatsoever. The file that is supposed to hold the configuration
cannot yet hold a configuration.

### Observed behaviour on a non-yadepan project

```bash
$ ./deploy-stg-to-prod.sh stg prod --dry-run
[2026-11-12 10:02:11] Plan: stg -> prod
[2026-11-12 10:02:11]   files : /home/yadepan/yadepan/stg/ -> /home/yadepan/yadepan/www/
[2026-11-12 10:02:11]   db    : 'yadepan_stg' (prefix 'wp_') -> 'yadepan_prod' (prefix 'wp_')
```

Every line of that plan points at the wrong project. There is no flag that can
change it.

---

## Root Cause

The two scripts were written **for one project** and the site-specific values
were never lifted out. The pattern that produced this is consistent:

- **Values that vary per environment** (paths, container names, docroots) were
  placed in the "config" block at the top of the file — a reasonable pattern,
  but the block was never connected to a `.env` loader, so it became a set of
  hard-coded constants.
- **Values that vary per project** (the URLs, the security-plugin policy, the
  theme mod name) were inlined at their point of use instead of being passed
  down, so they could not be centralised even in principle.
- **The table prefix was never modelled as configuration.** It was derived from
  the target's live `wp-config.php` on both sides, which makes the prefix a
  *read-only observation* rather than a *deploy target*. The prefix-rename
  machinery (`RENAME TABLE` + prefixed-meta-key rewrite) already exists and is
  correct — it simply renames to whatever the target already had, which is
  always a no-op.

A secondary cause: the `config_prefix()` helper
([`deploy-stg-to-prod.sh:36`](../../deploy-stg-to-prod.sh#L36),
[`sync-prod-to-stg.sh:38`](../../sync-prod-to-stg.sh#L38)) only matches one
`wp-config.php` dialect:

```bash
config_prefix() { sed -nE "s/^\\\$table_prefix *= *getenv_docker\('[A-Z_]+', *'([^']+)'.*/\1/p" "$1" | head -n1; }
```

It finds `$table_prefix = getenv_docker('WORDPRESS_TABLE_PREFIX', 'wp_');` but
**not** the far more common plain form `$table_prefix = 'wp_';`. On a project
that uses the plain form, `config_prefix()` returns empty and the scripts die
with *"could not read table_prefix from wp-config.php"*.

---

## Configuration Contract

All configuration lives in a single `.env` file **next to the scripts**
(`$SCRIPT_DIR/.env`). `.env` is already git-ignored (`.gitignore` contains
`.env`); keep it that way and ship [`.env.example`](../../.env.example) as the
template.

### Required keys

| Key | Meaning | yadepan value | Notes |
|-----|---------|---------------|-------|
| `PROD_URL` | Public URL of production | `https://yadepan.com` | Used for search-replace **and** as the verification target. Include the scheme. |
| `STG_URL` | Public URL of staging | `https://stg.yadepan.com` | Same. |
| `BASE_DIR` | Host directory that contains both file trees | `/home/yadepan/yadepan` | Root for `PROD_PATH` / `STG_PATH` defaults. |
| `PROD_PATH` | Host path of the production files | `/home/yadepan/yadepan/www` | The directory rsync writes into. |
| `STG_PATH` | Host path of the staging files | `/home/yadepan/yadepan/stg` | The directory rsync reads from. |
| `BACKUP_DIR` | Where dumps and file tarballs are written | `/home/yadepan/backups` | Must exist or be creatable; backups are the rollback path. |
| `DB_CONTAINER` | MariaDB/MySQL container name | `yadepan_db` | Verified by `check_prereqs()`. |
| `APP_CONTAINER` | WordPress/PHP container name | `yadepan_app` | Must contain `wp-cli`. |
| `PROD_WP_PATH` | Docroot **inside** `APP_CONTAINER` for production | `/var/www/vhosts/yadepan/html` | The `WP_PATH` passed to `wp-cli`. |
| `STG_WP_PATH` | Docroot **inside** `APP_CONTAINER` for staging | `/var/www/vhosts/stg/html` | The `WP_PATH` passed to `wp-cli`. |

### Optional keys (with defaults)

| Key | Default | Meaning |
|-----|---------|---------|
| `PROD_TABLE_PREFIX` | value read from production `wp-config.php` | **Target table prefix for production.** When set, the deploy renames the imported tables to this prefix **and rewrites production's `wp-config.php` `$table_prefix` to match**. |
| `STG_TABLE_PREFIX` | production's prefix (current behaviour) | **Target table prefix for staging.** When set, the sync renames the imported tables to this prefix **and rewrites staging's `wp-config.php` `$table_prefix` to match**. |
| `HEADER_SCRIPT` | *(unset)* | Full `<script>…</script>` tag written to production's theme mod. Already implemented; keep the current behaviour (skip the step when unset). |
| `HEADER_THEME_MOD` | `header_scripts` | Name of the theme mod the header script lives in. yadepan's theme uses `header_scripts`. |
| `SECURITY_PLUGINS` | *(empty)* | Comma-separated slugs deactivated on staging by `sync-prod-to-stg.sh`. yadepan: `all-in-one-wp-security-and-firewall,wordfence,sucuri-scanner,better-wp-security,solid-security,ithemes-security-pro`. |
| `PROD_WP_OWNER` | `nobody:nogroup` | `user:group` applied by `chown -R` after the production file sync. OpenLiteSpeed default. |
| `DB_CLIENT` | `mariadb` | Client binary inside `DB_CONTAINER`. |
| `DB_DUMP_CLIENT` | `mariadb-dump` | Dump binary inside `DB_CONTAINER`. |
| `DB_ROOT_PASSWORD_ENV` | `MYSQL_ROOT_PASSWORD` | Name of the env var inside `DB_CONTAINER` holding the root password. |

### `.env` parsing rules

The current `load_env()` must be replaced with a parser that:

1. **Does not `source` the file.** Never execute `.env` as shell — parse it.
2. Ignores blank lines and `#` comments.
3. Accepts an optional `export ` prefix.
4. Trims leading/trailing whitespace around the key and the value.
5. Strips one layer of matching surrounding quotes (`"…"` or `'…'`).
6. Treats everything after the first `=` as the value (values may contain `=`).
7. **Fails loudly** — `die` with the offending key and line number — when a
   required key is missing, empty, or the file itself is absent.
8. Reports the resolved configuration in the `--dry-run` plan so the operator
   can see what the script is about to touch before confirming with `--yes`.

Add `--env-file <path>` to both scripts (and honour an `ENV_FILE` environment
variable) so the same script can be pointed at a different project's config
without editing the repo.

### Shared loader

Both scripts need the same loader. Put it in a new sourced-only helper,
[`lib/deploy_config.sh`](../../lib/container_resolution.sh) sibling, e.g.
`lib/deploy_config.sh`, and source it from both scripts:

````bash
# shellcheck source=lib/deploy_config.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/deploy_config.sh"
````

Follow the `lib/container_resolution.sh` precedent: **functions only**, no
executable code, `# shellcheck shell=bash` at the top. Update the
project-layout table in [`AGENTS.md`](../../AGENTS.md) when you add it.

---

## Suggested Fix

### 1. Replace the constant block with an `.env`-driven config

In both scripts, delete the hard-coded constants and load them from `.env`.
Keep a *fallback* for the values that are safe to default, and **no fallback**
for the ones that are not.

**`deploy-stg-to-prod.sh`** — replace
[`L5-10`](../../deploy-stg-to-prod.sh#L5-L10) and rework
[`load_config()` at L66-78](../../deploy-stg-to-prod.sh#L66-L78):

```bash
# Before
SRC_PATH="$BASE_DIR/stg"; DST_PATH="$BASE_DIR/www"
SRC_WP_PATH="/var/www/vhosts/stg/html"; DST_WP_PATH="/var/www/vhosts/yadepan/html"

# After
SRC_PATH="$STG_PATH"; DST_PATH="$PROD_PATH"
SRC_WP_PATH="$STG_WP_PATH"; DST_WP_PATH="$PROD_WP_PATH"
```

**`sync-prod-to-stg.sh`** — replace
[`L13-14, L69`](../../sync-prod-to-stg.sh#L13-L14) the same way, with the roles
swapped: `SRC_PATH="$PROD_PATH"`, `DST_PATH="$STG_PATH"`,
`SRC_WP_PATH="$PROD_WP_PATH"`, `DST_WP_PATH="$STG_WP_PATH"`.

The **source/target roles stay positional** — `stg`/`prod` in that order for
the deploy, `prod`/`stg` for the sync. Those are semantic roles, not project
names, and the CLI contract must not change.

### 2. Make the table prefix a deploy *target*, not an observation

This is the core of the change.

**`deploy-stg-to-prod.sh` — `rename_prefix()`**
([`L139-156`](../../deploy-stg-to-prod.sh#L139-L156)):

- `SRC_PREFIX` stays as read from staging's `wp-config.php`.
- `DST_PREFIX` becomes **`$PROD_TABLE_PREFIX`** when that key is set;
  otherwise it falls back to production's current `wp-config.php` value
  (today's behaviour).
- When `DST_PREFIX` differs from production's current prefix, the script must
  **also rewrite production's `wp-config.php`** `$table_prefix` — otherwise
  WordPress will look for `wp_posts` in a database that now holds
  `prod_posts`. The existing `RENAME TABLE` loop and the prefixed-meta-key
  rewrite (`usermeta.meta_key`, `options.option_name`) stay as they are; they
  are correct.
- Add a `set_config_prefix()` helper that patches the `wp-config.php` prefix
  — see point 3 for the matching writer.

**`sync-prod-to-stg.sh` — `set_staging_prefix()`**
([`L128-133`](../../sync-prod-to-stg.sh#L128-L133)):

- `DST_PREFIX` becomes **`$STG_TABLE_PREFIX`** when set, otherwise production's
  prefix (today's behaviour).
- When `STG_TABLE_PREFIX` is set and differs from production's prefix, the
  imported staging tables must be **renamed** to it, not merely the
  `wp-config.php` rewritten. The sync currently imports the dump verbatim and
  only rewrites `wp-config.php`, so it assumes both sides already share a
  prefix. Add the same `RENAME TABLE` + meta-key rewrite used by the deploy.

### 3. Generalise the `wp-config.php` prefix reader/writer

`config_prefix()` must recognise the common dialects, not just `getenv_docker`:

```bash
# $table_prefix = 'wp_';
# $table_prefix = getenv_docker('WORDPRESS_TABLE_PREFIX', 'wp_');
# $table_prefix = getenv('TABLE_PREFIX') ?: 'wp_';
```

The matching writer must handle the same three forms. `sync-prod-to-stg.sh`
already rewrites the `getenv_docker` form with `sed` — extend that to the
plain form, and keep the post-write assertion
(`grep -qE … || die`) so a failed rewrite is fatal rather than silent.

> Note: `deploy-stg-to-prod.sh` currently has **no** `wp-config.php` prefix
> writer at all (it never needed one). It needs the same helper the sync
> script uses — share it rather than copying it.

### 4. Derive the search-replace strings from the URLs

Delete the literal-hostname calls and derive everything from `$PROD_URL` /
`$STG_URL`:

- **Deploy** ([`L158-164`](../../deploy-stg-to-prod.sh#L158-L164)):
  replace `$STG_URL` → `$PROD_URL`, plus the scheme-less and `www.`-less
  variants of each host, so that `https://stg.example.com`,
  `http://stg.example.com` and `stg.example.com` are all covered. The
  leftover check must query for the **staging host**, derived the same way —
  not the literal `'%stg.yadepan.com%'`.
- **Sync** ([`L135-139`](../../sync-prod-to-stg.sh#L135-L139)): replace
  `$PROD_URL` → `$STG_URL`, plus the same variants derived from `$PROD_URL`.

Derive the host by stripping the scheme and any `www.` prefix from the
configured URL — do not assume the host equals the URL.

### 5. Move the remaining inline values to configuration

| Location | Change |
|----------|--------|
| [`deploy-stg-to-prod.sh:125`](../../deploy-stg-to-prod.sh#L125) | `chown -R nobody:nogroup` → `chown -R "$PROD_WP_OWNER"` |
| [`deploy-stg-to-prod.sh:162-163`](../../deploy-stg-to-prod.sh#L162-L163) | leftover check → derived staging host |
| [`deploy-stg-to-prod.sh:203`](../../deploy-stg-to-prod.sh#L203) | reminder text → `$PROD_URL` |
| [`deploy-stg-to-prod.sh:173-176`](../../deploy-stg-to-prod.sh#L173-L176) | theme mod name → `$HEADER_THEME_MOD`; **skip the step entirely when `HEADER_SCRIPT` is unset** |
| [`sync-prod-to-stg.sh:16`](../../sync-prod-to-stg.sh#L16) | `SECURITY_PLUGINS=(…)` array → comma-separated `$SECURITY_PLUGINS` from `.env`; skip silently when unset |
| [`deploy-stg-to-prod.sh:178-186`](../../deploy-stg-to-prod.sh#L178-L186) | `activate_security_plugin()` — the plugin slug is also a policy choice; read it from `.env` (e.g. `PROD_SECURITY_PLUGIN`) and skip when unset |

### 6. Keep the safety rails intact

- `--dry-run` must change nothing and must print the **resolved** plan
  (paths, container names, docroots, source/target prefixes, URLs).
- `--yes` remains required before anything is written to production.
- The pre-deploy/pre-sync backups (`backup_prod()`, `backup_staging()`) stay
  exactly as they are, and the rollback paths stay printed at the end.
- `check_prereqs()` keeps verifying that both containers exist.

### 7. Out of scope — do **not** change in this issue

- The CLI shape (`<source> <target> [--dry-run] [--yes]`), the positional
  arguments, and the exit codes.
- The `--dry-run` / `--yes` semantics.
- The order of the deploy/sync steps.
- The `set -euo pipefail` error-handling style. These two scripts are new
  additions that are not yet covered by the repo's
  [`.github/instructions/shell.instructions.md`](../../.github/instructions/shell.instructions.md)
  file (which names `wp_backup.sh`, `wp_restore.sh`, `webserver_backup.sh`,
  `webserver_restore.sh` and `lib/container_resolution.sh`). **Do not**
  restructure the error handling in this issue. Instead, record the deviation
  explicitly in [`AGENTS.md`](../../AGENTS.md) so the convention documents the
  exception rather than leaving it as a silent contradiction.

---

## Acceptance Criteria

- [ ] `deploy-stg-to-prod.sh` and `sync-prod-to-stg.sh` contain **no**
      project-specific literal: no `yadepan`, no hard-coded URL, no hard-coded
      container name, no hard-coded docroot, no hard-coded prefix.
      (`grep -niE 'yadepan' *.sh` returns nothing.)
- [ ] `PROD_URL`, `STG_URL` and both target table prefixes are read from `.env`.
- [ ] `PROD_TABLE_PREFIX` set to a value different from production's current
      prefix results in: tables renamed, production's `wp-config.php` prefix
      rewritten to the same value, and `wp core is-installed` still passing.
- [ ] `STG_TABLE_PREFIX` set to a value different from production's prefix
      results in: tables renamed on staging, staging's `wp-config.php` prefix
      rewritten, and `wp config get table_prefix` matching.
- [ ] Removing any **required** key from `.env` aborts with a message naming
      the key and the file — before anything is touched.
- [ ] `--env-file <path>` selects a different `.env`; `ENV_FILE` in the
      environment is honoured.
- [ ] `--dry-run` prints the fully resolved configuration (paths, containers,
      docroots, prefixes, URLs) and changes nothing.
- [ ] `--yes` is still required for a production write.
- [ ] The backup + rollback paths are still produced and still printed.
- [ ] `bash -n` passes for both scripts and `lib/deploy_config.sh`.
- [ ] The search-replace covers `https://`, `http://` and the bare host for
      both the staging and production hosts, and no literal hostname remains.
- [ ] `.env.example` documents **every** key above, with a short comment.

---

## Documentation Deliverables

### [`README.md`](../../README.md)

1. **Add a `## Deployment Scripts` section** (a natural home is after
   `## Webserver Backup & Restore`), covering both new scripts: what they do,
   the `stg`/`prod` positional contract, `--dry-run` / `--yes`, the `.env`
   requirement, and the rollback story.
2. **Add the two scripts to the `## Scripts` table** at the top of the README.
3. **Add a `.env` configuration reference** — either a table inside the new
   section or a sub-section — listing every key, its meaning and whether it is
   required. Do **not** duplicate the prose here and in the scripts: link
   instead, per the "link, don't duplicate" rule in
   [`.github/instructions/docs.instructions.md`](../../.github/instructions/docs.instructions.md).
4. **Update `## Dependencies`** — the deploy scripts need `rsync`, `docker`,
   `tar`, `gzip`, `python3` (for the theme-mod JSON read) and `curl`, and the
   production file sync needs root.
5. **Update `## Installation`** — mention `chmod 600 .env` and that `.env` is
   git-ignored while `.env.example` is tracked.
6. **Update `## Permissions`** — note that `deploy-stg-to-prod.sh` requires
   root for the `rsync`/`chown` step.
7. **Add a troubleshooting entry** for a missing/malformed `.env` and for the
   *"could not read table_prefix from wp-config.php"* failure (now only
   possible when the `wp-config.php` dialect is genuinely unsupported).

### [`RELEASE.md`](../../RELEASE.md)

- Move the existing `## [Unreleased]` entries into a new release section at the
  top of the file:

  ````markdown
  ## v.1.2 — Project-Agnostic Deployment Scripts

  **Tag:** `v.1.2`
  **Date:** 2026-11-12
  ````

- Under `### Added`: the new `deploy-stg-to-prod.sh` and `sync-prod-to-stg.sh`
  scripts, the `.env` configuration contract, and
  `lib/deploy_config.sh`.
- Under `### Changed`: the URL / table-prefix / container / docroot values are
  now read from `.env` instead of being hard-coded; the search-replace is
  derived from the configured URLs.
- Link this issue from the release entry — the target is `docs/issues/issue004.md`
  relative to the repository root (the path `RELEASE.md` itself uses).
- Keep the `## [Unreleased]` block at the top with all three headings
  (`### Added` / `### Fixed` / `### Removed`) present, even if empty.
- The version number exists **only** in `RELEASE.md` and the git tag — no
  script embeds a version string.

> **Version-naming note for the maintainer.** The user asked for "Version
> 1.2" and the working branch is already named `v.1.2`, but the newest release
> in `RELEASE.md` is `v.1.1.1` (three-component patch form) while older tags
> are `v.1.0` / `v.1.1`. `AGENTS.md` says to follow the newest convention
> (`v.1.1.1`). The issue uses `v.1.2` because that matches the branch name
> and the owner's wording — **confirm the tag format with the maintainer
> before tagging** (`v.1.2` vs `v.1.2.0`).

### Also update (consistency, not explicitly requested)

- [`.env.example`](../../.env.example) — list every key with a comment.
- [`AGENTS.md`](../../AGENTS.md) — add the two new scripts and
  `lib/deploy_config.sh` to the project-layout table; note the `set -euo
  pipefail` deviation.
- [`docs/about.md`](../../docs/about.md) — the project-layout tree and the
  version table both need the new files and the `v.1.2` row.

---

## Workaround Until Fixed

Until the `.env` support lands, a developer can still point the scripts at
another project by overriding the constants at the top of the file — but this
is an edit, not a configuration, and it must not be committed:

```bash
# Temporary, local-only: sed the constants for a different project
sed -i.bak \
  -e 's|^BASE_DIR=.*|BASE_DIR="/srv/myproject"|' \
  -e 's|^DB_CONTAINER=.*|DB_CONTAINER="myproject_db"|' \
  -e 's|^APP_CONTAINER=.*|APP_CONTAINER="myproject_app"|' \
  -e 's|^PROD_URL=.*|PROD_URL="https://example.com"|' \
  -e 's|^STG_URL=.*|STG_URL="https://stg.example.com"|' \
  deploy-stg-to-prod.sh
```

Note that this still does **not** fix the table prefix, the search-replace
hostnames or the docroots — those need the code change.

---

## Verification

This repo has **no test suite and no CI** — see the
[`verify-scripts`](../../.github/skills/verify-scripts/SKILL.md) skill. The
change must be verified manually, and the verification notes must state what
was actually run.

**Level 1 — syntax and help (no side effects):**

````bash
cd /home/zongbao/projects/wp-server-scripts
for f in *.sh lib/*.sh; do bash -n "$f" && echo "OK   $f" || echo "FAIL $f"; done
./deploy-stg-to-prod.sh --help
./sync-prod-to-stg.sh --help
````

**Level 2 — config resolution (no stack required):**

- Copy `.env.example` to a scratch `.env`, change every value, run both
  scripts with `--dry-run` and confirm the printed plan matches the file
  exactly.
- Delete one required key at a time and confirm each run aborts with a message
  naming the key — and that it aborts **before** any container is touched.
- Point `--env-file` at a second `.env` and confirm the plan changes.

**Level 3 — live stack (disposable stack only, never a production site):**

- `docker ps` to identify the containers, then run `deploy-stg-to-prod.sh stg
  prod --dry-run` and `sync-prod-to-stg.sh prod stg --dry-run` and confirm the
  resolved container names, docroots and prefixes.
- With `PROD_TABLE_PREFIX` set to a **new** value, run the deploy against a
  disposable stack and confirm: tables renamed, `wp-config.php` rewritten,
  `wp config get table_prefix` matches, `wp core is-installed` passes, and the
  pre-deploy backup exists on disk.
- Confirm the search-replace left no occurrence of the staging host:
  ````bash
  docker exec <db_container> mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" \
    -e "SELECT COUNT(*) FROM \`<prefix>options\` WHERE option_name LIKE '%<staging-host>%'"
  ````

**Report honestly.** If no disposable stack is available, say so in the
release entry rather than implying the deploy path was exercised.

---

## Related

- [`deploy-stg-to-prod.sh`](../../deploy-stg-to-prod.sh) — staging → production deploy
- [`sync-prod-to-stg.sh`](../../sync-prod-to-stg.sh) — production → staging sync
- [`.env.example`](../../.env.example) — configuration template to be extended
- [`lib/container_resolution.sh`](../../lib/container_resolution.sh) — the
  existing sourced-helper precedent (`lib/deploy_config.sh` should follow it);
  its 5-step DB-container chain is an optional alternative to hard-coding
  `DB_CONTAINER` in `.env`
- [`docs/issues/issue003.md`](issue003.md) — the DB-container / docroot
  resolution hardening (v.1.1.1); the same "resolve it, don't hard-code it"
  thinking applies to `DB_CONTAINER` and `PROD_WP_PATH` / `STG_WP_PATH`
- [`AGENTS.md`](../../AGENTS.md) — safety rules, project layout, release process
- [`.github/instructions/shell.instructions.md`](../../.github/instructions/shell.instructions.md)
  — shell conventions (note: it does not yet cover the two deploy scripts)
- [`.github/instructions/docs.instructions.md`](../../.github/instructions/docs.instructions.md)
  — README / RELEASE / `docs/about.md` split and link-integrity rules
- [`RELEASE.md`](../../RELEASE.md) — the `v.1.2` changelog entry
