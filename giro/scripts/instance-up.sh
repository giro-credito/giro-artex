#!/usr/bin/env bash
# Runs on the instance after artex-bootstrap has synced this tree to /opt/artex.
set -euo pipefail

# shellcheck disable=SC1091
source /etc/artex/bootstrap.env

cd /opt/artex

token="$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")"
bind="$(curl -fsS -H "X-aws-ec2-metadata-token: ${token}" \
  http://169.254.169.254/latest/meta-data/local-ipv4)"
proxies="$(aws ssm get-parameter \
  --name "$TRUSTED_PROXIES_PARAMETER" \
  --query Parameter.Value \
  --output text \
  --region "$REGION")"
db_pass="$(aws secretsmanager get-secret-value \
  --secret-id "$DB_SECRET_ID" \
  --query SecretString \
  --output text \
  --region "$REGION")"

install -d -m 0755 /opt/artex/data
install -d -m 0700 /opt/artex/keys
umask 077
printf 'POSTGRES_PASSWORD=%s\nARTEX_BIND_ADDR=%s\nARTEX_TRUSTED_PROXIES=%s\n' \
  "$db_pass" "$bind" "$proxies" >/opt/artex/.env
chmod 600 /opt/artex/.env
unset db_pass token

# The image build fetches toolchains. Open container egress for that, then
# put the production allowlist back even if the build fails.
bash giro/scripts/egress-lock.sh --unlock || true
trap 'bash giro/scripts/egress-lock.sh || true' EXIT

bash giro/scripts/apply-patches.sh
docker compose -f docker-compose.yml -f giro/docker-compose.aws.yml up -d --build --remove-orphans
docker compose -f docker-compose.yml -f giro/docker-compose.aws.yml ps

bash giro/scripts/egress-lock.sh
trap - EXIT
