# shellcheck shell=bash
#
# lib/deploy_config.sh - shared .env parser and wp-config.php helpers for
# deploy-stg-to-prod.sh and sync-prod-to-stg.sh.
#
# Sourced only, never executed. Defines functions only. Bash 4.0 compatible.
#
# Provided helpers:
#   load_deploy_env <file>
#   deploy_env_get <KEY> [default]
#   require_deploy_keys <file> KEY...
#   config_define <wp-config.php> <NAME>
#   config_prefix <wp-config.php>
#   set_config_prefix <wp-config.php> <prefix>
#   url_host <url>
#   url_variants <url>
#   build_rsync_excludes <csv-slugs>   (fills global array RSYNC_EXCLUDES)

# Keys the scripts understand. Anything else in .env is ignored with a warning.
_DEPLOY_KNOWN_KEYS="PROD_URL STG_URL BASE_DIR PROD_PATH STG_PATH BACKUP_DIR
DB_CONTAINER APP_CONTAINER PROD_WP_PATH STG_WP_PATH PROD_TABLE_PREFIX
STG_TABLE_PREFIX HEADER_SCRIPT HEADER_THEME_MOD SECURITY_PLUGINS
PROD_SECURITY_PLUGIN PROD_WP_OWNER"

_deploy_die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

_deploy_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Parse one raw value: strip one quoted layer, or cut an unquoted inline comment.
# A '#' is only a comment when preceded by whitespace; quoted values keep it.
_deploy_parse_value() {
    local v="$1" q rest inner after
    if [[ "$v" == \"* || "$v" == \'* ]]; then
        q="${v:0:1}"
        rest="${v:1}"
        [[ "$rest" == *"$q"* ]] || _deploy_die "unterminated quote in value: $v"
        inner="${rest%%"$q"*}"
        after="$(_deploy_trim "${rest#*"$q"}")"
        [[ -z "$after" || "$after" == \#* ]] || _deploy_die "unexpected text after closing quote: $v"
        printf '%s' "$inner"
        return 0
    fi
    if [[ "$v" =~ ^(.*)[[:space:]]#.*$ ]]; then
        v="${BASH_REMATCH[1]}"
    fi
    _deploy_trim "$v"
}

# load_deploy_env <file>: parse KEY=VALUE lines into DEPLOY_ENV_<KEY> variables.
# The file is parsed, never sourced, so $(...) and backticks stay literal.
load_deploy_env() {
    local file="$1" line key value lineno=0 known
    [[ -n "$file" && -r "$file" ]] || _deploy_die "cannot read env file: ${file:-<empty>}"

    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        line="$(_deploy_trim "$line")"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" == export[[:space:]]* ]]; then
            line="$(_deploy_trim "${line#export}")"
        fi
        [[ "$line" == *=* ]] || _deploy_die "$file:$lineno: expected KEY=VALUE"

        key="$(_deploy_trim "${line%%=*}")"
        value="$(_deploy_trim "${line#*=}")"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || _deploy_die "$file:$lineno: invalid key name '$key'"

        known=0
        for k in $_DEPLOY_KNOWN_KEYS; do
            if [[ "$k" == "$key" ]]; then known=1; break; fi
        done
        if [[ $known -eq 0 ]]; then
            printf 'WARNING: ignoring unknown key %s in %s\n' "$key" "$file" >&2
            continue
        fi

        value="$(_deploy_parse_value "$value")"
        printf -v "DEPLOY_ENV_${key}" '%s' "$value"
    done < "$file"
}

# deploy_env_get <KEY> [default]: print the value, or the default when unset or empty.
deploy_env_get() {
    local var="DEPLOY_ENV_$1"
    local value="${!var-}"
    if [[ -n "$value" ]]; then
        printf '%s' "$value"
    else
        printf '%s' "${2-}"
    fi
    return 0
}

# require_deploy_keys <file> KEY...: report every missing key before aborting.
require_deploy_keys() {
    local file="$1" key missing=0
    shift
    for key in "$@"; do
        if [[ -z "$(deploy_env_get "$key")" ]]; then
            printf 'ERROR: %s is not set in %s\n' "$key" "$file" >&2
            missing=1
        fi
    done
    [[ $missing -eq 0 ]] || exit 1
}

# config_define <wp-config.php> <NAME>: print the literal value of define('NAME', '...').
config_define() {
    local file="$1" name="$2" line re q="[\"']"
    [[ -r "$file" ]] || return 0
    re="^[[:space:]]*define[[:space:]]*\([[:space:]]*${q}${name}${q}[[:space:]]*,[[:space:]]*${q}([^\"']*)${q}"
    while IFS= read -r line; do
        if [[ "$line" =~ $re ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return 0
        fi
    done < "$file"
    return 0
}

# config_prefix <wp-config.php>: print the literal value of $table_prefix.
config_prefix() {
    local file="$1" line re q="[\"']"
    [[ -r "$file" ]] || return 0
    re="^[[:space:]]*\\\$table_prefix[[:space:]]*=[[:space:]]*${q}([^\"']*)${q}[[:space:]]*;"
    while IFS= read -r line; do
        if [[ "$line" =~ $re ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return 0
        fi
    done < "$file"
    return 0
}

# set_config_prefix <wp-config.php> <prefix>: rewrite the $table_prefix line in place.
# Writes a temp file, re-reads it to verify, then copies over the original.
set_config_prefix() {
    local file="$1" prefix="$2" tmp line replaced=0 re q="[\"']"
    [[ "$prefix" =~ ^[A-Za-z0-9_]+$ ]] || _deploy_die "invalid table prefix: '$prefix'"
    [[ -w "$file" ]] || _deploy_die "cannot write $file"
    re="^[[:space:]]*\\\$table_prefix[[:space:]]*=[[:space:]]*${q}[^\"']*${q}[[:space:]]*;"

    tmp="$(mktemp)" || _deploy_die "mktemp failed"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ $replaced -eq 0 && "$line" =~ $re ]]; then
            line="${line%%\$table_prefix*}\$table_prefix = '${prefix}';"
            replaced=1
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$file"

    if [[ $replaced -ne 1 ]]; then
        rm -f "$tmp"
        _deploy_die "no \$table_prefix assignment found in $file"
    fi
    if [[ "$(config_prefix "$tmp")" != "$prefix" ]]; then
        rm -f "$tmp"
        _deploy_die "verification failed rewriting \$table_prefix in $file"
    fi
    cat "$tmp" > "$file" || { rm -f "$tmp"; _deploy_die "failed writing $file"; }
    rm -f "$tmp"
}

# url_host <url>: print the host without scheme, port, path or leading www.
url_host() {
    local h="${1#*://}"
    h="${h%%/*}"
    h="${h%%:*}"
    printf '%s' "${h#www.}"
}

# url_variants <url>: print scheme/www variants, canonical (as given) first.
url_variants() {
    local url="$1" scheme authority other_scheme alt_auth
    [[ "$url" == *://* ]] || _deploy_die "URL must include a scheme: $url"
    scheme="${url%%://*}"
    authority="${url#*://}"
    authority="${authority%%/*}"

    if [[ "$scheme" == https ]]; then other_scheme=http; else other_scheme=https; fi
    if [[ "$authority" == www.* ]]; then alt_auth="${authority#www.}"; else alt_auth="www.$authority"; fi

    printf '%s\n' \
        "$scheme://$authority" \
        "$scheme://$alt_auth" \
        "$other_scheme://$authority" \
        "$other_scheme://$alt_auth"
}

# _security_dropin <slug>: print the known drop-in file for a security plugin, if any.
_security_dropin() {
    case "$1" in
        wordfence) printf '%s' wordfence-waf.php ;;
        all-in-one-wp-security-and-firewall) printf '%s' aios-bootstrap.php ;;
        *) return 0 ;;
    esac
}

# build_rsync_excludes <csv-slugs>: fill RSYNC_EXCLUDES with the base list plus each plugin's dir and drop-in.
build_rsync_excludes() {
    local slugs="$1" s drop
    RSYNC_EXCLUDES=(--exclude=wp-config.php --exclude=wp-config-docker.php --exclude=.htaccess)
    local IFS=','
    for s in $slugs; do
        s="$(_deploy_trim "$s")"
        [[ -n "$s" ]] || continue
        [[ "$s" =~ ^[a-z0-9_-]+$ ]] || _deploy_die "invalid plugin slug: '$s'"
        RSYNC_EXCLUDES+=("--exclude=/wp-content/plugins/$s/")
        drop="$(_security_dropin "$s")"
        [[ -z "$drop" ]] || RSYNC_EXCLUDES+=("--exclude=$drop")
    done
}
