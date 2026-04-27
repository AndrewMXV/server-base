#!/bin/bash
set -euo pipefail

DNS_CONF="/etc/systemd/resolved.conf.d/docker.conf"
DAEMON_JSON="/etc/docker/daemon.json"
TMP_JSON="/tmp/daemon.json.tmp"
TMP_CONF="/tmp/docker.conf.tmp"
RESOLVED_DIR="/etc/systemd/resolved.conf.d"
DOCKER_DIR="/etc/docker"

HAS_SYSTEMCTL=0
HAS_RESOLVED_UNIT=0
HAS_DOCKER_UNIT=0
if command -v systemctl >/dev/null 2>&1; then
  HAS_SYSTEMCTL=1
  if [ "$(systemctl show -p LoadState --value systemd-resolved.service 2>/dev/null || true)" != "not-found" ]; then
    HAS_RESOLVED_UNIT=1
  fi
  if [ "$(systemctl show -p LoadState --value docker.service 2>/dev/null || true)" != "not-found" ]; then
    HAS_DOCKER_UNIT=1
  fi
fi

desired_conf='[Resolve]
DNSStubListenerExtra=172.17.0.1
'

changed=0
docker_changed=0

if [ "$HAS_RESOLVED_UNIT" -eq 1 ]; then
  mkdir -p "$RESOLVED_DIR"
  printf "%s\n" "$desired_conf" > "$TMP_CONF"
  if ! [ -f "$DNS_CONF" ] || ! cmp -s "$DNS_CONF" "$TMP_CONF"; then
    echo "Updating $DNS_CONF"
    mv "$TMP_CONF" "$DNS_CONF"
    changed=1
  else
    rm -f "$TMP_CONF"
    echo "$DNS_CONF is already up to date."
  fi
else
  echo "systemd-resolved.service not found; skipping resolved.conf update."
fi

mkdir -p "$DOCKER_DIR"
if ! [ -s "$DAEMON_JSON" ]; then
  echo "{}" > "$DAEMON_JSON"
elif ! jq -e . "$DAEMON_JSON" >/dev/null 2>&1; then
  echo "Invalid JSON in $DAEMON_JSON; resetting to {}"
  echo "{}" > "$DAEMON_JSON"
fi

jq '. + {"dns": ["172.17.0.1"], "dns-search": ["."], "dns-opts": ["ndots:0"]} | del(.icc)' \
  "$DAEMON_JSON" > "$TMP_JSON"
if ! cmp -s "$DAEMON_JSON" "$TMP_JSON"; then
  mv "$TMP_JSON" "$DAEMON_JSON"
  echo "Updating $DAEMON_JSON"
  changed=1
  docker_changed=1
else
  rm -f "$TMP_JSON"
  echo "$DAEMON_JSON is already up to date."
fi

DISTRO=unknown
if [ -f /etc/os-release ]; then
  . /etc/os-release
  DISTRO="${ID:-unknown}"
fi

if [ "$DISTRO" = "redos" ] && [ "$HAS_RESOLVED_UNIT" -eq 1 ]; then
  RESOLV_STUB="/run/systemd/resolve/stub-resolv.conf"
  if [ ! -e "$RESOLV_STUB" ]; then
    echo "systemd-resolved stub file not found at $RESOLV_STUB; skipping /etc/resolv.conf update."
  else
    current_resolv="$(readlink -f /etc/resolv.conf 2>/dev/null || true)"
    expected_resolv="$(readlink -f "$RESOLV_STUB" 2>/dev/null || echo "$RESOLV_STUB")"
    if [ -L /etc/resolv.conf ] && [ "$current_resolv" = "$expected_resolv" ]; then
      echo "/etc/resolv.conf already points to systemd-resolved stub."
    else
      echo "Updating /etc/resolv.conf to use systemd-resolved stub."
      rm -f /etc/resolv.conf
      ln -s "$RESOLV_STUB" /etc/resolv.conf
      changed=1
    fi
  fi
fi

enable_failed=0
if [ "$HAS_RESOLVED_UNIT" -eq 1 ]; then
  if ! systemctl enable --now systemd-resolved; then
    enable_failed=1
  fi
  if ! systemctl is-active --quiet systemd-resolved; then
    if [ "$DISTRO" != "ubuntu" ]; then
      if command -v ausearch >/dev/null 2>&1 && command -v audit2allow >/dev/null 2>&1; then
        sleep 2
        avc_tmp="/tmp/avc.systemd-resolve.$$"
        ausearch -m avc -ts recent 2>/dev/null | grep -E 'systemd-resolve(d)?' > "$avc_tmp" || true
        if ! grep -q . "$avc_tmp"; then
          ausearch -m avc -ts today 2>/dev/null | grep -E 'systemd-resolve(d)?' > "$avc_tmp" || true
        fi
        if ! grep -q . "$avc_tmp" && [ -f /var/log/audit/audit.log ]; then
          grep -E 'avc:  denied' /var/log/audit/audit.log | grep -E 'systemd-resolve(d)?' > "$avc_tmp" || true
        fi
        if ! grep -q . "$avc_tmp" && command -v journalctl >/dev/null 2>&1; then
          journalctl -t audit --since "5 minutes ago" --no-pager 2>/dev/null | grep -E 'systemd-resolve(d)?' > "$avc_tmp" || true
        fi
        if grep -q . "$avc_tmp"; then
          echo "SELinux AVC detected for systemd-resolve; generating local policy."
          audit2allow -M local-systemd-resolved < "$avc_tmp"
          semodule -i local-systemd-resolved.pp
          systemctl reset-failed systemd-resolved || true
          if ! systemctl enable --now systemd-resolved; then
            enable_failed=1
          else
            enable_failed=0
          fi
        else
          echo "No SELinux AVC entries found for systemd-resolve."
        fi
        rm -f "$avc_tmp"
      fi
    fi
  fi
else
  echo "systemd-resolved.service not found; skipping systemd-resolved activation checks."
fi

if [ "$HAS_RESOLVED_UNIT" -eq 1 ] && ! systemctl is-active --quiet systemd-resolved; then
  echo "systemd-resolved is not active; aborting."
  systemctl status systemd-resolved --no-pager || true
  journalctl -u systemd-resolved --no-pager -n 50 || true
  exit 1
fi
if [ "$HAS_RESOLVED_UNIT" -eq 1 ] && [ "$enable_failed" -ne 0 ]; then
  echo "systemd-resolved start command failed; aborting."
  systemctl status systemd-resolved --no-pager || true
  journalctl -u systemd-resolved --no-pager -n 50 || true
  exit 1
fi

dump_docker_logs() {
  echo "Failed to restart docker.service; dumping status/logs."
  systemctl status docker --no-pager || true
  journalctl -u docker --no-pager -n 80 || true
}

restart_docker_with_recovery() {
  if systemctl restart docker; then
    return 0
  fi

  result="$(systemctl show -p Result --value docker.service 2>/dev/null || true)"
  if [ "$result" = "start-limit-hit" ]; then
    echo "docker.service hit systemd start limit; resetting and retrying once."
    systemctl reset-failed docker.service docker.socket || true
    sleep 2
    systemctl start docker || true
  fi

  systemctl is-active --quiet docker && return 0
  dump_docker_logs
  return 1
}

if [ "$changed" = "1" ]; then
  echo "Configuration changed, restarting services..."
  if [ "$HAS_RESOLVED_UNIT" -eq 1 ]; then
    systemctl restart systemd-resolved
  fi
  if [ "$HAS_SYSTEMCTL" -eq 1 ] && [ "$HAS_DOCKER_UNIT" -eq 1 ]; then
    if [ "$docker_changed" = "1" ]; then
      if [ "$(systemctl is-enabled docker.service 2>/dev/null || true)" = "masked" ]; then
        echo "docker.service is masked; unmasking docker.service and docker.socket"
        systemctl unmask docker.service docker.socket || true
        systemctl daemon-reload || true
      fi
      restart_docker_with_recovery || exit 1
    else
      echo "$DAEMON_JSON unchanged; skipping docker restart."
    fi
  else
    echo "docker.service not found or systemctl unavailable; skipping docker restart."
  fi
else
  echo "No configuration changes detected, skipping service restarts."
fi
