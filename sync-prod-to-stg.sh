#!/usr/bin/env bash
# Rollback: restore the staging DB dump and stg_files.tar.gz from BACKUP_DIR (paths printed on each run).
# Configuration comes from .env (see .env.example); nothing project-specific is hard-coded here.
set -euo pipefail

SRC_ENV="prod"
DST_ENV="stg"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/deploy_config.sh
. "$SCRIPT_DIR/lib/deploy_config.sh"

DRY_RUN=0
CONFIRMED=0
SRC_ARG=""
DST_ARG=""
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
# Staging is hidden from search engines after a sync (blog_public=0); production is indexable.
STG_BLOG_PUBLIC=0

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(basename "$0")" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $(basename "$0") <source> <target> [--dry-run] [--yes] [--env-file <path>]
  source, target : must be "prod" and "stg" (in that order)
  --dry-run      : print the resolved plan and change nothing
  --yes          : required to overwrite staging
  --env-file     : configuration file (default: \$ENV_FILE or $SCRIPT_DIR/.env)
EOF
  exit 2
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --yes) CONFIRMED=1 ;;
      --env-file) [[ $# -ge 2 ]] || usage; ENV_FILE="$2"; shift ;;
      -h|--help) usage ;;
      *)
        if [[ -z "$SRC_ARG" ]]; then SRC_ARG="$1"
        elif [[ -z "$DST_ARG" ]]; then DST_ARG="$1"
        else usage
        fi ;;
    esac
    shift
  done
  [[ -n "$SRC_ARG" && -n "$DST_ARG" ]] || usage
  if [[ "$SRC_ARG" != "$SRC_ENV" || "$DST_ARG" != "$DST_ENV" ]]; then
    log "ERROR: only '$SRC_ENV' -> '$DST_ENV' is supported" >&2
    usage
  fi
  if [[ $DRY_RUN -eq 0 && $CONFIRMED -eq 0 ]]; then
    die "refusing to overwrite staging without --yes (or use --dry-run)"
  fi
}

# Run mariadb as root inside the DB container; the password never leaves the container.
dbx() { docker exec -i "$DB_CONTAINER" sh -c 'exec mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" "$@"' sh "$@"; }

# Run wp-cli in the app container against the given docroot.
wpx() { local path="$1"; shift; docker exec -e WP_PATH="$path" "$APP_CONTAINER" wp "$@"; }

load_env() {
  load_deploy_env "$ENV_FILE"
  require_deploy_keys "$ENV_FILE" PROD_URL STG_URL BASE_DIR PROD_PATH STG_PATH BACKUP_DIR \
    DB_CONTAINER APP_CONTAINER PROD_WP_PATH STG_WP_PATH

  PROD_URL="$(deploy_env_get PROD_URL)"
  STG_URL="$(deploy_env_get STG_URL)"
  BASE_DIR="$(deploy_env_get BASE_DIR)"
  PROD_PATH="$(deploy_env_get PROD_PATH)"
  STG_PATH="$(deploy_env_get STG_PATH)"
  BACKUP_DIR="$(deploy_env_get BACKUP_DIR)"
  DB_CONTAINER="$(deploy_env_get DB_CONTAINER)"
  APP_CONTAINER="$(deploy_env_get APP_CONTAINER)"
  PROD_WP_PATH="$(deploy_env_get PROD_WP_PATH)"
  STG_WP_PATH="$(deploy_env_get STG_WP_PATH)"
  STG_TABLE_PREFIX="$(deploy_env_get STG_TABLE_PREFIX)"
  SECURITY_PLUGINS="$(deploy_env_get SECURITY_PLUGINS)"

  if [[ -n "$STG_TABLE_PREFIX" ]]; then
    [[ "$STG_TABLE_PREFIX" =~ ^[A-Za-z0-9_]+$ ]] || die "STG_TABLE_PREFIX may only contain letters, digits and underscores"
  fi
}

load_config() {
  SRC_PATH="$PROD_PATH"; DST_PATH="$STG_PATH"
  SRC_WP_PATH="$PROD_WP_PATH"; DST_WP_PATH="$STG_WP_PATH"
  SRC_CFG="$SRC_PATH/wp-config.php"; DST_CFG="$DST_PATH/wp-config.php"
  [[ -f "$SRC_CFG" && -f "$DST_CFG" ]] || die "wp-config.php missing in production or staging path"

  SRC_DB="$(config_define "$SRC_CFG" DB_NAME)"; DST_DB="$(config_define "$DST_CFG" DB_NAME)"
  SRC_PREFIX="$(config_prefix "$SRC_CFG")";     OLD_STG_PREFIX="$(config_prefix "$DST_CFG")"
  [[ -n "$SRC_DB" && -n "$DST_DB" ]] || die "could not read DB_NAME from wp-config.php"
  [[ -n "$SRC_PREFIX" && -n "$OLD_STG_PREFIX" ]] || die "could not read table_prefix from wp-config.php (unsupported form?)"
  [[ "$SRC_DB" != "$DST_DB" ]] || die "source and target share the same database '$SRC_DB'"

  # Target prefix: STG_TABLE_PREFIX when set, otherwise production's prefix (staging adopts it).
  DST_PREFIX="${STG_TABLE_PREFIX:-$SRC_PREFIX}"

  # Validated here, before any backup or write, so a bad slug aborts with nothing changed.
  build_rsync_excludes "$SECURITY_PLUGINS"
}

print_plan() {
  log "Plan: $SRC_ENV -> $DST_ENV  (config: $ENV_FILE)"
  log "  files   : $SRC_PATH/ -> $DST_PATH/ (wp-config*.php, .htaccess kept on staging)"
  log "  db      : '$SRC_DB' -> '$DST_DB'"
  log "  prefix  : '$OLD_STG_PREFIX' -> '$DST_PREFIX' (set in staging wp-config.php)"
  log "  url     : $PROD_URL -> $STG_URL"
  log "  docker  : db=$DB_CONTAINER app=$APP_CONTAINER docroot=$DST_WP_PATH"
  if [[ -n "$SECURITY_PLUGINS" ]]; then
    log "  post    : deactivate security plugins: $SECURITY_PLUGINS"
  else
    log "  post    : no security plugins configured"
  fi
  log "  post    : discourage search engines on"
  log "  backup  : $BACKUP_DIR (staging DB + files before overwrite)"
}

check_prereqs() {
  docker inspect "$DB_CONTAINER" >/dev/null 2>&1 || die "container $DB_CONTAINER not running"
  docker inspect "$APP_CONTAINER" >/dev/null 2>&1 || die "container $APP_CONTAINER not running"
}

backup_staging() {
  local ts; ts="$(date '+%Y%m%d_%H%M%S')"
  mkdir -p "$BACKUP_DIR"
  BACKUP_DB="$BACKUP_DIR/${ts}_stg_db_${DST_DB}.sql.gz"
  BACKUP_FILES="$BACKUP_DIR/${ts}_stg_files.tar.gz"
  log "Backing up staging database to $BACKUP_DB"
  docker exec "$DB_CONTAINER" sh -c 'exec mariadb-dump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --databases "$0"' "$DST_DB" | gzip > "$BACKUP_DB"
  log "Backing up staging files to $BACKUP_FILES"
  tar -czf "$BACKUP_FILES" -C "$DST_PATH" .
}

sync_files() {
  command -v rsync >/dev/null || die "rsync is not installed (sudo apt install rsync)"
  log "Syncing files $SRC_ENV -> $DST_ENV"
  rsync -a --delete \
    "${RSYNC_EXCLUDES[@]}" \
    "$SRC_PATH/" "$DST_PATH/"
}

copy_database() {
  local dump="$BACKUP_DIR/prod_to_stg_$(date '+%Y%m%d_%H%M%S').sql"
  log "Dumping $SRC_DB"
  docker exec "$DB_CONTAINER" sh -c 'exec mariadb-dump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines "$0"' "$SRC_DB" > "$dump"

  log "Recreating $DST_DB and importing production data"
  dbx -e "DROP DATABASE IF EXISTS \`$DST_DB\`; CREATE DATABASE \`$DST_DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  dbx "$DST_DB" < "$dump"
  rm -f "$dump"
}

rename_prefix() {
  [[ "$SRC_PREFIX" != "$DST_PREFIX" ]] || return 0
  log "Renaming tables $SRC_PREFIX* -> $DST_PREFIX* in $DST_DB"
  local stmts="" t
  while read -r t; do
    [[ "$t" == "$SRC_PREFIX"* ]] || continue
    stmts+="RENAME TABLE \`$t\` TO \`${DST_PREFIX}${t#"$SRC_PREFIX"}\`;"
  done < <(dbx -N -B -e "SHOW TABLES FROM \`$DST_DB\`")
  [[ -n "$stmts" ]] && dbx "$DST_DB" -e "$stmts"

  log "Rewriting prefixed meta keys"
  dbx "$DST_DB" -e "
    UPDATE \`${DST_PREFIX}usermeta\` SET meta_key = CONCAT('$DST_PREFIX', SUBSTRING(meta_key, LENGTH('$SRC_PREFIX') + 1))
      WHERE LEFT(meta_key, LENGTH('$SRC_PREFIX')) = '$SRC_PREFIX';
    UPDATE \`${DST_PREFIX}options\` SET option_name = CONCAT('$DST_PREFIX', SUBSTRING(option_name, LENGTH('$SRC_PREFIX') + 1))
      WHERE LEFT(option_name, LENGTH('$SRC_PREFIX')) = '$SRC_PREFIX' AND option_name LIKE '%user_roles';"
}

set_staging_prefix() {
  log "Setting staging table_prefix to '$DST_PREFIX'"
  set_config_prefix "$DST_CFG" "$DST_PREFIX"
}

search_replace() {
  log "Search-replace $PROD_URL -> $STG_URL (all scheme/www variants)"
  local v
  while read -r v; do
    wpx "$DST_WP_PATH" search-replace "$v" "$(url_variants "$STG_URL" | head -n1)" \
      --all-tables-with-prefix --skip-columns=guid --precise --report-changed-only
  done < <(url_variants "$PROD_URL")
}

discourage_indexing() {
  log "Discouraging search engines on staging"
  wpx "$DST_WP_PATH" option update blog_public "$STG_BLOG_PUBLIC"
}

deactivate_security_plugins() {
  [[ -n "$SECURITY_PLUGINS" ]] || { log "No security plugins configured; nothing to deactivate"; return 0; }
  local active p
  active="$(wpx "$DST_WP_PATH" plugin list --status=active --field=name)"
  local IFS=','
  for p in $SECURITY_PLUGINS; do
    p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"
    [[ -n "$p" ]] || continue
    if grep -qx "$p" <<<"$active"; then
      log "Deactivating security plugin: $p"
      wpx "$DST_WP_PATH" plugin deactivate "$p"
    fi
  done
}

verify() {
  log "Verifying $DST_DB and $STG_URL"
  wpx "$DST_WP_PATH" core is-installed || die "WordPress is not installed on staging after sync"
  local db_now; db_now="$(wpx "$DST_WP_PATH" db query 'SELECT DATABASE()' --skip-column-names)"
  [[ "$db_now" == "$DST_DB" ]] || die "staging wp-cli is connected to '$db_now', expected '$DST_DB'"
  local home; home="$(wpx "$DST_WP_PATH" option get home)"
  [[ "$home" == "$STG_URL" ]] || die "staging home is '$home', expected '$STG_URL'"
  local bp; bp="$(wpx "$DST_WP_PATH" option get blog_public)"
  [[ "$bp" == "$STG_BLOG_PUBLIC" ]] || die "blog_public is '$bp', expected $STG_BLOG_PUBLIC"
  local prefix; prefix="$(wpx "$DST_WP_PATH" config get table_prefix)"
  [[ "$prefix" == "$DST_PREFIX" ]] || die "staging table_prefix is '$prefix', expected '$DST_PREFIX'"
  local code; code="$(curl -s -o /dev/null -w '%{http_code}' "$STG_URL" || true)"
  log "HTTP $code from $STG_URL"
}

remind() {
  cat <<EOF

Sync to staging finished. Remaining manual steps:
  1. Remove any analytics or tracking script from the staging site so it stops reporting pageviews.
  2. Review the security plugins that were deactivated; re-enable them manually only if needed on staging.
Rollback: restore $BACKUP_DB and $BACKUP_FILES if something is wrong.
EOF
}

main() {
  parse_args "$@"
  load_env
  check_prereqs
  load_config
  print_plan
  if [[ $DRY_RUN -eq 1 ]]; then log "Dry run: no changes made"; exit 0; fi

  backup_staging
  sync_files
  copy_database
  rename_prefix
  set_staging_prefix
  search_replace
  discourage_indexing
  deactivate_security_plugins
  verify
  remind
}

main "$@"
