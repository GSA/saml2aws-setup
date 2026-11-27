# Shared helpers for awslogin.sh, samllogin.sh and install.sh. Source, don't run.
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2016  # vars are used by callers; PowerShell code is single-quoted on purpose

export PATH="$HOME/.local/bin:$PATH"

SAML_CONFIG=${SAML2AWS_CONFIGFILE:-$HOME/.saml2aws}
STATE_DIR=${SAMLLOGIN_STATE:-${XDG_CONFIG_HOME:-$HOME/.config}/samllogin}
HOSTS_FILE=${SAMLLOGIN_HOSTS:-$STATE_DIR/hosts}
PASSWORD_DIR=$STATE_DIR/passwords
TEAM_FILE=${SAMLLOGIN_TEAM:-$STATE_DIR/team.conf}
TEAM_FILE_NAME=saml2aws-team.conf
REGION=${AWS_REGION:-us-east-1}
DEFAULT_ENVIRONMENTS=${SAMLLOGIN_ENVIRONMENTS:-"dev mgmt prod"}
# Okta usernames must be an email in this domain; set SAMLLOGIN_EMAIL_DOMAIN= (empty) to allow any.
EMAIL_DOMAIN=${SAMLLOGIN_EMAIL_DOMAIN-gsa.gov}

say() { printf '%s\n' "$*" >&2; }
die() { say "$*"; exit 1; }

require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null || die "Missing $tool. Run install.sh first."
  done
}

have_tty() { { : </dev/tty; } 2>/dev/null; }

# ---- ~/.saml2aws ----------------------------------------------------------

# ini_read FILE SECTION KEY: value of KEY in [SECTION] (the file may start with a UTF-8 BOM).
ini_read() {
  [[ -f $1 ]] || return 0
  awk -v sec="[$2]" -v key="$3" '
    { sub(/^\xef\xbb\xbf/, ""); line = $0; gsub(/^[ \t]+|[ \t\r]+$/, "", line) }
    line ~ /^\[/ { insec = (line == sec); next }
    insec {
      i = index(line, "="); if (!i) next
      k = substr(line, 1, i - 1); v = substr(line, i + 1)
      gsub(/[ \t]+$/, "", k); gsub(/^[ \t]+/, "", v)
      if (k == key) { print v; exit }
    }' "$1"
}

ini_sections() {
  [[ -f $1 ]] || return 0
  sed 's/^\xef\xbb\xbf//; s/\r$//' "$1" | sed -n 's/^\[\([A-Za-z0-9_-]*\)\][[:space:]]*$/\1/p'
}

# ini_get ENV KEY: from ~/.saml2aws.  team_get ENV KEY: from the shared team file.
ini_get() { ini_read "$SAML_CONFIG" "$1" "$2" | awk '{ sub(/\r$/, ""); print }'; }
team_get() { ini_read "$TEAM_FILE" "$1" "$2" | awk '{ sub(/\r$/, ""); print }'; }

configured_envs() {
  { ini_sections "$SAML_CONFIG"; ini_sections "$TEAM_FILE"; } | awk '!seen[$0]++'
}

valid_env_name() { [[ $1 =~ ^[A-Za-z0-9_-]+$ ]]; }

default_duration() { [[ $1 == prod* ]] && echo 3600 || echo 28800; }

# configure_env ENV URL USERNAME [DURATION]: write (or rewrite) the [ENV] section.
configure_env() {
  local env=$1 url=$2 user=$3 duration=${4:-$(default_duration "$1")} out
  if ! out=$(saml2aws configure --skip-prompt \
    --config "$SAML_CONFIG" \
    --idp-account "$env" --profile "$env" \
    --idp-provider Okta --mfa "${SAML2AWS_MFA:-Auto}" \
    --region "$REGION" --session-duration "$duration" \
    --disable-sessions \
    --url "$url" --username "$user" 2>&1); then
    say "$out"
    die "Could not save the $env settings."
  fi
}

prompt_url() {
  local env=$1 url
  say ""
  say "Paste the Okta link for the AWS \"$env\" environment."
  say "  Find it in your Okta dashboard: right-click the AWS tile for $env and choose \"Copy link\"."
  say "  It looks like https://<your-org>.okta.com/home/amazon_aws/<id>/272"
  while :; do
    read -r -p "Okta link for $env: " url </dev/tty
    url=${url//[[:space:]]/}
    [[ $url =~ ^https://[^/]+/home/amazon_aws/[A-Za-z0-9]+/[0-9]+ ]] && break
    say "That doesn't look like an Okta AWS link. Try again (Ctrl+C to quit)."
  done
  printf '%s' "$url"
}

valid_username() {
  [[ -z $EMAIL_DOMAIN ]] && [[ -n $1 ]] && return 0
  local local_part=${1%@*}
  [[ ${1,,} == *@"${EMAIL_DOMAIN,,}" && -n $local_part && $local_part != *[@[:space:]]* ]]
}

last_username() {
  local last
  [[ -f $STATE_DIR/username ]] && last=$(<"$STATE_DIR/username")
  if valid_username "${last:-}"; then printf '%s' "$last"; fi
  return 0
}

prompt_username() {
  local env=$1 last user hint="your GSA email, e.g. first.last@$EMAIL_DOMAIN"
  [[ -n $EMAIL_DOMAIN ]] || hint="usually your work email"
  last=$(last_username)
  while :; do
    if [[ -n $last ]]; then
      read -r -p "Okta username for $env ($hint) [$last]: " user </dev/tty
      user=${user:-$last}
    else
      read -r -p "Okta username for $env ($hint): " user </dev/tty
    fi
    user=${user//[[:space:]]/}
    valid_username "$user" && break
    say "  That isn't a @$EMAIL_DOMAIN address. Use your GSA email, not a personal one."
  done
  printf '%s' "$user"
}

remember_username() {
  mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
  printf '%s\n' "$1" >"$STATE_DIR/username"
}

# ensure_env ENV: make sure [ENV] has a URL and username, asking once and saving the answers.
ensure_env() {
  local env=$1 url user duration
  valid_env_name "$env" || die "Environment names may only use letters, digits, - and _: $env"
  url=$(ini_get "$env" url)
  user=$(ini_get "$env" username)
  if [[ -n $user ]] && ! valid_username "$user"; then
    say "The saved $env username ($user) isn't a @$EMAIL_DOMAIN address; enter your GSA email."
    user=
  fi
  if [[ -n $url && -n $user ]]; then
    # Okta now refuses saml2aws's session API with HTTP 403 after MFA; turn it off for older setups.
    [[ $(ini_get "$env" disable_sessions) == true ]] ||
      configure_env "$env" "$url" "$user" "$(ini_get "$env" aws_session_duration)"
    return 0
  fi
  [[ -n $url ]] || url=$(team_get "$env" url)
  have_tty || die "Environment \"$env\" is not set up yet; run this in a terminal once to set it up."
  [[ -n $url ]] || url=$(prompt_url "$env")
  [[ -n $user ]] || user=$(prompt_username "$env")
  duration=$(ini_get "$env" aws_session_duration)
  configure_env "$env" "$url" "$user" "${duration:-}"
  remember_username "$user"
  say "Saved the $env settings in $SAML_CONFIG."
}

# choose_env [ARG]: the environment from ARG, or a menu of configured ones.
choose_env() {
  local envs=() e i choice
  if [[ -n ${1:-} ]]; then printf '%s' "$1"; return; fi
  have_tty || die "Usage: $0 ENVIRONMENT"
  mapfile -t envs < <(configured_envs)
  say "Which environment?"
  for i in "${!envs[@]}"; do say "  $((i + 1))) ${envs[$i]}"; done
  say "  n) set up a new one"
  while :; do
    read -r -p "Choose [1-${#envs[@]} or n]: " choice </dev/tty
    if [[ $choice == n ]]; then
      read -r -p "Name for the new environment (for example dev): " e </dev/tty
      valid_env_name "$e" && { printf '%s' "$e"; return; }
    elif [[ $choice =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#envs[@]})); then
      printf '%s' "${envs[$((choice - 1))]}"; return
    fi
  done
}

# ---- saved passwords --------------------------------------------------------
# WSL: encrypted with Windows DPAPI via PowerShell, so only your Windows login can read it.
# Elsewhere: the desktop keyring through secret-tool, if available. Otherwise nothing is saved.

powershell_exe() {
  local p
  p=$(command -v powershell.exe 2>/dev/null) && { printf '%s' "$p"; return; }
  for p in /mnt/*/Windows/System32/WindowsPowerShell/v1.0/powershell.exe; do
    [[ -x $p ]] && { printf '%s' "$p"; return; }
  done
  return 1
}

password_backend() {
  if [[ -n ${SAMLLOGIN_NO_SAVE:-} ]]; then echo none
  elif powershell_exe >/dev/null; then echo dpapi
  elif command -v secret-tool >/dev/null; then echo secret-tool
  else echo none
  fi
}

ps_run() {
  # Run from a Windows directory so PowerShell doesn't warn about a UNC working directory.
  (cd /mnt/c 2>/dev/null || true; "$(powershell_exe)" -NoProfile -NonInteractive -Command \
    "[Console]::InputEncoding=[Text.Encoding]::UTF8; [Console]::OutputEncoding=[Text.Encoding]::UTF8; $1") | tr -d '\r'
}

password_load() {
  local env=$1
  case $(password_backend) in
    dpapi)
      [[ -s $PASSWORD_DIR/$env.dpapi ]] || return 0
      ps_run '$b=[Console]::In.ReadLine(); (New-Object System.Management.Automation.PSCredential "u",(ConvertTo-SecureString $b)).GetNetworkCredential().Password' \
        <"$PASSWORD_DIR/$env.dpapi" 2>/dev/null || true ;;
    secret-tool) secret-tool lookup service saml2aws-setup environment "$env" 2>/dev/null || true ;;
  esac
}

password_save() {
  local env=$1 password=$2 blob
  case $(password_backend) in
    dpapi)
      blob=$(printf '%s\n' "$password" | ps_run '$s=[Console]::In.ReadLine(); ConvertTo-SecureString $s -AsPlainText -Force | ConvertFrom-SecureString') || return 0
      [[ -n $blob ]] || return 0
      mkdir -p "$PASSWORD_DIR" && chmod 700 "$STATE_DIR" "$PASSWORD_DIR"
      (umask 077; printf '%s\n' "$blob" >"$PASSWORD_DIR/$env.dpapi")
      say "Saved your $env password (encrypted so only your Windows login can read it)." ;;
    secret-tool)
      printf '%s' "$password" | secret-tool store --label "saml2aws $env" service saml2aws-setup environment "$env" 2>/dev/null &&
        say "Saved your $env password in the desktop keyring." ;;
  esac
  return 0
}

password_forget() {
  rm -f "$PASSWORD_DIR/$1.dpapi"
  if command -v secret-tool >/dev/null; then
    secret-tool clear service saml2aws-setup environment "$1" 2>/dev/null || true
  fi
}

# ---- login --------------------------------------------------------------------

saml_login() {
  SAML2AWS_PASSWORD=$2 SAML2AWS_OKTA_DISABLE_SESSIONS=true saml2aws login --skip-prompt \
    --config "$SAML_CONFIG" --idp-account "$1" --profile "$1" \
    --username "$(ini_get "$1" username)" >&2
}

# login ENV: sign in with the saved password, asking (and saving) only when needed.
login() {
  local env=$1 password saved
  ensure_env "$env"
  saved=$(password_load "$env")
  password=$saved
  if [[ -z $password ]]; then
    have_tty || die "No saved password for $env; run this in a terminal once."
    read -r -s -p "Okta password for $(ini_get "$env" username): " password </dev/tty; say ""
  fi
  say "Signing in to $env. Approve the Okta Verify prompt on your phone if asked."
  if ! saml_login "$env" "$password"; then
    have_tty || die "Sign-in to $env failed."
    say ""
    say "Sign-in failed. If your password changed, type the new one; press Enter to stop."
    read -r -s -p "Okta password: " password </dev/tty; say ""
    [[ -n $password ]] || exit 1
    saml_login "$env" "$password" || die "Sign-in to $env failed again."
  fi
  [[ $password == "$saved" ]] || password_save "$env" "$password"
  aws sts get-caller-identity --profile "$env" --region "$REGION" --no-cli-pager >/dev/null
}
