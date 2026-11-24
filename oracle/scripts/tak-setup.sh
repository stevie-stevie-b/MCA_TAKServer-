#!/bin/bash
# Builds and starts the official TAK Server Docker release on this machine.
#
# Safe to re-run: it stops at the first missing input and picks up where it left off.
# Works on ARM64 (Oracle A1) and x86_64 Ubuntu hosts with Docker + Compose v2.
#
# Inputs (from /etc/tak-deploy.env, all optional):
#   TAK_ZIP_URL       URL to download takserver-docker-*.zip from (e.g. an OCI PAR)
#   SERVER_HOSTNAME   DNS name clients will use; defaults to the public IP
#   CERT_COUNTRY / CERT_STATE / CERT_CITY / CERT_ORG / CERT_ORG_UNIT
#
# Or copy the zip to /opt/tak-deploy/takserver.zip and run:  sudo /opt/tak-deploy/tak-setup.sh
set -euo pipefail

DEPLOY_DIR=/opt/tak-deploy
ZIP="$DEPLOY_DIR/takserver.zip"
BASE=/opt/takserver            # release is unpacked here; tak/ is the live config + certs
SECRETS=/root/tak-secrets.env
DONE_FLAG="$BASE/.setup-complete"
CERT_OUT=/home/ubuntu/tak-certs
ADMIN_USER="admin"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { log "ERROR: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root (sudo)."

# shellcheck disable=SC1091
[ -f /etc/tak-deploy.env ] && . /etc/tak-deploy.env
CERT_COUNTRY=${CERT_COUNTRY:-AU}
CERT_STATE=${CERT_STATE:-NSW}
CERT_CITY=${CERT_CITY:-Newcastle}
CERT_ORG=${CERT_ORG:-TAK}
CERT_ORG_UNIT=${CERT_ORG_UNIT:-TAK}

if [ -f "$DONE_FLAG" ]; then
  log "Setup already complete. To add a phone: sudo $DEPLOY_DIR/tak-add-user.sh <name>"
  exit 0
fi

command -v docker >/dev/null || die "Docker is not installed."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is not installed (apt-get install docker-compose-v2)."
mkdir -p "$DEPLOY_DIR" "$BASE"

# --- 1. Get the release zip --------------------------------------------------
if [ ! -s "$ZIP" ]; then
  if [ -n "${TAK_ZIP_URL:-}" ]; then
    log "[1/7] Downloading TAK Server release..."
    curl -fSL --retry 5 --retry-delay 10 -o "$ZIP.part" "$TAK_ZIP_URL" || die "Download failed. Check the pre-authenticated request URL has not expired."
    mv "$ZIP.part" "$ZIP"
  else
    log "No TAK Server zip yet. Copy it up and re-run:"
    log "  scp takserver-docker-X.Y-RELEASE-NN.zip ubuntu@<server>:/tmp/"
    log "  ssh ubuntu@<server> 'sudo mv /tmp/takserver-docker-*.zip $ZIP && sudo $DEPLOY_DIR/tak-setup.sh'"
    exit 0
  fi
fi
log "[1/7] Release zip present. SHA-256 (compare with tak.gov):"
sha256sum "$ZIP"

# --- 2. Unpack ---------------------------------------------------------------
if ! ls -d "$BASE"/takserver-docker-* >/dev/null 2>&1; then
  log "[2/7] Unpacking..."
  unzip -q -o "$ZIP" -d "$BASE"
fi
RELEASE_DIR=$(ls -d "$BASE"/takserver-docker-* | head -n1)
[ -d "$RELEASE_DIR/tak" ] || die "Unexpected zip layout: no tak/ folder in $RELEASE_DIR. Is this the Docker release?"
[ -f "$RELEASE_DIR/docker/Dockerfile.takserver" ] || die "No docker/Dockerfile.takserver in $RELEASE_DIR. Is this the Docker release?"
TAK_DIR="$RELEASE_DIR/tak"
VERSION=$(basename "$RELEASE_DIR" | sed 's/^takserver-docker-//')
log "[2/7] TAK Server $VERSION, architecture $(dpkg --print-architecture)"

# --- 3. Secrets ----------------------------------------------------------------
if [ ! -f "$SECRETS" ]; then
  log "[3/7] Generating passwords..."
  umask 077
  {
    echo "DB_PASS='$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)'"
    echo "CERT_PASS='$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 20)'"
  } > "$SECRETS"
  umask 022
fi
# shellcheck disable=SC1090
. "$SECRETS"

# Address clients will connect to.
if [ -n "${SERVER_HOSTNAME:-}" ]; then
  SERVER_NAME="$SERVER_HOSTNAME"
else
  SERVER_NAME=$(curl -fsS --max-time 10 https://checkip.amazonaws.com || curl -fsS --max-time 10 https://ifconfig.me || true)
  SERVER_NAME=$(echo "$SERVER_NAME" | tr -d '[:space:]')
  [[ "$SERVER_NAME" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Could not work out the public IP. Set SERVER_HOSTNAME in /etc/tak-deploy.env and re-run."
fi
echo "SERVER_NAME='$SERVER_NAME'" > "$BASE/server.env"
log "[3/7] Clients will connect to $SERVER_NAME"

# --- 4. Configure ------------------------------------------------------------
if [ ! -f "$TAK_DIR/CoreConfig.xml" ]; then
  log "[4/7] Writing CoreConfig.xml..."
  cp "$TAK_DIR/CoreConfig.example.xml" "$TAK_DIR/CoreConfig.xml"
  # Database: point at the DB container and set a real password (first <connection> only).
  sed -i "0,/<connection /s#<connection url=\"jdbc:postgresql://[^\"]*\"#<connection url=\"jdbc:postgresql://tak-database:5432/cot\"#" "$TAK_DIR/CoreConfig.xml"
  sed -i "0,/<connection /s#\(<connection [^>]*\)password=\"[^\"]*\"#\1password=\"$DB_PASS\"#" "$TAK_DIR/CoreConfig.xml"
  # Server keystore named after the address clients use; replace the default 'atakatak' everywhere.
  sed -i "s#certs/files/takserver.jks#certs/files/$SERVER_NAME.jks#g" "$TAK_DIR/CoreConfig.xml"
  sed -i "s#atakatak#$CERT_PASS#g" "$TAK_DIR/CoreConfig.xml"
  grep -q "tak-database:5432" "$TAK_DIR/CoreConfig.xml" || die "Could not set the database URL in CoreConfig.xml; edit it by hand."
fi
# Certificate country (the script hard-codes US).
sed -i "s/^COUNTRY=.*/COUNTRY=$CERT_COUNTRY/" "$TAK_DIR/certs/cert-metadata.sh"
mkdir -p "$TAK_DIR/logs"

cat > "$BASE/docker-compose.yml" <<EOF
# Generated by tak-setup.sh
name: takserver
services:
  tak-database:
    build:
      context: $RELEASE_DIR/docker
      dockerfile: Dockerfile.takserver-db
    image: takserver-db:$VERSION
    container_name: tak-database
    restart: unless-stopped
    volumes:
      - $TAK_DIR:/opt/tak
      - tak-db-data:/var/lib/postgresql
    networks: [tak]
  takserver:
    build:
      context: $RELEASE_DIR/docker
      dockerfile: Dockerfile.takserver
    image: takserver:$VERSION
    container_name: takserver
    restart: unless-stopped
    depends_on: [tak-database]
    volumes:
      - $TAK_DIR:/opt/tak
    ports:
      - "8089:8089"
      - "8443:8443"
      - "8446:8446"
    networks: [tak]
volumes:
  tak-db-data:
networks:
  tak:
EOF
COMPOSE=(docker compose -f "$BASE/docker-compose.yml")

log "[4/7] Building images (first build takes several minutes)..."
"${COMPOSE[@]}" build

# --- 5. Certificates (before the server first starts) ------------------------
if [ ! -f "$TAK_DIR/certs/files/ca.pem" ]; then
  log "[5/7] Generating certificate authority, server and admin certificates..."
  CA_NAME="$(echo "$CERT_ORG" | tr -cd 'A-Za-z0-9')-Root-CA"
  "${COMPOSE[@]}" run --rm --no-deps --entrypoint bash \
    -e COUNTRY="$CERT_COUNTRY" -e STATE="$CERT_STATE" -e CITY="$CERT_CITY" \
    -e ORGANIZATION="$CERT_ORG" -e ORGANIZATIONAL_UNIT="$CERT_ORG_UNIT" \
    -e CAPASS="$CERT_PASS" -e PASS="$CERT_PASS" \
    takserver -c "set -e; cd /opt/tak/certs \
      && ./makeRootCa.sh --ca-name '$CA_NAME' \
      && ./makeCert.sh server '$SERVER_NAME' \
      && ./makeCert.sh client '$ADMIN_USER'"
fi
[ -f "$TAK_DIR/certs/files/$SERVER_NAME.jks" ] || die "Server keystore $SERVER_NAME.jks missing. If the address changed, see README 'Changing the server address'."

# --- 6. Start ----------------------------------------------------------------
log "[6/7] Starting database and TAK Server..."
"${COMPOSE[@]}" up -d

log "Waiting for TAK Server to accept the admin certificate (usually 2-5 minutes)..."
ok=false
for i in $(seq 1 60); do
  if "${COMPOSE[@]}" exec -T takserver bash -c \
      "cd /opt/tak && java -jar utils/UserManager.jar certmod -A certs/files/$ADMIN_USER.pem" >/dev/null 2>&1; then
    ok=true; break
  fi
  sleep 10
  [ $((i % 6)) -eq 0 ] && log "  still waiting ($((i * 10))s)..."
done
$ok || die "TAK Server did not come up in 10 minutes. Check: sudo docker logs takserver; sudo ls -lt $TAK_DIR/logs/ (then tail the newest log). Re-run this script once fixed."

# --- 7. Hand over ------------------------------------------------------------
log "[7/7] Copying admin files to $CERT_OUT ..."
mkdir -p "$CERT_OUT"
cp "$TAK_DIR/certs/files/$ADMIN_USER.p12" "$CERT_OUT/"
cp "$TAK_DIR/certs/files/ca.pem" "$CERT_OUT/tak-ca.pem"
chown -R ubuntu:ubuntu "$CERT_OUT" 2>/dev/null || true
chmod 700 "$CERT_OUT"
chmod 600 "$CERT_OUT"/*

touch "$DONE_FLAG"
cat <<EOF

==========================================================
 TAK Server $VERSION setup complete
==========================================================
 Admin UI:   https://$SERVER_NAME:8443   (import admin.p12 first)
 Clients:    $SERVER_NAME:8089 (TLS)
 Admin cert: $CERT_OUT/$ADMIN_USER.p12
 Cert password: sudo cat $SECRETS   (CERT_PASS)
 Add a phone:   sudo $DEPLOY_DIR/tak-add-user.sh <name>
==========================================================
EOF
