#!/usr/bin/env bash
# Rollback: restore the DB dump and www.tar.gz from BACKUP_DIR (see the printed paths on each run).
# Configuration comes from .env (see .env.example); nothing project-specific is hard-coded here.
set -euo pipefail

SRC_ENV="stg"
DST_ENV="prod"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/deploy_config.sh
. "$SCRIPT_DIR/lib/deploy_config.sh"

DRY_RUN=0
CONFIRMED=0
SRC_ARG=""
DST_ARG=""
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(basename "$0")" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $(basename "$0") <source> <target> [--dry-run] [--yes] [--env-file <path>]
  source, target : must be "stg" and "prod" (in that order)
  --dry-run      : print the resolved plan and change nothing
  --yes          : required to run against production
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
  [[ "$SRC_ARG" == "$SRC_ENV" && "$DST_ARG" == "$DST_ENV" ]] \
    || die "only '$SRC_ENV' -> '$DST_ENV' is supported"
  if [[ $DRY_RUN -eq 0 && $CONFIRMED -eq 0 ]]; then
    die "refusing to change production without --yes (or use --dry-run)"
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
  PROD_TABLE_PREFIX="$(deploy_env_get PROD_TABLE_PREFIX)"
  PROD_WP_OWNER="$(deploy_env_get PROD_WP_OWNER nobody:nogroup)"
  HEADER_SCRIPT="$(deploy_env_get HEADER_SCRIPT)"
  HEADER_THEME_MOD="$(deploy_env_get HEADER_THEME_MOD header_scripts)"
  PROD_SECURITY_PLUGIN="$(deploy_env_get PROD_SECURITY_PLUGIN)"

  if [[ -n "$HEADER_SCRIPT" ]]; then
    [[ "$HEADER_SCRIPT" == "<script"*"</script>" ]] || die "HEADER_SCRIPT must be one <script>...</script> tag"
  fi
  if [[ -n "$PROD_TABLE_PREFIX" ]]; then
    [[ "$PROD_TABLE_PREFIX" =~ ^[A-Za-z0-9_]+$ ]] || die "PROD_TABLE_PREFIX may only contain letters, digits and underscores"
  fi
}

load_config() {
  SRC_PATH="$STG_PATH"; DST_PATH="$PROD_PATH"
  SRC_WP_PATH="$STG_WP_PATH"; DST_WP_PATH="$PROD_WP_PATH"
  SRC_CFG="$SRC_PATH/wp-config.php"; DST_CFG="$DST_PATH/wp-config.php"
  [[ -f "$SRC_CFG" && -f "$DST_CFG" ]] || die "wp-config.php missing in staging or production path"

  SRC_DB="$(config_define "$SRC_CFG" DB_NAME)"; DST_DB="$(config_define "$DST_CFG" DB_NAME)"
  SRC_PREFIX="$(config_prefix "$SRC_CFG")";     DST_PREFIX_CURRENT="$(config_prefix "$DST_CFG")"
  [[ -n "$SRC_DB" && -n "$DST_DB" ]] || die "could not read DB_NAME from wp-config.php"
  [[ -n "$SRC_PREFIX" && -n "$DST_PREFIX_CURRENT" ]] || die "could not read table_prefix from wp-config.php (unsupported form?)"
  [[ "$SRC_DB" != "$DST_DB" ]] || die "source and target share the same database '$SRC_DB'"

  # Target prefix: PROD_TABLE_PREFIX when set, otherwise production's current prefix.
  DST_PREFIX="${PROD_TABLE_PREFIX:-$DST_PREFIX_CURRENT}"
  [[ "$SRC_PREFIX" != "$DST_PREFIX" ]] || log "note: table prefixes are identical; rename step is skipped"
}

print_plan() {
  log "Plan: $SRC_ENV -> $DST_ENV  (config: $ENV_FILE)"
  log "  files : $SRC_PATH/ -> $DST_PATH/ (wp-config*.php and .htaccess kept on prod)"
  log "  owner : $PROD_WP_OWNER (chown after file sync)"
  log "  db    : '$SRC_DB' (prefix '$SRC_PREFIX') -> '$DST_DB' (prefix '$DST_PREFIX', was '$DST_PREFIX_CURRENT')"
  log "  url   : $STG_URL -> $PROD_URL"
  log "  docker: db=$DB_CONTAINER app=$APP_CONTAINER docroot=$DST_WP_PATH"
  if [[ -n "$HEADER_SCRIPT" ]]; then
    log "  header: HEADER_SCRIPT -> prod theme mod '$HEADER_THEME_MOD'"
  else
    log "  header: skipped (HEADER_SCRIPT unset)"
  fi
  if [[ -n "$PROD_SECURITY_PLUGIN" ]]; then
    log "  plugin: activate $PROD_SECURITY_PLUGIN"
  else
    log "  plugin: skipped (PROD_SECURITY_PLUGIN unset)"
  fi
  log "  backup: $BACKUP_DIR"
}

check_prereqs() {
  docker inspect "$DB_CONTAINER" >/dev/null 2>&1 || die "container $DB_CONTAINER not running"
  docker inspect "$APP_CONTAINER" >/dev/null 2>&1 || die "container $APP_CONTAINER not running"
}

backup_prod() {
  local ts; ts="$(date '+%Y%m%d_%H%M%S')"
  mkdir -p "$BACKUP_DIR"
  BACKUP_DB="$BACKUP_DIR/${ts}_prod_db_${DST_DB}.sql.gz"
  BACKUP_FILES="$BACKUP_DIR/${ts}_prod_www.tar.gz"
  log "Backing up prod database to $BACKUP_DB"
  docker exec "$DB_CONTAINER" sh -c 'exec mariadb-dump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --databases "$0"' "$DST_DB" | gzip > "$BACKUP_DB"
  log "Backing up prod files to $BACKUP_FILES"
  tar -czf "$BACKUP_FILES" -C "$DST_PATH" .
}

sync_files() {
  command -v rsync >/dev/null || die "rsync is not installed (sudo apt install rsync)"
  [[ $EUID -eq 0 ]] || die "run with sudo: www/ files are owned by the container user"
  log "Syncing files $SRC_ENV -> $DST_ENV"
  rsync -a --no-owner --no-group --omit-dir-times --delete \
    --exclude 'wp-config.php' --exclude 'wp-config-docker.php' --exclude '.htaccess' \
    --exclude 'wordfence-waf.php' --exclude 'aios-bootstrap.php' \
    "$SRC_PATH/" "$DST_PATH/"
  docker exec "$APP_CONTAINER" chown -R "$PROD_WP_OWNER" "$DST_WP_PATH"
}

copy_database() {
  local dump="$BACKUP_DIR/stg_to_prod_$(date '+%Y%m%d_%H%M%S').sql"
  log "Dumping $SRC_DB"
  docker exec "$DB_CONTAINER" sh -c 'exec mariadb-dump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines "$0"' "$SRC_DB" > "$dump"

  log "Recreating $DST_DB and importing staging data"
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

  # Meta keys that embed the prefix, so logins and roles keep working.
  log "Rewriting prefixed meta keys"
  dbx "$DST_DB" -e "
    UPDATE \`${DST_PREFIX}usermeta\` SET meta_key = CONCAT('$DST_PREFIX', SUBSTRING(meta_key, LENGTH('$SRC_PREFIX') + 1))
      WHERE LEFT(meta_key, LENGTH('$SRC_PREFIX')) = '$SRC_PREFIX';
    UPDATE \`${DST_PREFIX}options\` SET option_name = CONCAT('$DST_PREFIX', SUBSTRING(option_name, LENGTH('$SRC_PREFIX') + 1))
      WHERE LEFT(option_name, LENGTH('$SRC_PREFIX')) = '$SRC_PREFIX' AND option_name LIKE '%user_roles';"

  # Production's wp-config.php must follow the new prefix, or WordPress looks for wp_* tables.
  if [[ "$DST_PREFIX" != "$DST_PREFIX_CURRENT" ]]; then
    log "Setting prod wp-config.php table_prefix to '$DST_PREFIX'"
    set_config_prefix "$DST_CFG" "$DST_PREFIX"
  fi
}

search_replace() {
  log "Search-replace $STG_URL -> $PROD_URL (all scheme/www variants)"
  local stg_host; stg_host="$(url_host "$STG_URL")"
  local v
  while read -r v; do
    wpx "$DST_WP_PATH" search-replace "$v" "$(url_variants "$PROD_URL" | head -n1)" \
      --all-tables-with-prefix --skip-columns=guid --precise --report-changed-only
  done < <(url_variants "$STG_URL")
  local left; left="$(wpx "$DST_WP_PATH" db query "SELECT COUNT(*) FROM ${DST_PREFIX}options WHERE option_name LIKE '%${stg_host}%'" --skip-column-names)"
  [[ "$left" == "0" ]] || log "WARNING: $left option_name rows still contain $stg_host (duplicate keys); review them manually"
}

allow_indexing() {
  log "Allowing search engines to index production"
  wpx "$DST_WP_PATH" option update blog_public 1
}

set_header_script() {
  if [[ -z "$HEADER_SCRIPT" ]]; then
    log "Skipping header script (HEADER_SCRIPT unset)"
    return 0
  fi
  log "Setting prod $HEADER_THEME_MOD from .env (replaces staging's value)"
  wpx "$DST_WP_PATH" theme mod set "$HEADER_THEME_MOD" "$HEADER_SCRIPT" >/dev/null
  local hs; hs="$(wpx "$DST_WP_PATH" theme mod get "$HEADER_THEME_MOD" --format=json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["value"])')"
  [[ "$hs" == "$HEADER_SCRIPT" ]] || die "prod $HEADER_THEME_MOD does not match HEADER_SCRIPT"
}

activate_security_plugin() {
  if [[ -z "$PROD_SECURITY_PLUGIN" ]]; then
    log "Skipping security plugin activation (PROD_SECURITY_PLUGIN unset)"
    return 0
  fi
  log "Activating security plugin: $PROD_SECURITY_PLUGIN"
  wpx "$DST_WP_PATH" plugin is-installed "$PROD_SECURITY_PLUGIN" || die "$PROD_SECURITY_PLUGIN is not installed on prod"
  if ! wpx "$DST_WP_PATH" plugin is-active "$PROD_SECURITY_PLUGIN"; then
    wpx "$DST_WP_PATH" plugin activate "$PROD_SECURITY_PLUGIN"
  fi
  wpx "$DST_WP_PATH" plugin is-active "$PROD_SECURITY_PLUGIN" || die "$PROD_SECURITY_PLUGIN is not active on prod"
}

verify() {
  log "Verifying $DST_DB and $PROD_URL"
  wpx "$DST_WP_PATH" core is-installed || die "WordPress is not installed on prod after deploy"
  local db_now; db_now="$(wpx "$DST_WP_PATH" db query 'SELECT DATABASE()' --skip-column-names)"
  [[ "$db_now" == "$DST_DB" ]] || die "prod wp-cli is connected to '$db_now', expected '$DST_DB'"
  local bp; bp="$(wpx "$DST_WP_PATH" option get blog_public)"
  [[ "$bp" == "1" ]] || die "blog_public is '$bp', expected 1"
  local cfg_prefix; cfg_prefix="$(wpx "$DST_WP_PATH" config get table_prefix)"
  [[ "$cfg_prefix" == "$DST_PREFIX" ]] || die "prod table_prefix is '$cfg_prefix', expected '$DST_PREFIX'"
  local code; code="$(curl -s -o /dev/null -w '%{http_code}' "$PROD_URL" || true)"
  log "HTTP $code from $PROD_URL"
}

remind() {
  cat <<EOF

Deploy finished. Remaining manual steps:
  1. Confirm the site loads on $PROD_URL and that analytics (if configured) reports pageviews.
  2. Run a scan in your security plugin and review any findings.
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

  backup_prod
  sync_files
  copy_database
  rename_prefix
  search_replace
  allow_indexing
  set_header_script
  activate_security_plugin
  verify
  remind
}

main "$@"
