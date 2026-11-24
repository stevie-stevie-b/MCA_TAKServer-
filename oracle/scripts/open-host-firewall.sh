#!/bin/bash
# Oracle's Ubuntu images ship a host firewall (/etc/iptables/rules.v4) that rejects
# everything except SSH, even when the cloud security list allows it.
# This opens the TAK ports in that file and in the running firewall.
set -euo pipefail

# shellcheck disable=SC1091
[ -f /etc/tak-deploy.env ] && . /etc/tak-deploy.env

PORTS=(8089 8443)
if [ "${OPEN_ENROLMENT_PORT:-false}" = "true" ]; then
  PORTS+=(8446)
fi

RULES=/etc/iptables/rules.v4
SSH_RULE='-A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT'

for port in "${PORTS[@]}"; do
  rule="-A INPUT -p tcp -m state --state NEW -m tcp --dport ${port} -j ACCEPT"

  # Persisted rules: insert straight after the SSH rule so they sit above the REJECT.
  if [ -f "$RULES" ] && ! grep -qF -- "$rule" "$RULES"; then
    if grep -qF -- "$SSH_RULE" "$RULES"; then
      sed -i "\|${SSH_RULE}|a ${rule}" "$RULES"
    else
      echo "WARNING: SSH rule not found in $RULES; add port ${port} by hand." >&2
    fi
  fi

  # Running firewall.
  if ! iptables -C INPUT -p tcp -m state --state NEW -m tcp --dport "$port" -j ACCEPT 2>/dev/null; then
    iptables -I INPUT -p tcp -m state --state NEW -m tcp --dport "$port" -j ACCEPT
  fi
done

echo "Host firewall open for TCP ${PORTS[*]}."
