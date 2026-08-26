#!/bin/bash
#
# OpenSearch on Railway.
#
# Runs as root so it can prepare the volume, then hands the node to uid 1000 --
# OpenSearch refuses to run as root and the upstream entrypoint exits if it is.
#
# Everything below is boot-time work the stock image cannot express:
#
#   * a Railway volume is mounted root-owned, and the image neither chowns it
#     nor runs as root, so the node cannot write its own data directory;
#   * transport TLS is mandatory and the only certificates the image can install
#     are the project's published demo certificates;
#   * the internal user database ships with well-known password hashes;
#   * the JVM heap is a fixed 1 GB in jvm.options regardless of the container's
#     memory limit;
#   * the snapshot repository needs credentials in the OpenSearch keystore,
#     which no environment variable can populate.

set -euo pipefail

OPENSEARCH_HOME=/usr/share/opensearch
CONF="$OPENSEARCH_HOME/config"
DATA="$OPENSEARCH_HOME/data"
CERT_STORE="$DATA/certs"
CERT_SUBJ_PREFIX="/C=US/O=OpenSearch/OU=opensearch-railway"

log() { echo "[railway-entrypoint] $*"; }

# ---------------------------------------------------------------------------
# 1. Volume
# ---------------------------------------------------------------------------
IS_ROOT=no
if [ "$(id -u)" = "0" ]; then
  IS_ROOT=yes
fi

mkdir -p "$DATA" "$CERT_STORE" "$OPENSEARCH_HOME/logs"
if [ "$IS_ROOT" = "yes" ]; then
  chown -R 1000:0 "$DATA" "$OPENSEARCH_HOME/logs"
  chmod 0770 "$DATA" "$CERT_STORE"
else
  log "WARNING: not running as root; skipping the volume chown."
fi

# ---------------------------------------------------------------------------
# 2. Heap
#
# jvm.options pins -Xms1g -Xmx1g. OpenSearch wants half the available memory,
# capped below the ~32 GB compressed-oops boundary, and reading the cgroup means
# a deployer who resizes the service gets a node that retunes itself.
# ---------------------------------------------------------------------------
if [ -z "${OPENSEARCH_JAVA_OPTS:-}" ]; then
  MEM_LIMIT=""
  if [ -r /sys/fs/cgroup/memory.max ]; then
    MEM_LIMIT="$(cat /sys/fs/cgroup/memory.max)"
  elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
    MEM_LIMIT="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)"
  fi
  case "$MEM_LIMIT" in
    ''|*[!0-9]*) MEM_LIMIT=2147483648 ;;
  esac
  # A cgroup with no limit reports a number far larger than any real host.
  if [ "$MEM_LIMIT" -gt 137438953472 ]; then
    MEM_LIMIT=2147483648
  fi
  HEAP_MB=$(( MEM_LIMIT / 2 / 1024 / 1024 ))
  if [ "$HEAP_MB" -lt 512 ]; then
    HEAP_MB=512
  fi
  if [ "$HEAP_MB" -gt 30720 ]; then
    HEAP_MB=30720
  fi
  export OPENSEARCH_JAVA_OPTS="-Xms${HEAP_MB}m -Xmx${HEAP_MB}m"
  log "JVM heap set to ${HEAP_MB}m from a container limit of $(( MEM_LIMIT / 1024 / 1024 ))m."
fi

# ---------------------------------------------------------------------------
# 3. Transport certificates
#
# Minted once, on the volume, so they survive every redeploy. The node is its
# own only transport peer, so a private CA of one certificate is the whole PKI.
# ---------------------------------------------------------------------------
if [ ! -s "$CERT_STORE/node.pem" ] || [ ! -s "$CERT_STORE/admin.pem" ]; then
  log "Generating this deployment's transport CA and certificates."
  TMP="$(mktemp -d)"
  cat > "$TMP/node.ext" <<'EXT'
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = DNS:opensearch-node, DNS:localhost, IP:127.0.0.1
EXT
  cat > "$TMP/admin.ext" <<'EXT'
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EXT

  openssl genrsa -out "$TMP/ca-key.pem" 4096
  openssl req -x509 -new -sha256 -days 3650 -key "$TMP/ca-key.pem" \
    -subj "$CERT_SUBJ_PREFIX/CN=opensearch-railway-ca" -out "$TMP/ca.pem"

  for name in node admin; do
    openssl genrsa -out "$TMP/$name-key-pkcs1.pem" 2048
    openssl pkcs8 -topk8 -inform PEM -outform PEM -nocrypt \
      -in "$TMP/$name-key-pkcs1.pem" -out "$TMP/$name-key.pem"
    cn="$name"
    if [ "$name" = "node" ]; then cn="opensearch-node"; fi
    openssl req -new -key "$TMP/$name-key.pem" \
      -subj "$CERT_SUBJ_PREFIX/CN=$cn" -out "$TMP/$name.csr"
    openssl x509 -req -sha256 -days 3650 -in "$TMP/$name.csr" \
      -CA "$TMP/ca.pem" -CAkey "$TMP/ca-key.pem" -CAcreateserial \
      -extfile "$TMP/$name.ext" -out "$TMP/$name.pem"
  done

  install -m 0600 "$TMP/ca-key.pem" "$CERT_STORE/ca-key.pem"
  install -m 0644 "$TMP/ca.pem" "$CERT_STORE/ca.pem"
  install -m 0600 "$TMP/node-key.pem" "$CERT_STORE/node-key.pem"
  install -m 0644 "$TMP/node.pem" "$CERT_STORE/node.pem"
  install -m 0600 "$TMP/admin-key.pem" "$CERT_STORE/admin-key.pem"
  install -m 0644 "$TMP/admin.pem" "$CERT_STORE/admin.pem"
  rm -rf "$TMP"
fi

# The security plugin resolves every certificate path relative to the config
# directory and refuses an absolute one, so the volume's copies are staged in.
rm -rf "$CONF/certs"
mkdir -p "$CONF/certs"
cp "$CERT_STORE/ca.pem" "$CERT_STORE/node.pem" "$CERT_STORE/node-key.pem" \
   "$CERT_STORE/admin.pem" "$CERT_STORE/admin-key.pem" "$CONF/certs/"
chmod 0600 "$CONF/certs/node-key.pem" "$CONF/certs/admin-key.pem"

# ---------------------------------------------------------------------------
# 4. Internal users
#
# Replaces the shipped internal_users.yml, whose bcrypt hashes are published in
# the security plugin's repository. Only read on the very first cluster start
# (plugins.security.allow_default_init_securityindex); after that the security
# index is authoritative and passwords change through the Dashboards Security
# UI, or through securityadmin.sh with config/certs/admin.pem.
# ---------------------------------------------------------------------------
ADMIN_USER="${OPENSEARCH_ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${OPENSEARCH_INITIAL_ADMIN_PASSWORD:-}"
DASHBOARDS_PASSWORD="${DASHBOARDS_SERVICE_PASSWORD:-}"

if [ -z "$ADMIN_PASSWORD" ] || [ -z "$DASHBOARDS_PASSWORD" ]; then
  log "FATAL: OPENSEARCH_INITIAL_ADMIN_PASSWORD and DASHBOARDS_SERVICE_PASSWORD must both be set."
  exit 1
fi

hash_password() {
  # Hasher reads the password from the environment where the build supports it,
  # keeping it out of the process list; older builds only accept -p.
  local out h tool="$OPENSEARCH_HOME/plugins/opensearch-security/tools/hash.sh"
  out="$(OPENSEARCH_HASH_INPUT="$1" bash "$tool" -env OPENSEARCH_HASH_INPUT 2>/dev/null || true)"
  h="$(printf '%s\n' "$out" | grep -E '^\$2[aby]\$' | tail -n 1 || true)"
  if [ -z "$h" ]; then
    out="$(bash "$tool" -p "$1" 2>/dev/null || true)"
    h="$(printf '%s\n' "$out" | grep -E '^\$2[aby]\$' | tail -n 1 || true)"
  fi
  printf '%s' "$h"
}

ADMIN_HASH="$(hash_password "$ADMIN_PASSWORD")"
DASHBOARDS_HASH="$(hash_password "$DASHBOARDS_PASSWORD")"
if [ -z "$ADMIN_HASH" ] || [ -z "$DASHBOARDS_HASH" ]; then
  log "FATAL: could not hash the configured passwords."
  exit 1
fi

# roles_mapping.yml, shipped with the plugin, maps all_access to the backend
# role "admin" and kibana_server to the user "kibanaserver" -- so those two
# names are what wire these accounts to their privileges.
cat > "$CONF/opensearch-security/internal_users.yml" <<YAML
---
_meta:
  type: "internalusers"
  config_version: 2

$ADMIN_USER:
  hash: "$ADMIN_HASH"
  reserved: true
  backend_roles:
  - "admin"
  description: "Cluster administrator, created by the Railway template"

kibanaserver:
  hash: "$DASHBOARDS_HASH"
  reserved: true
  description: "Service account OpenSearch Dashboards authenticates with"
YAML
chmod 0600 "$CONF/opensearch-security/internal_users.yml"

# ---------------------------------------------------------------------------
# 5. Node configuration
# ---------------------------------------------------------------------------
cp /opt/opensearch-railway/opensearch.yml "$CONF/opensearch.yml"

SNAPSHOT_REPOSITORY="${SNAPSHOT_REPOSITORY_NAME:-railway-object-storage}"
S3_ENABLED=no
if [ -n "${SNAPSHOT_S3_BUCKET:-}" ] && [ -n "${SNAPSHOT_S3_ACCESS_KEY_ID:-}" ]; then
  S3_ENABLED=yes

  # ${{<bucket>.ENDPOINT}} resolves with its scheme; the repository-s3 client
  # wants a bare host and a separate protocol setting.
  S3_ENDPOINT="${SNAPSHOT_S3_ENDPOINT:-https://t3.storageapi.dev}"
  S3_PROTOCOL=https
  case "$S3_ENDPOINT" in
    https://*) S3_ENDPOINT="${S3_ENDPOINT#https://}" ;;
    http://*)  S3_ENDPOINT="${S3_ENDPOINT#http://}"; S3_PROTOCOL=http ;;
  esac

  cat >> "$CONF/opensearch.yml" <<YAML

# --- snapshot repository client (written at boot from the bucket variables) --
s3.client.default.endpoint: "$S3_ENDPOINT"
s3.client.default.protocol: "$S3_PROTOCOL"
s3.client.default.path_style_access: true
s3.client.default.region: "${SNAPSHOT_S3_REGION:-auto}"
YAML

  # Repository credentials live in the OpenSearch keystore, never in the
  # configuration file: opensearch.yml is world-readable inside the container
  # and is printed verbatim by several support endpoints.
  if [ ! -f "$CONF/opensearch.keystore" ]; then
    "$OPENSEARCH_HOME/bin/opensearch-keystore" create >/dev/null
  fi
  printf '%s' "$SNAPSHOT_S3_ACCESS_KEY_ID" | \
    "$OPENSEARCH_HOME/bin/opensearch-keystore" add --stdin --force s3.client.default.access_key
  printf '%s' "${SNAPSHOT_S3_SECRET_ACCESS_KEY:-}" | \
    "$OPENSEARCH_HOME/bin/opensearch-keystore" add --stdin --force s3.client.default.secret_key
  log "Snapshot repository client configured for bucket $SNAPSHOT_S3_BUCKET."
fi

if [ "$IS_ROOT" = "yes" ]; then
  chown -R 1000:0 "$CONF"
  chmod 0640 "$CONF/opensearch.yml" "$CONF/opensearch-security/internal_users.yml"
  if [ -f "$CONF/opensearch.keystore" ]; then
    chmod 0660 "$CONF/opensearch.keystore"
  fi
fi

# ---------------------------------------------------------------------------
# 6. Snapshot repository and schedule
#
# Registered after the node answers, because the repository API needs a running
# cluster. Behind the exec, so a slow or unreachable bucket costs the deployment
# nothing. Every call is idempotent and a failure is logged, never fatal.
# ---------------------------------------------------------------------------
if [ "$S3_ENABLED" = "yes" ]; then
(
  set +e
  ES="http://127.0.0.1:9200"
  AUTH="$ADMIN_USER:$ADMIN_PASSWORD"
  for _ in $(seq 1 60); do
    code="$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" "$ES/_cluster/health")"
    if [ "$code" = "200" ]; then
      break
    fi
    sleep 5
  done

  body="$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" -X PUT \
    -H 'Content-Type: application/json' \
    "$ES/_snapshot/$SNAPSHOT_REPOSITORY" \
    -d "{\"type\":\"s3\",\"settings\":{\"bucket\":\"$SNAPSHOT_S3_BUCKET\",\"client\":\"default\",\"base_path\":\"${SNAPSHOT_S3_BASE_PATH:-opensearch-snapshots}\"}}")"
  log "Snapshot repository $SNAPSHOT_REPOSITORY registration returned HTTP $body."

  policy="$(cat <<JSON
{
  "description": "Daily snapshot of every index to Railway object storage",
  "creation": {
    "schedule": { "cron": { "expression": "${SNAPSHOT_SCHEDULE_CRON:-0 2 * * *}", "timezone": "UTC" } },
    "time_limit": "1h"
  },
  "deletion": {
    "schedule": { "cron": { "expression": "30 3 * * *", "timezone": "UTC" } },
    "condition": { "max_age": "${SNAPSHOT_RETENTION:-14d}", "max_count": 50, "min_count": 1 }
  },
  "snapshot_config": {
    "repository": "$SNAPSHOT_REPOSITORY",
    "timezone": "UTC",
    "indices": "*",
    "ignore_unavailable": true,
    "include_global_state": false,
    "partial": false
  }
}
JSON
)"
  code="$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" -X POST \
    -H 'Content-Type: application/json' \
    "$ES/_plugins/_sm/policies/${SNAPSHOT_POLICY_NAME:-railway-daily}" -d "$policy")"
  log "Snapshot policy returned HTTP $code (409 means it already exists)."
) &
fi

# ---------------------------------------------------------------------------
# 7. Hand over
# ---------------------------------------------------------------------------
export HOME="$OPENSEARCH_HOME"
cd "$OPENSEARCH_HOME"

if [ "$IS_ROOT" = "yes" ]; then
  exec setpriv --reuid=1000 --regid=1000 --init-groups \
    "$OPENSEARCH_HOME/opensearch-docker-entrypoint.sh" "$@"
fi
exec "$OPENSEARCH_HOME/opensearch-docker-entrypoint.sh" "$@"
