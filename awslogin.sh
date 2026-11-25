#!/usr/bin/env bash
# Sign in to AWS through Okta for one environment and refresh that AWS CLI profile.
# Usage: awslogin.sh [ENVIRONMENT]   (no argument: choose from a menu)
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"
require_tools saml2aws aws

env=$(choose_env "${1:-}")
login "$env"

arn=$(aws sts get-caller-identity --profile "$env" --region "$REGION" --no-cli-pager --query Arn --output text)
expires=$(aws configure get x_security_token_expires --profile "$env" 2>/dev/null || true)
say ""
say "Signed in to $env as ${arn##*/}."
[[ -n $expires ]] && say "Valid until $expires."
say "Use it with:  aws --profile $env ...   or   export AWS_PROFILE=$env"
