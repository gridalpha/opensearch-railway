#!/bin/bash
#
# OpenSearch Dashboards on Railway.
#
# The stock image maps a fixed list of settings from environment variables, and
# none of the opensearch_security.* settings are on it. Two of them decide
# whether this deployment is safe:
#
#   * opensearch_security.cookie.password signs and encrypts the session cookie.
#     Its shipped default is a constant published in the plugin's source, so
#     leaving it alone lets anyone mint a valid session for any user.
#   * opensearch.requestHeadersAllowlist has to carry securitytenant, or every
#     tenant-scoped saved object silently lands in the wrong tenant.
#
# So the configuration file is written here instead, from variables Railway can
# actually set.

set -euo pipefail

HOME_DIR=/usr/share/opensearch-dashboards
CONFIG="$HOME_DIR/config/opensearch_dashboards.yml"

log() { echo "[railway-entrypoint] $*"; }

# ${{opensearch.RAILWAY_PRIVATE_DOMAIN}} renders empty until that service owns a
# deployment -- which is every service's state during a template deploy -- so a
# reference alone would bake "http://:9200". The private hostname is
# deterministic, so fall back to it whenever the host half is missing.
OS_HOSTS="${OPENSEARCH_HOSTS:-}"
case "$OS_HOSTS" in
  ''|http://:*|https://:*)
    OS_HOSTS="http://opensearch.railway.internal:9200"
    log "OPENSEARCH_HOSTS was empty or hostless; using $OS_HOSTS."
    ;;
esac

COOKIE_PASSWORD="${DASHBOARDS_COOKIE_PASSWORD:-}"
if [ "${#COOKIE_PASSWORD}" -lt 32 ]; then
  log "FATAL: DASHBOARDS_COOKIE_PASSWORD must be at least 32 characters."
  log "It encrypts the session cookie; there is no safe default to fall back to."
  exit 1
fi

OS_USERNAME="${OPENSEARCH_USERNAME:-kibanaserver}"
OS_PASSWORD="${OPENSEARCH_PASSWORD:-}"
if [ -z "$OS_PASSWORD" ]; then
  log "FATAL: OPENSEARCH_PASSWORD is unset; Dashboards cannot authenticate to OpenSearch."
  exit 1
fi

cat > "$CONFIG" <<YAML
# Written at boot by entrypoint.sh. Edits here are lost on the next deploy.
server.host: "0.0.0.0"
server.port: ${PORT:-5601}
server.name: "opensearch-dashboards"

opensearch.hosts: ["$OS_HOSTS"]
opensearch.username: "$OS_USERNAME"
opensearch.password: "$OS_PASSWORD"
opensearch.ssl.verificationMode: full
opensearch.requestHeadersAllowlist: ["securitytenant", "Authorization"]

opensearch_security.multitenancy.enabled: true
opensearch_security.multitenancy.tenants.enable_global: true
opensearch_security.multitenancy.tenants.enable_private: true
opensearch_security.multitenancy.tenants.preferred: ["Private", "Global"]
opensearch_security.readonly_mode.roles: ["kibana_read_only"]

# Railway terminates TLS at its edge, so the browser's session cookie is only
# ever carried over HTTPS and is marked accordingly.
opensearch_security.cookie.secure: true
opensearch_security.cookie.password: "$COOKIE_PASSWORD"

# Railway's health check is anonymous; /api/status is the only route it reaches
# and it reports red whenever the OpenSearch node is unreachable.
opensearch_security.auth.unauthenticated_routes: ["/api/status"]
YAML

if [ -n "${DASHBOARDS_EXTRA_CONFIG:-}" ]; then
  printf '\n# --- DASHBOARDS_EXTRA_CONFIG ---\n%s\n' "$DASHBOARDS_EXTRA_CONFIG" >> "$CONFIG"
fi

# The stock entrypoint turns each of these into a --setting=value argument,
# which beats the file above. The file is the single source of truth, so the
# variables are consumed here and not passed on -- which also keeps the
# OpenSearch password out of the child process's environment.
unset OPENSEARCH_HOSTS OPENSEARCH_USERNAME OPENSEARCH_PASSWORD
unset SERVER_HOST SERVER_PORT SERVER_NAME

cd "$HOME_DIR"
exec "$HOME_DIR/opensearch-dashboards-docker-entrypoint.sh" "$@"
