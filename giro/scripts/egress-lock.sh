#!/usr/bin/env bash
# Container egress for the self-pentest box.
#
# The admin panel is reachable only from the Twingate connectors, at the load
# balancer. This script is the other half: traffic from the containers may
# leave the instance only toward the production names in giro/egress/targets.txt,
# plus the model APIs in giro/egress/platform.txt, and only on tcp/80 and
# tcp/443. Private addresses, link-local, the VPC, and staging are never added.
#
# Host traffic is not filtered, so the image build and Session Manager keep
# working. --unlock opens container egress for the duration of a rebuild.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
targets_file="${root}/giro/egress/targets.txt"
platform_file="${root}/giro/egress/platform.txt"

production_name() {
  case "$1" in
    "" | *[!a-z0-9.-]* | .* | *. | *..*) return 1 ;;
    staging.girocredito.com | *.staging.girocredito.com) return 1 ;;
    artex.girocredito.com) return 1 ;;
    girocredito.com | *.girocredito.com) return 0 ;;
  esac
  return 1
}

platform_name() {
  case "$1" in
    api.anthropic.com | api.openai.com | openrouter.ai) return 0 ;;
  esac
  return 1
}

public_ipv4() {
  local a b c d
  [[ "$1" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
  a="${BASH_REMATCH[1]}"
  b="${BASH_REMATCH[2]}"
  c="${BASH_REMATCH[3]}"
  d="${BASH_REMATCH[4]}"
  if ((a > 255 || b > 255 || c > 255 || d > 255)); then return 1; fi
  if ((a == 0 || a == 10 || a == 127)); then return 1; fi
  if ((a == 169 && b == 254)); then return 1; fi
  if ((a == 172 && b >= 16 && b <= 31)); then return 1; fi
  if ((a == 192 && b == 168)); then return 1; fi
  if ((a == 100 && b >= 64 && b <= 127)); then return 1; fi
  return 0
}

read_names() {
  local file="$1" kind="$2" line
  if [[ ! -f "$file" ]]; then
    echo "Missing ${file}." >&2
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [[ -z "$line" ]] && continue
    if [[ "$kind" == target ]]; then
      if ! production_name "$line"; then
        echo "Rejected target name: ${line}" >&2
        return 1
      fi
    elif ! platform_name "$line"; then
      echo "Rejected platform name: ${line}" >&2
      return 1
    fi
    printf '%s\n' "$line"
  done <"$file"
}

expect_reject() {
  if "$1" "$2"; then
    echo "Accepted ${2}, which must be rejected." >&2
    return 1
  fi
}

self_test() {
  production_name "app.girocredito.com"
  production_name "girocredito.com"
  expect_reject production_name "staging.girocredito.com"
  expect_reject production_name "api.staging.girocredito.com"
  expect_reject production_name "artex.girocredito.com"
  expect_reject production_name "example.com"
  platform_name "api.anthropic.com"
  platform_name "api.openai.com"
  platform_name "openrouter.ai"
  expect_reject platform_name "example.com"
  public_ipv4 "203.0.113.10"
  expect_reject public_ipv4 "10.0.1.5"
  expect_reject public_ipv4 "169.254.169.254"
  expect_reject public_ipv4 "172.16.0.5"
  read_names "$targets_file" target >/dev/null
  read_names "$platform_file" platform >/dev/null
  echo "Egress name checks passed."
}

external_interface() {
  ip route show default | awk '{print $5; exit}'
}

resolve_public() {
  local name="$1" ip
  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    if public_ipv4 "$ip"; then
      printf '%s\n' "$ip"
    else
      echo "Ignoring non-public address ${ip} for ${name}." >&2
    fi
  done < <(getent ahostsv4 "$name" | awk '{print $1}' | sort -u)
}

write_rules() {
  local ext="$1" mode="$2"
  shift 2
  local ip seen=" "
  {
    echo "*filter"
    echo ":DOCKER-USER - [0:0]"
    echo "-A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN"
    # Docker's resolver at 127.0.0.11 forwards the lookup to the host's
    # nameserver, and that packet leaves on the default interface. Without
    # this, every name in the allowlist fails closed. Public resolvers are
    # not added.
    local ns
    while IFS= read -r ns; do
      [[ -z "$ns" || "$ns" == "127."* ]] && continue
      if public_ipv4 "$ns"; then
        continue
      fi
      echo "-A DOCKER-USER -o ${ext} -p udp -d ${ns} --dport 53 -j RETURN"
      echo "-A DOCKER-USER -o ${ext} -p tcp -d ${ns} --dport 53 -j RETURN"
    done < <(awk '/^nameserver[[:space:]]+/ {print $2}' /etc/resolv.conf)
    if [[ "$mode" == allow ]]; then
      for ip in "$@"; do
        [[ "$seen" == *" ${ip} "* ]] && continue
        seen+="${ip} "
        echo "-A DOCKER-USER -o ${ext} -p tcp -m multiport --dports 80,443 -d ${ip} -j RETURN"
      done
    fi
    echo "-A DOCKER-USER -o ${ext} -j DROP"
    echo "-A DOCKER-USER -j RETURN"
    echo "COMMIT"
  } | iptables-restore --noflush
}

apply_rules() {
  local ext ips=() name ip
  ext="$(external_interface)"
  if [[ -z "$ext" ]]; then
    echo "No default route." >&2
    return 1
  fi
  local names=""
  names="$(read_names "$targets_file" target)" || return 1
  names+=$'\n'"$(read_names "$platform_file" platform)" || return 1
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    while IFS= read -r ip; do
      [[ -n "$ip" ]] && ips+=("$ip")
    done < <(resolve_public "$name")
  done <<<"$names"

  if ((${#ips[@]} == 0)); then
    write_rules "$ext" seal
    echo "No public addresses resolved. Container egress is sealed on ${ext}." >&2
    return 1
  fi
  write_rules "$ext" allow "${ips[@]}"
  echo "Container egress allows ${#ips[@]} address(es) via ${ext}."
}

install_timer() {
  [[ -d /etc/systemd/system ]] || return 0
  if [[ -f /etc/systemd/system/artex-egress.timer ]]; then
    systemctl enable --now artex-egress.timer
    return 0
  fi
  cat >/etc/systemd/system/artex-egress.service <<'UNIT'
[Unit]
Description=Refresh Giro ARTEX container egress allowlist
After=docker.service

[Service]
Type=oneshot
ExecStart=/opt/artex/giro/scripts/egress-lock.sh
UNIT
  cat >/etc/systemd/system/artex-egress.timer <<'UNIT'
[Unit]
Description=Refresh Giro ARTEX container egress allowlist

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now artex-egress.timer
}

case "${1:-}" in
  --check)
    read_names "$targets_file" target >/dev/null
    read_names "$platform_file" platform >/dev/null
    echo "Egress allowlists are valid."
    ;;
  --self-test)
    self_test
    ;;
  --unlock)
    systemctl stop artex-egress.timer 2>/dev/null || true
    if iptables -S DOCKER-USER >/dev/null 2>&1; then
      iptables -F DOCKER-USER
    else
      iptables -N DOCKER-USER
    fi
    iptables -A DOCKER-USER -j RETURN
    echo "Container egress unlocked for the image build."
    ;;
  "")
    apply_rules
    install_timer
    ;;
  *)
    echo "Usage: egress-lock.sh [--check|--self-test|--unlock]" >&2
    exit 2
    ;;
esac
