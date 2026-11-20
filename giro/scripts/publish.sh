#!/usr/bin/env bash
# Upload this checkout and rebuild ARTEX on the instance. The first build is long.
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
  echo "Refusing to publish. Expected account ${expected_account}, got ${account}." >&2
  exit 1
fi

output() {
  aws cloudformation describe-stacks \
    --region "$region" \
    --stack-name "$stack" \
    --query "Stacks[0].Outputs[?OutputKey=='${1}'].OutputValue" \
    --output text
}

bucket="$(output ComposeBucketName)"
instance_id="$(output InstanceId)"

aws s3 sync "${repo}/" "s3://${bucket}/source/" \
  --region "$region" \
  --delete \
  --exclude ".git/*" \
  --exclude "data/*" \
  --exclude "keys/*" \
  --exclude ".env" \
  --exclude "web/node_modules/*" \
  --exclude "web/.next/*" \
  --exclude "server/webui/dist/*"

echo "Waiting for SSM on ${instance_id}"
online=0
for _ in $(seq 1 30); do
  status="$(aws ssm describe-instance-information \
    --region "$region" \
    --filters "Key=InstanceIds,Values=${instance_id}" \
    --query "InstanceInformationList[0].PingStatus" \
    --output text 2>/dev/null || true)"
  if [[ "$status" == "Online" ]]; then
    online=1
    break
  fi
  sleep 10
done
if [[ "$online" != 1 ]]; then
  echo "Instance ${instance_id} is not online in Systems Manager." >&2
  exit 1
fi

echo "Waiting for instance bootstrap script"
bootstrapped=0
for _ in $(seq 1 40); do
  probe_id="$(aws ssm send-command \
    --region "$region" \
    --instance-ids "$instance_id" \
    --document-name AWS-RunShellScript \
    --comment "Check Giro ARTEX bootstrap" \
    --timeout-seconds 60 \
    --parameters '{"commands":["test -x /usr/local/bin/artex-bootstrap"]}' \
    --query Command.CommandId \
    --output text)"
  probe_status="Pending"
  for _ in $(seq 1 12); do
    probe_status="$(aws ssm get-command-invocation \
      --region "$region" \
      --command-id "$probe_id" \
      --instance-id "$instance_id" \
      --query Status \
      --output text 2>/dev/null || true)"
    case "$probe_status" in
      Success | Failed | Cancelled | TimedOut | Cancelling) break ;;
    esac
    sleep 5
  done
  if [[ "$probe_status" == "Success" ]]; then
    bootstrapped=1
    break
  fi
  sleep 15
done
if [[ "$bootstrapped" != 1 ]]; then
  echo "Instance ${instance_id} never installed /usr/local/bin/artex-bootstrap." >&2
  exit 1
fi

command_id="$(aws ssm send-command \
  --region "$region" \
  --instance-ids "$instance_id" \
  --document-name AWS-RunShellScript \
  --comment "Publish Giro ARTEX" \
  --timeout-seconds 7200 \
  --parameters '{"commands":["/usr/local/bin/artex-bootstrap"]}' \
  --query Command.CommandId \
  --output text)"

echo "SSM command ${command_id}"
for _ in $(seq 1 480); do
  status="$(aws ssm get-command-invocation \
    --region "$region" \
    --command-id "$command_id" \
    --instance-id "$instance_id" \
    --query Status \
    --output text 2>/dev/null || true)"
  case "$status" in
    Success)
      aws ssm get-command-invocation \
        --region "$region" \
        --command-id "$command_id" \
        --instance-id "$instance_id" \
        --query StandardOutputContent \
        --output text
      echo "ARTEX refresh finished. Site: $(output SiteUrl)"
      exit 0
      ;;
    Failed | Cancelled | TimedOut | Cancelling)
      aws ssm get-command-invocation \
        --region "$region" \
        --command-id "$command_id" \
        --instance-id "$instance_id" \
        --output text
      exit 1
      ;;
  esac
  sleep 15
done

echo "Timed out waiting for SSM command ${command_id}" >&2
exit 1
