#!/usr/bin/env bash
# Install saml2aws and the AWS CLI, set up your Okta environments, and add Desktop shortcuts.
# Usage: ./install.sh [--team FILE] [ENVIRONMENT...]   (default: the team file's, else dev mgmt prod)
#   --team FILE      shared Okta links and database hosts (default: saml2aws-team.conf here or in Downloads)
#   --no-shortcuts   skip the Windows Desktop shortcuts
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"

shortcuts=yes
team=
envs=()
while (($#)); do
  case $1 in
    --no-shortcuts) shortcuts=no ;;
    --team) [[ -n ${2:-} ]] || die "--team needs a file"; team=$2; shift ;;
    --team=*) team=${1#*=} ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) valid_env_name "$1" || die "Not an environment name: $1"; envs+=("$1") ;;
  esac
  shift
done

[[ $(uname -s) == Linux ]] || die "This installer supports Linux and WSL only."
[[ $EUID -ne 0 ]] || die "Run as your normal user, not with sudo; the settings are per user."
case "$(uname -m)" in
  x86_64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) die "Unsupported CPU architecture: $(uname -m)" ;;
esac

# ---- tools -------------------------------------------------------------------
packages=()
command -v curl >/dev/null || packages+=(curl ca-certificates)
command -v tar >/dev/null || packages+=(tar)
command -v sha256sum >/dev/null || packages+=(coreutils)
command -v aws >/dev/null || packages+=(awscli)
if ((${#packages[@]})); then
  if ! command -v apt-get >/dev/null || ! command -v sudo >/dev/null; then
    die "Install these with your package manager, then rerun: ${packages[*]}"
  fi
  say "Installing ${packages[*]} (you may be asked for your Linux password)..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq "${packages[@]}"
fi

if ! command -v saml2aws >/dev/null; then
  tmp_dir=$(mktemp -d)
  trap 'rm -rf -- "$tmp_dir"' EXIT
  release_url=$(curl --fail --silent --show-error --location --output /dev/null \
    --write-out '%{url_effective}' https://github.com/Versent/saml2aws/releases/latest)
  version=${release_url##*/v}
  [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Unable to determine the latest saml2aws version."
  archive="saml2aws_${version}_linux_${arch}.tar.gz"
  base="https://github.com/Versent/saml2aws/releases/download/v${version}"
  say "Downloading saml2aws $version..."
  curl --fail --silent --show-error --location "$base/$archive" --output "$tmp_dir/$archive"
  curl --fail --silent --show-error --location "$base/saml2aws_${version}_checksums.txt" --output "$tmp_dir/checksums.txt"
  (
    cd "$tmp_dir"
    awk -v file="$archive" '$2 == file { print }' checksums.txt >selected.txt
    [[ -s selected.txt ]] || die "No checksum published for $archive."
    sha256sum --check --quiet selected.txt
    tar -xzf "$archive" saml2aws
  )
  mkdir -p "$HOME/.local/bin"
  install -m 755 "$tmp_dir/saml2aws" "$HOME/.local/bin/saml2aws"
fi
say "$(aws --version 2>&1 | cut -d' ' -f1), saml2aws $(saml2aws --version 2>&1)"

# ---- scripts -----------------------------------------------------------------
app=$HOME/.local/share/saml2aws-setup
if [[ $here != "$app" ]]; then
  mkdir -p "$app/lib"
  install -m 755 "$here/awslogin.sh" "$here/samllogin.sh" "$app/"
  install -m 644 "$here/lib/common.sh" "$app/lib/"
fi
mkdir -p "$HOME/.local/bin"
ln -sfn "$app/awslogin.sh" "$HOME/.local/bin/awslogin.sh"
ln -sfn "$app/samllogin.sh" "$HOME/.local/bin/samllogin.sh"
# Also link them in your home folder, so ~/awslogin.sh works without the clone.
for script in awslogin.sh samllogin.sh; do
  if [[ -e $HOME/$script && ! -L $HOME/$script ]]; then
    say "Left your existing ~/$script alone (not a link)."
  else
    ln -sfn "$app/$script" "$HOME/$script"
  fi
done
say "Installed awslogin.sh and samllogin.sh (in ~ and ~/.local/bin). You can delete the downloaded folder."

# ---- team defaults -------------------------------------------------------------
if [[ -z $team ]]; then
  downloads=
  # shellcheck disable=SC2016  # PowerShell variable
  if profile=$(ps_run '$env:USERPROFILE' </dev/null 2>/dev/null) && [[ -n $profile ]]; then
    downloads=$(wslpath -u "$profile\\Downloads" 2>/dev/null || true)
  fi
  for candidate in "$here/$TEAM_FILE_NAME" ${downloads:+"$downloads/$TEAM_FILE_NAME"}; do
    [[ -f $candidate ]] && { team=$candidate; break; }
  done
fi
if [[ -n $team ]]; then
  [[ -f $team ]] || die "Team file not found: $team"
  [[ -n $(ini_sections "$team") ]] || die "No [environment] sections in $team"
  mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
  if [[ $(readlink -f "$team") != $(readlink -f "$TEAM_FILE" 2>/dev/null) ]]; then
    install -m 600 "$team" "$TEAM_FILE"
  fi
  say "Using team settings from $team."
fi
((${#envs[@]})) || mapfile -t envs < <(ini_sections "$TEAM_FILE")
((${#envs[@]})) || read -r -a envs <<<"$DEFAULT_ENVIRONMENTS"

# ---- environments ------------------------------------------------------------
say ""
say "Set up your environments."
for env in "${envs[@]}"; do
  if [[ -n $(ini_get "$env" url) && -n $(ini_get "$env" username) ]]; then
    say "  $env: already set up."
    continue
  fi
  have_tty || { say "  $env: skipped (no terminal)."; continue; }
  read -r -p "Set up \"$env\" now? [Y/n] " yn </dev/tty
  [[ ${yn,,} == n* ]] && { say "  $env: skipped; it will be offered the first time you use it."; continue; }
  ensure_env "$env"
done

# ---- Windows Desktop shortcuts -------------------------------------------------
if [[ $shortcuts == yes && -n ${WSL_DISTRO_NAME:-} ]] && powershell_exe >/dev/null; then
  desktop_win=$(ps_run '[Environment]::GetFolderPath("Desktop")' </dev/null)
  desktop=$(wslpath -u "$desktop_win" 2>/dev/null || true)
  if [[ -n ${SAMLLOGIN_DESKTOP:-} ]]; then desktop=$SAMLLOGIN_DESKTOP desktop_win=$SAMLLOGIN_DESKTOP; fi
  if [[ -d $desktop ]]; then
    write_cmd() {
      printf '@echo off\r\ntitle %s\r\nwsl.exe -d %s --cd ~ -- %s\r\npause\r\n' \
        "$1" "$WSL_DISTRO_NAME" "$2" >"$desktop/$1.cmd"
    }
    write_cmd "AWS Login" "$app/awslogin.sh"
    write_cmd "AWS Database Password" "$app/samllogin.sh"
    say ""
    say "Added \"AWS Login\" and \"AWS Database Password\" to your Desktop ($desktop_win)."
  fi
fi

say ""
say "Done. Double-click \"AWS Login\" on your Desktop, or run: awslogin.sh <environment>"
