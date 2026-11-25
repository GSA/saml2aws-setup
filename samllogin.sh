#!/usr/bin/env bash
# Sign in to AWS through Okta, then print a 15-minute database (RDS IAM) password.
# Usage: samllogin.sh [ENVIRONMENT [DB_USER]]   samllogin.sh --list
#   DB_HOST=... skips the hostname prompt; DB_PORT defaults to 3306.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"
require_tools saml2aws aws

saved_host() {
  [[ -f $HOSTS_FILE ]] || return 0
  grep -m1 "^$1=" "$HOSTS_FILE" | cut -d= -f2- || true
}

if [[ ${1:-} == --list ]]; then
  if [[ -s $HOSTS_FILE ]]; then sed 's/=/\t/' "$HOSTS_FILE"; else say "No saved hostnames ($HOSTS_FILE)."; fi
  exit 0
fi

env=$(choose_env "${1:-}")
db_user=${2:-${DB_USER:-admin}}
port=${DB_PORT:-3306}
ensure_env "$env"

# The database hostname differs per environment and must be the proxied endpoint.
# Ask once, then offer the saved one (Enter keeps it). DB_HOST skips the prompt.
db_host=${DB_HOST:-}
remembered=$(saved_host "$env")
if [[ -z $db_host ]]; then
  if ! have_tty; then
    [[ -n $remembered ]] || die "No terminal to ask on; set DB_HOST to the database hostname for $env."
    db_host=$remembered
  elif [[ -n $remembered ]]; then
    read -r -p "Database hostname for $env [$remembered]: " db_host </dev/tty
    db_host=${db_host:-$remembered}
  else
    read -r -p "Database hostname for $env (the proxied endpoint): " db_host </dev/tty
  fi
fi
# Pasted values can carry whitespace, a scheme, a path or a port; any of these
# become part of the signed host and make RDS reject the token.
db_host=${db_host//[[:space:]]/}
db_host=${db_host#*://}
db_host=${db_host%%/*}
db_host=${db_host%%:*}
[[ -n $db_host ]] || die "A database hostname is required."

login "$env"

token=$(aws rds generate-db-auth-token --hostname "$db_host" --port "$port" \
  --username "$db_user" --region "$REGION" --profile "$env" --no-cli-pager)

# Remember the hostname only once it has produced a token.
if [[ $db_host != "$remembered" ]]; then
  mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
  tmp=$(mktemp "$HOSTS_FILE.XXXXXX")
  { [[ -f $HOSTS_FILE ]] && grep -v "^$env=" "$HOSTS_FILE"; printf '%s=%s\n' "$env" "$db_host"; } >"$tmp" || true
  mv "$tmp" "$HOSTS_FILE"
  say "Saved the $env database hostname."
fi

say ""
say "Database password for $db_user@$db_host:$port (valid 15 minutes):"
for clip in clip.exe /mnt/c/Windows/System32/clip.exe; do
  if command -v "$clip" >/dev/null 2>&1 || [[ -x $clip ]]; then
    printf '%s' "$token" | "$clip" 2>/dev/null && say "(also copied to the clipboard; paste it as the password)"
    break
  fi
done
say ""
# Only the token goes to stdout, so it can be captured or redirected.
printf '%s\n' "$token"
