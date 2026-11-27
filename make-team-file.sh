#!/usr/bin/env bash
# Build a shareable saml2aws-team.conf from your own working setup.
# Usage: ./make-team-file.sh [-o FILE] [--title TEXT] [ENV=DB_HOST...]
#   Okta links come from ~/.saml2aws. Database hosts come from ENV=DB_HOST arguments, else your
#   saved hosts (~/.config/samllogin/hosts), else your installed team file. Usernames and
#   passwords are never copied. Default output: ./saml2aws-team.conf (ignored by git).
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"

out=$TEAM_FILE_NAME title="Team settings"
declare -A host=()
while (($#)); do
  case $1 in
    -o) [[ -n ${2:-} ]] || die "-o needs a file"; out=$2; shift ;;
    --title) [[ -n ${2:-} ]] || die "--title needs text"; title=$2; shift ;;
    -h|--help) sed -n '2,6s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *=*) host[${1%%=*}]=${1#*=} ;;
    *) die "Unknown argument: $1 (see --help)" ;;
  esac
  shift
done

mapfile -t envs < <(ini_sections "$SAML_CONFIG")
((${#envs[@]})) || die "No environments in $SAML_CONFIG. Run install.sh and sign in first."

saved_host() { [[ -f $HOSTS_FILE ]] && sed -n "s/^$1=//p" "$HOSTS_FILE" | tail -n1; }

{
  printf '# %s for https://github.com/GSA/saml2aws-setup\n' "$title"
  printf '# Internal: share privately. Save to Downloads, then run install.sh.\n'
  for env in "${envs[@]}"; do
    url=$(ini_get "$env" url)
    [[ -n $url ]] || { say "Skipping $env: no Okta link."; continue; }
    db=${host[$env]:-$(saved_host "$env")}
    db=${db:-$(team_get "$env" db_host)}
    printf '\n[%s]\nurl = %s\n' "$env" "$url"
    [[ -n $db ]] && printf 'db_host = %s\n' "$db"
    [[ -n $db ]] || say "Note: no database host for $env (pass $env=HOST to add one)."
  done
} >"$out.tmp"
chmod 600 "$out.tmp" && mv "$out.tmp" "$out"
say "Wrote $out ($(grep -c '^\[' "$out") environments). Share it privately, not in git."
