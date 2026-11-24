#!/bin/bash
# Deploys the TAK Server stack from OCI Cloud Shell (Sydney).
#
#   unzip -o tak-oracle-stack.zip -d tak-stack && bash tak-stack/cloudshell-deploy.sh
#
# Safe to re-run: it reuses the compartment, stack and SSH key it made last time,
# so after an "Out of host capacity" failure just run it again later.
#
# Optional overrides: CERT_STATE, CERT_CITY, CERT_ORG, CERT_ORG_UNIT, SERVER_HOSTNAME,
#                     COMPARTMENT_NAME (default tak), STACK_NAME (default tak-server)
#                     OCPUS / MEMORY_GB (default 4 / 24; 2 / 12 is often easier to get)
#                     RETRIES (default 1) and RETRY_MINUTES (default 5): keep retrying
#                     the build while Oracle reports "Out of host capacity"
set -euo pipefail
OCPUS=${OCPUS:-4}
MEMORY_GB=${MEMORY_GB:-24}
RETRIES=${RETRIES:-1}
RETRY_MINUTES=${RETRY_MINUTES:-5}

REGION=ap-sydney-1
COMPARTMENT_NAME=${COMPARTMENT_NAME:-tak}
STACK_NAME=${STACK_NAME:-tak-server}
INSTANCE_NAME=tak-server
KEY=~/.ssh/tak_server
HERE=$(cd "$(dirname "$0")" && pwd)
R=(--region "$REGION")
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

say() { echo; echo "== $*"; }
die() { echo; echo "STOPPED: $*" >&2; exit 1; }
is_ip() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; }
job_logs() { oci resource-manager job get-job-logs-content "${R[@]}" --job-id "$1" --query data --raw-output 2>/dev/null; }

# --- Account checks ----------------------------------------------------------
say "Checking your Oracle account"
HOME_REGION=$(oci iam region-subscription list --query 'data[?"is-home-region"] | [0]."region-name"' --raw-output)
[ "$HOME_REGION" = "$REGION" ] || die "Your home region is $HOME_REGION, not $REGION. Always Free servers only run in the home region."
TENANCY=${OCI_TENANCY:-}
[[ "$TENANCY" == ocid1.tenancy* ]] || TENANCY=$(oci iam compartment list --include-root --all \
  --query 'data[?starts_with(id, `ocid1.tenancy`)] | [0].id' --raw-output)
[[ "$TENANCY" == ocid1.tenancy* ]] || die "Could not find your tenancy ID."
echo "Home region $HOME_REGION, tenancy found."

# --- Compartment -------------------------------------------------------------
say "Compartment '$COMPARTMENT_NAME'"
COMP=$(oci iam compartment list --compartment-id "$TENANCY" --lifecycle-state ACTIVE --all \
         --query "data[?name=='$COMPARTMENT_NAME'] | [0].id" --raw-output 2>/dev/null || true)
if [[ "$COMP" != ocid1.compartment* ]]; then
  COMP=$(oci iam compartment create --compartment-id "$TENANCY" --name "$COMPARTMENT_NAME" \
           --description "TAK Server" --wait-for-state ACTIVE --query 'data.id' --raw-output)
  echo "Created. Waiting a minute for it to be usable everywhere..."
  sleep 60
else
  echo "Using existing compartment."
fi

# --- SSH key (kept in Cloud Shell's home folder) -----------------------------
[ -f "$KEY" ] || ssh-keygen -q -t rsa -b 4096 -N "" -f "$KEY" -C tak-server  # RSA: Cloud Shell runs in FIPS mode (no ed25519)
echo "SSH key: $KEY"

# --- Inputs ------------------------------------------------------------------
say "A few questions"
SHELL_IP=$(curl -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]' || true)
is_ip "$SHELL_IP" || die "Could not work out Cloud Shell's public IP."
echo "Cloud Shell's IP is $SHELL_IP (allowed for SSH so this script can watch the install)."

read -rp "Your computer's public IP (search 'what is my IP' in your browser): " MY_IP
MY_IP=$(echo "$MY_IP" | tr -d '[:space:]')
is_ip "$MY_IP" || die "'$MY_IP' doesn't look like an IPv4 address."

ADMIN_CIDR="$MY_IP/32"
[ "$MY_IP" = "$SHELL_IP" ] || ADMIN_CIDR="$ADMIN_CIDR,$SHELL_IP/32"

read -rsp "Paste the pre-authenticated request URL for the TAK zip (hidden; Enter to skip): " PAR; echo
PAR=$(echo "$PAR" | tr -d '[:space:]')
[ -z "$PAR" ] || [[ "$PAR" == https://* ]] || die "That URL should start with https://"
if [ -n "$PAR" ]; then
  echo "Download link received (${#PAR} characters, ends ...${PAR: -24})."
else
  echo "No download link given: the server will build, but you'll copy the TAK zip up by hand (README step 5)."
fi

TF_SSH_KEY=$(cat "$KEY.pub")
export TF_TENANCY="$TENANCY" TF_COMP="$COMP" TF_SSH_KEY TF_ADMIN_CIDR="$ADMIN_CIDR" TF_PAR="$PAR"
python3 - > "$WORK/vars.json" <<'EOF'
import json, os
v = {
  "region": "ap-sydney-1",
  "tenancy_ocid": os.environ["TF_TENANCY"],
  "compartment_ocid": os.environ["TF_COMP"],
  "ssh_public_key": os.environ["TF_SSH_KEY"],
  "admin_cidr": os.environ["TF_ADMIN_CIDR"],
  "tak_zip_url": os.environ["TF_PAR"],
  "server_hostname": os.environ.get("SERVER_HOSTNAME", ""),
  "cert_state": os.environ.get("CERT_STATE", "NSW"),
  "cert_city": os.environ.get("CERT_CITY", "Newcastle"),
  "cert_org": os.environ.get("CERT_ORG", "TAK"),
  "cert_org_unit": os.environ.get("CERT_ORG_UNIT", "TAK"),
  "ocpus": os.environ.get("OCPUS", "4"),
  "memory_gb": os.environ.get("MEMORY_GB", "24"),
}
print(json.dumps(v))
EOF
echo "Admin access (SSH + 8443) from: $ADMIN_CIDR"
echo "Certificates: ${CERT_STATE:-NSW} / ${CERT_CITY:-Newcastle} / ${CERT_ORG:-TAK}"
echo "Server size: $OCPUS OCPU, $MEMORY_GB GB RAM"
export OCPUS MEMORY_GB

# --- Stack -------------------------------------------------------------------
say "Resource Manager stack '$STACK_NAME'"
python3 -c "import shutil,sys; shutil.make_archive(sys.argv[1], 'zip', sys.argv[2])" "$WORK/stack" "$HERE"
STACK=$(oci resource-manager stack list "${R[@]}" --compartment-id "$COMP" --lifecycle-state ACTIVE --all \
          --query "data[?\"display-name\"=='$STACK_NAME'] | [0].id" --raw-output 2>/dev/null || true)
if [[ "$STACK" == ocid1.ormstack* ]]; then
  oci resource-manager stack update "${R[@]}" --stack-id "$STACK" --config-source "$WORK/stack.zip" \
    --variables "file://$WORK/vars.json" --force >/dev/null
  echo "Updated existing stack."
else
  STACK=$(oci resource-manager stack create "${R[@]}" --compartment-id "$COMP" --display-name "$STACK_NAME" \
            --description "TAK Server on Always Free A1" --config-source "$WORK/stack.zip" \
            --variables "file://$WORK/vars.json" --terraform-version "1.5.x" --query 'data.id' --raw-output)
  echo "Created stack."
fi

# --- Plan --------------------------------------------------------------------
say "Plan (checks the configuration; about 1-2 minutes)"
PLAN=$(oci resource-manager job create-plan-job "${R[@]}" --stack-id "$STACK" --display-name "plan-$(date +%Y%m%d-%H%M)" \
         --wait-for-state SUCCEEDED --wait-for-state FAILED --max-wait-seconds 1800 --query 'data.id' --raw-output)
STATE=$(oci resource-manager job get "${R[@]}" --job-id "$PLAN" --query 'data."lifecycle-state"' --raw-output)
if [ "$STATE" != "SUCCEEDED" ]; then
  job_logs "$PLAN" | tail -n 40
  die "Plan $STATE. Copy the lines above to Claude."
fi
job_logs "$PLAN" | grep -E 'Plan:|No changes' | tail -n 1 || true

read -rp "Build it now? [y/N] " GO
[[ "$GO" =~ ^[Yy] ]] || die "Not applied. Re-run this script when ready."

# --- Apply -------------------------------------------------------------------
say "Apply (builds the network and server; about 2-5 minutes)"
attempt=1
while :; do
  APPLY=$(oci resource-manager job create-apply-job "${R[@]}" --stack-id "$STACK" --execution-plan-strategy AUTO_APPROVED \
            --display-name "apply-$(date +%Y%m%d-%H%M)" \
            --wait-for-state SUCCEEDED --wait-for-state FAILED --max-wait-seconds 3600 --query 'data.id' --raw-output)
  STATE=$(oci resource-manager job get "${R[@]}" --job-id "$APPLY" --query 'data."lifecycle-state"' --raw-output)
  [ "$STATE" = "SUCCEEDED" ] && break
  LOGS=$(job_logs "$APPLY")
  if echo "$LOGS" | grep -qi 'out of host capacity'; then
    if [ "$attempt" -lt "$RETRIES" ]; then
      echo "$(date '+%H:%M') attempt $attempt/$RETRIES: no free ARM capacity in Sydney. Trying again in $RETRY_MINUTES minutes..."
      attempt=$((attempt + 1))
      sleep $((RETRY_MINUTES * 60))
      continue
    fi
    die "Oracle has no free ARM capacity in Sydney right now (tried $attempt time(s)). Run again later, e.g. RETRIES=12 bash $0"
  fi
  echo "$LOGS" | tail -n 40
  die "Apply $STATE. Copy the lines above to Claude."
done

INST=$(oci compute instance list "${R[@]}" --compartment-id "$COMP" --display-name "$INSTANCE_NAME" \
         --lifecycle-state RUNNING --query 'data[0].id' --raw-output)
IP=$(oci compute instance list-vnics "${R[@]}" --instance-id "$INST" --query 'data[0]."public-ip"' --raw-output)
is_ip "$IP" || die "Server built but its public IP wasn't found. Check Compute > Instances in the console."
echo "Server is up at $IP"
cat > ~/tak-info.txt <<EOF
TAK server IP: $IP
SSH:           ssh -i $KEY ubuntu@$IP
Install log:   ssh -i $KEY ubuntu@$IP 'sudo tail -f /var/log/tak-setup.log'
Admin UI:      https://${SERVER_HOSTNAME:-$IP}:8443  (from $MY_IP only)
EOF

# --- Watch the TAK install ---------------------------------------------------
say "Waiting for the TAK install on the server (10-20 minutes)"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes "ubuntu@$IP")
for _ in $(seq 1 30); do "${SSH[@]}" true 2>/dev/null && break; sleep 10; done
"${SSH[@]}" true 2>/dev/null || die "Can't SSH to $IP yet. Re-run later or check Compute > Instances."

last=""
for _ in $(seq 1 90); do
  line=$("${SSH[@]}" "sudo grep -E '^\[|setup complete|No TAK Server zip' /var/log/tak-setup.log 2>/dev/null | tail -n 1" || true)
  if [ -n "$line" ] && [ "$line" != "$last" ]; then echo "$line"; last=$line; fi
  case "$line" in
    *"setup complete"*) break ;;
    *"] ERROR:"*) "${SSH[@]}" "sudo tail -n 30 /var/log/tak-setup.log"; die "TAK install hit an error. Copy the lines above to Claude." ;;
    *"No TAK Server zip"*) die "The server has no TAK zip (no URL given). See README step 5 to copy it up." ;;
  esac
  sleep 20
done
[[ "$last" == *"setup complete"* ]] || die "Still installing after 30 minutes. Watch with: ${SSH[*]} 'sudo tail -f /var/log/tak-setup.log'"

# --- Hand over ---------------------------------------------------------------
scp -q -i "$KEY" -o BatchMode=yes "ubuntu@$IP:tak-certs/admin.p12" ~/tak-admin.p12
CERT_PASS=$("${SSH[@]}" "sudo grep '^CERT_PASS=' /root/tak-secrets.env" | cut -d"'" -f2)

say "Done"
cat <<EOF
TAK Server is running at $IP

1. Download the admin certificate: Cloud Shell menu (gear icon) > Download > tak-admin.p12
2. Import it into your browser / Keychain with this password: $CERT_PASS
   (it's also on the server: sudo cat /root/tak-secrets.env)
3. Open https://${SERVER_HOSTNAME:-$IP}:8443 and accept the certificate warning.
4. Add a phone:  ${SSH[*]} 'sudo /opt/tak-deploy/tak-add-user.sh jsmith'
   then:         scp -i $KEY ubuntu@$IP:tak-certs/jsmith-${SERVER_HOSTNAME:-$IP}.zip ~/
   and download it from the Cloud Shell menu.

Details saved in ~/tak-info.txt. Delete the pre-authenticated request (and the bucket) in the console now.
EOF
