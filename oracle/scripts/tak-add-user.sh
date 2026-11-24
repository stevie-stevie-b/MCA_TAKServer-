#!/bin/bash
# Makes a client certificate and an ATAK/iTAK connection data package for one person or device.
#
#   sudo /opt/tak-deploy/tak-add-user.sh <name> [group]
#
# <name>   letters, numbers, dot, dash, underscore (e.g. jsmith or truck-2)
# [group]  optional TAK group to put the certificate in (created if new)
#
# Output: /home/ubuntu/tak-certs/<name>-<server>.zip
# Import it in ATAK/iTAK (Import > Local SD / Files). Treat it like a password.
set -euo pipefail

BASE=/opt/takserver
SECRETS=/root/tak-secrets.env
CERT_OUT=/home/ubuntu/tak-certs

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root (sudo)."
[ $# -ge 1 ] || die "Usage: $0 <name> [group]"
NAME=$1
GROUP=${2:-}
[[ "$NAME" =~ ^[A-Za-z0-9._-]{3,64}$ ]] || die "Name must be 3-64 characters: letters, numbers, . _ -"
[ -z "$GROUP" ] || [[ "$GROUP" =~ ^[A-Za-z0-9._\ -]{1,64}$ ]] || die "Group may only use letters, numbers, spaces, . _ -"
[ "$NAME" != "admin" ] || die "'admin' is reserved for the web UI certificate."

[ -f "$BASE/.setup-complete" ] || die "Run tak-setup.sh first."
# shellcheck disable=SC1090
. "$SECRETS"
# shellcheck disable=SC1091
. "$BASE/server.env"
# shellcheck disable=SC1091
[ -f /etc/tak-deploy.env ] && . /etc/tak-deploy.env

RELEASE_DIR=$(ls -d "$BASE"/takserver-docker-* | head -n1)
FILES="$RELEASE_DIR/tak/certs/files"
COMPOSE=(docker compose -f "$BASE/docker-compose.yml")

[ ! -f "$FILES/$NAME.p12" ] || die "A certificate for '$NAME' already exists. Pick another name or revoke the old one first."

echo "Making certificate for $NAME..."
"${COMPOSE[@]}" exec -T \
  -e COUNTRY="${CERT_COUNTRY:-AU}" -e STATE="${CERT_STATE:-NSW}" -e CITY="${CERT_CITY:-Newcastle}" \
  -e ORGANIZATION="${CERT_ORG:-TAK}" -e ORGANIZATIONAL_UNIT="${CERT_ORG_UNIT:-TAK}" \
  -e CAPASS="$CERT_PASS" -e PASS="$CERT_PASS" \
  takserver bash -c "cd /opt/tak/certs && ./makeCert.sh client '$NAME'"

if [ -n "$GROUP" ]; then
  echo "Adding $NAME to group '$GROUP'..."
  "${COMPOSE[@]}" exec -T takserver bash -c \
    "cd /opt/tak && java -jar utils/UserManager.jar certmod -g '$GROUP' certs/files/$NAME.pem"
fi

# Build the data package: MANIFEST/manifest.xml + certs/{server.pref, CA truststore, client cert}.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/MANIFEST" "$WORK/certs"
cp "$FILES/truststore-root.p12" "$WORK/certs/truststore-root.p12"
cp "$FILES/$NAME.p12" "$WORK/certs/$NAME.p12"

cat > "$WORK/certs/server.pref" <<EOF
<?xml version='1.0' encoding='ASCII' standalone='yes'?>
<preferences>
  <preference version="1" name="cot_streams">
    <entry key="count" class="class java.lang.Integer">1</entry>
    <entry key="description0" class="class java.lang.String">TAK Server</entry>
    <entry key="enabled0" class="class java.lang.Boolean">true</entry>
    <entry key="connectString0" class="class java.lang.String">$SERVER_NAME:8089:ssl</entry>
  </preference>
  <preference version="1" name="com.atakmap.app_preferences">
    <entry key="displayServerConnectionWidget" class="class java.lang.Boolean">true</entry>
    <entry key="caLocation" class="class java.lang.String">cert/truststore-root.p12</entry>
    <entry key="caPassword" class="class java.lang.String">$CERT_PASS</entry>
    <entry key="clientPassword" class="class java.lang.String">$CERT_PASS</entry>
    <entry key="certificateLocation" class="class java.lang.String">cert/$NAME.p12</entry>
  </preference>
</preferences>
EOF

cat > "$WORK/MANIFEST/manifest.xml" <<EOF
<MissionPackageManifest version="2">
  <Configuration>
    <Parameter name="uid" value="$(cat /proc/sys/kernel/random/uuid)"/>
    <Parameter name="name" value="$NAME-$SERVER_NAME"/>
    <Parameter name="onReceiveDelete" value="true"/>
  </Configuration>
  <Contents>
    <Content ignore="false" zipEntry="certs/server.pref"/>
    <Content ignore="false" zipEntry="certs/truststore-root.p12"/>
    <Content ignore="false" zipEntry="certs/$NAME.p12"/>
  </Contents>
</MissionPackageManifest>
EOF

mkdir -p "$CERT_OUT"
OUT="$CERT_OUT/$NAME-$SERVER_NAME.zip"
(cd "$WORK" && zip -q -r "$OUT" MANIFEST certs)
chown ubuntu:ubuntu "$OUT" 2>/dev/null || true
chmod 600 "$OUT"

echo
echo "Data package: $OUT"
echo "Copy it off with:  scp ubuntu@$SERVER_NAME:$OUT ."
echo "Then delete the server copy once it's on the device:  sudo rm $OUT"
