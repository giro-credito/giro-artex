#!/usr/bin/env bash
# Create or update stack giro-artex, then publish the source tree and build the image.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
region="us-east-2"
stack="giro-artex"
expected_account="920373016063"

if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  unset AWS_PROFILE
else
  export AWS_PROFILE="${AWS_PROFILE:-giro-admin}"
fi
export AWS_REGION="$region"

account="$(aws sts get-caller-identity --query Account --output text)"
if [[ "$account" != "$expected_account" ]]; then
  echo "Refusing to deploy. Expected account ${expected_account}, got ${account}." >&2
  exit 1
fi

overrides=()
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ -z "$line" ]] && continue
  overrides+=("$line")
done <"${repo}/giro/parameters/prod.parameters"

echo "Deploying stack ${stack} in ${account}."

deploy_args=(
  --region "$region"
  --stack-name "$stack"
  --template-file "${repo}/giro/cloudformation/artex.yml"
  --parameter-overrides "${overrides[@]}"
  --capabilities CAPABILITY_IAM
  --no-fail-on-empty-changeset
  --tags Project=giro-artex ManagedBy=cloudformation
)
if [[ -n "${CFN_EXEC_ROLE_ARN:-}" ]]; then
  deploy_args+=(--role-arn "$CFN_EXEC_ROLE_ARN")
fi

aws cloudformation deploy "${deploy_args[@]}"

aws cloudformation update-termination-protection \
  --region "$region" \
  --stack-name "$stack" \
  --enable-termination-protection

bash "${repo}/giro/scripts/publish.sh"
