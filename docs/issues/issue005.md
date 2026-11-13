# Issue 005 — Staging returns 404 on every non-home URL after `sync-prod-to-stg.sh`

**Status**: Investigating (root cause confirmed in code; live-site confirmation pending)
**Affects**: [`sync-prod-to-stg.sh`](../../sync-prod-to-stg.sh) — `sync_files()`, `search_replace()`, `verify()`; [`lib/deploy_config.sh`](../../lib/deploy_config.sh) — `build_rsync_excludes()`; [`deploy-stg-to-prod.sh`](../../deploy-stg-to-prod.sh) — `sync_files()` (same exclusion, same risk)
**Severity**: High — staging is unusable for any page except the front page, so QA on staging is blocked
**Discovered**: 2026-11-14
**Reporter**: project owner (banrimkwae.com)

---

## TL;DR

After a sync, `https://stg.banrimkwae.com/` loads, but `https://stg.banrimkwae.com/en/` and every other front-end permalink return 404. `wp-admin` still works. Production (`www.banrimkwae.com`) serves all URLs correctly.

The likely cause is the **`.htaccess` file**. `build_rsync_excludes()` always excludes `.htaccess` from the file sync, so staging keeps its own `.htaccess` and never receives production's rewrite rules. The homepage works because `index.php` is served directly. Any other path needs the WordPress front-controller rewrite in `.htaccess`. With the wrong or missing rules, Apache/OpenLiteSpeed returns 404 for the file that does not exist on disk.

A second, contributing gap: the sync never flushes rewrite rules, and the script's `verify()` only checks the HTTP code of the homepage. It cannot detect this failure.

This issue is about **routing after sync**. It does not change the data copy, URL replacement or safety rails.

---

## Reproduction

1. Run `./sync-prod-to-stg.sh prod stg --yes`. Let it finish. `verify()` logs `HTTP 200 from https://stg.banrimkwae.com`.
2. Open these URLs in a browser or with `curl -I`:

| URL | Expected | Observed |
|---|---|---|
| `https://stg.banrimkwae.com/` | 200 | 200 |
| `https://stg.banrimkwae.com/en/` | 200 | 404 |
| `https://stg.banrimkwae.com/<any-post-or-page-slug>/` | 200 | 404 |
| `https://stg.banrimkwae.com/wp-admin/` | 302 to login | works |
| `https://www.banrimkwae.com/en/` | 200 | 200 (production, unaffected) |

3. Compare the rewrite rules on both sides:

```bash
# On the host
diff <(cat "$PROD_PATH/.htaccess") <(cat "$STG_PATH/.htaccess")
```

Expected finding: the files differ, or the staging copy is missing the `# BEGIN WordPress` block that production has.

---

## Root Cause

### 1. `.htaccess` is never synced

[`lib/deploy_config.sh`](../../lib/deploy_config.sh) `build_rsync_excludes()` sets:

```bash
RSYNC_EXCLUDES=(--exclude=wp-config.php --exclude=wp-config-docker.php --exclude=.htaccess)
```

[`sync-prod-to-stg.sh`](../../sync-prod-to-stg.sh) `sync_files()` runs `rsync -a --delete "${RSYNC_EXCLUDES[@]}"`. Staging's `.htaccess` is therefore the one that was there before the sync. It is not refreshed.

Production's `.htaccess` is usually more than the default WordPress block. It may contain:

- The `# BEGIN WordPress` front-controller rewrite. Without it, every non-existent path returns 404 instead of being routed to `index.php`.
- Plugin-added rules (caching, security, language redirects). Multilingual plugins such as Polylang or WPML often add rules for `/en/`-style prefixes.
- Redirects or canonical-host rules for production (e.g. `www`).

If staging's `.htaccess` is the default WordPress block, or was written by a plugin that is now deactivated on staging, `/en/` and other permalinks have no rewrite target. The homepage still works because the server serves `index.php` for `/`.

The `.htaccess` exclusion is intentional for one reason: production rules must not blindly overwrite staging-only rules (for example, basic-auth or `noindex` headers that staging may need). Excluding the file entirely trades that protection for a silent routing failure.

### 2. Rewrite rules are not regenerated after sync

`copy_database()` imports the production `rewrite_rules` option. That option encodes production's active plugins. `deactivate_security_plugins()` then turns plugins off on staging, and nothing calls `wp rewrite flush`. Staging's routing table no longer matches its plugin set.

### 3. `verify()` only checks the homepage

[`sync-prod-to-stg.sh`](../../sync-prod-to-stg.sh) `verify()` checks `home`, `blog_public` and `table_prefix`, then `curl`s `$STG_URL`. A homepage 200 says nothing about routing, so the script reports success on a broken staging site.

### Why the search-replace is not the cause

`search_replace()` rewrites `www.banrimkwae.com` / `banrimkwae.com` variants to `stg.banrimkwae.com`. Permalinks are relative paths in the DB, so `/en/` survives unchanged. The 404 is a server-level routing failure, not a URL-string problem.

---

## Suggested Fix

Dev should implement the following. Each step is independent. Steps 1 and 2 fix the reported bug. Steps 3 and 4 prevent recurrence.

### 1. Sync `.htaccess` from production, then re-add staging-only rules

Remove `--exclude=.htaccess` from `build_rsync_excludes()` for the **sync** direction only. Do this in `sync_files()` with a dedicated step, not by changing the shared base list:

- Back up staging's current `.htaccess` to `BACKUP_DIR` (the backup already contains it, since `backup_staging()` tars the whole docroot).
- Copy `$PROD_PATH/.htaccess` to `$STG_PATH/.htaccess`.
- Preserve any staging-only block the owner declares in `.env`. Add an optional key, e.g. `STG_HTACCESS_APPEND`, pointing to a file whose content is appended after the production copy. If the key is unset, copy production's file as-is.
- Ownership: run the same `chown` used for files so the web server can read it.

The **deploy** direction (`deploy-stg-to-prod.sh`) has the same exclusion. Do **not** change it in this issue. Production's `.htaccess` is what must survive a deploy. Record that decision in the issue's Acceptance Criteria.

### 2. Flush rewrite rules after plugin deactivation

Add `wpx "$DST_WP_PATH" rewrite flush --hard` to `sync-prod-to-stg.sh` after `deactivate_security_plugins()` and before `verify()`. Use `--hard` so WordPress writes the rules to `.htaccess` on the staging side. If `.htaccess` is not writable by the container user, the flush fails loudly. Do not swallow the error.

Note: with step 1, the synced `.htaccess` already carries production's rules. The flush ensures the DB `rewrite_rules` option matches the active plugin set on staging.

### 3. Make `verify()` check routing, not only the homepage

Add a probe of at least one non-home permalink. Choose it at runtime with `wpx "$DST_WP_PATH" post list --post_status=publish --field=url --posts_per_page=1` (or a `.env` key such as `VERIFY_PATH=/en/`). Fail with `die` if the probe is not `200` or `301`/`302`.

### 4. Document the expectation in the README

In the README's Deploy & Sync section, state that `.htaccess` is copied from production on sync, and that staging-only rules must go in the append file.

---

## Workaround Until Fixed

On the staging host, copy production's `.htaccess` by hand after each sync, then flush permalinks in the staging container:

```bash
sudo cp "$PROD_PATH/.htaccess" "$STG_PATH/.htaccess"
sudo docker exec -e WP_PATH="$STG_WP_PATH" "$APP_CONTAINER" wp rewrite flush --hard
curl -I "https://stg.banrimkwae.com/en/"
```

Remove any staging-only rule you need (e.g. `noindex` headers) and re-add it after the copy.

---

## Verification

Run all of these against staging after the fix. Each must pass:

```bash
bash -n sync-prod-to-stg.sh
bash -n deploy-stg-to-prod.sh
bash -n lib/deploy_config.sh
./sync-prod-to-stg.sh prod stg --dry-run           # plan shows .htaccess is copied
./sync-prod-to-stg.sh prod stg --yes
curl -s -o /dev/null -w '%{http_code}\n' https://stg.banrimkwae.com/        # 200
curl -s -o /dev/null -w '%{http_code}\n' https://stg.banrimkwae.com/en/     # 200
curl -s -o /dev/null -w '%{http_code}\n' https://stg.banrimkwae.com/wp-admin/  # 302
diff "$PROD_PATH/.htaccess" "$STG_PATH/.htaccess"   # no output (except staging-only append)
```

Also check a sample of deep permalinks (a post, a page, a category, an attachment) on staging, and confirm each returns the same status as on production.

There is no test suite or CI. These checks are the only gate.

---

## Acceptance Criteria

- [ ] After sync, `diff` between production and staging `.htaccess` is empty, or differs only by the staging-only append file.
- [ ] `/en/` and a sample of deep permalinks return 200 on staging, the same as production.
- [ ] `wp rewrite flush --hard` runs after the plugin deactivation step and fails the script if it errors.
- [ ] `verify()` fails if a non-home permalink does not return 200 or 301/302.
- [ ] `deploy-stg-to-prod.sh` still keeps production's `.htaccess` unchanged (no regression).
- [ ] `bash -n` passes on all changed scripts.
- [ ] README Deploy & Sync section and RELEASE.md updated.

---

## Open Questions for the Owner

These cannot be answered from the repo. The dev needs the answers before step 1 is final:

1. What does production's `.htaccess` contain? Please paste `cat $PROD_PATH/.htaccess` (redact any secrets).
2. Which language plugin does `/en/` use (Polylang, WPML, or other)? Is it in `SECURITY_PLUGINS`?
3. Is there any staging-only rule you need to keep (basic auth, `noindex` header, IP allow-list)?
4. Is the web server OpenLiteSpeed, Apache or Nginx? If Nginx, rewrite rules live in the server config and are **not** in `.htaccess`. In that case step 1 does not apply, and the fix must sync the vhost config (out of scope for this issue, see [`docs/issues/issue003.md`](issue003.md) for the container/webserver context).

---

## Related

- [`docs/issues/issue004.md`](issue004.md) — the `.env` configuration work that introduced `build_rsync_excludes()`.
- [`docs/issues/issue003.md`](issue003.md) — container and docroot resolution context.
- [`RELEASE.md`](../../RELEASE.md) — v.1.2.0 entry for the deploy and sync scripts.
