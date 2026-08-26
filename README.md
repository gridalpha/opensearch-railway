# opensearch-railway

Two one-layer wrappers around the published
[`opensearchproject/opensearch`](https://hub.docker.com/r/opensearchproject/opensearch)
and
[`opensearchproject/opensearch-dashboards`](https://hub.docker.com/r/opensearchproject/opensearch-dashboards)
images that make OpenSearch deployable on [Railway](https://railway.com) as a
template, with no manual first-run steps and no shipped credentials.

| Directory | Builds | Railway variable |
|---|---|---|
| `opensearch/` | the search node | `RAILWAY_DOCKERFILE_PATH=opensearch/Dockerfile` |
| `dashboards/` | the Dashboards UI | `RAILWAY_DOCKERFILE_PATH=dashboards/Dockerfile` |

Both build from the repository root, so the `COPY` paths are directory-prefixed.

## What the OpenSearch layer adds

| Gap in the stock image | What this repo does |
|---|---|
| Railway mounts volumes root-owned; the image runs as uid 1000 and OpenSearch refuses to run as root | the entrypoint starts as root, chowns the volume, and `setpriv`s down to uid 1000 |
| Transport TLS is mandatory, and the only certificates the image can install are the project's published demo certificates | a private CA, node certificate and admin certificate are minted with `openssl` on the volume the first time the node boots |
| `internal_users.yml` ships bcrypt hashes that are published in the security plugin's repository | it is rewritten at boot from `OPENSEARCH_INITIAL_ADMIN_PASSWORD` and `DASHBOARDS_SERVICE_PASSWORD`, and `plugins.security.allow_default_init_securityindex` loads it on the first cluster start |
| `jvm.options` pins a 1 GB heap whatever the container's limit is | the entrypoint reads `/sys/fs/cgroup/memory.max` and sets `-Xmx` to half of it, capped at 30 GB |
| The default `mmapfs` store needs `vm.max_map_count` raised on the host | `node.store.allow_mmap: false` |
| Snapshot repository credentials can only live in the OpenSearch keystore | the entrypoint loads them from the bucket variables, registers the repository and creates a daily snapshot policy once the node answers |
| The bundled Performance Analyzer agent is a second JVM that writes to `/dev/shm`, which is 64 MB on Railway | `DISABLE_PERFORMANCE_ANALYZER_AGENT_CLI=true` |

REST TLS is deliberately off. The node's HTTP port is never published: it is
reachable only over the project's private network, and Railway terminates TLS at
its edge for the Dashboards domain people actually visit. Turning it on would
mean handing this node's CA certificate to the Dashboards service, and Railway
volumes are 1:1 with a service, so there is no way to share a file between them.
Authentication is unaffected — every request still needs credentials.

## What the Dashboards layer adds

The stock entrypoint maps a fixed list of settings from environment variables,
and none of the `opensearch_security.*` settings are on it. Two of them decide
whether the deployment is safe:

- `opensearch_security.cookie.password` signs and encrypts the session cookie,
  and its shipped default is a constant published in the plugin's source.
- `opensearch.requestHeadersAllowlist` has to carry `securitytenant`, or every
  tenant-scoped saved object lands in the wrong tenant.

So `opensearch_dashboards.yml` is written at boot from variables Railway can
set, and the variables the stock entrypoint would turn into command-line
overrides are consumed rather than passed on.

## Variables

### OpenSearch

| Variable | Required | Notes |
|---|---|---|
| `OPENSEARCH_INITIAL_ADMIN_PASSWORD` | yes | Read only while the security index does not exist. Change it later from the Dashboards **Security** UI. |
| `DASHBOARDS_SERVICE_PASSWORD` | yes | Password for the `kibanaserver` service account. The Dashboards service references it. |
| `OPENSEARCH_ADMIN_USERNAME` | no | Defaults to `admin`. |
| `SNAPSHOT_S3_BUCKET`, `SNAPSHOT_S3_ENDPOINT`, `SNAPSHOT_S3_REGION`, `SNAPSHOT_S3_ACCESS_KEY_ID`, `SNAPSHOT_S3_SECRET_ACCESS_KEY` | no | Set them all and the entrypoint registers a snapshot repository plus a daily policy. Leave them unset and snapshots are simply not configured. |
| `SNAPSHOT_SCHEDULE_CRON` | no | Defaults to `0 2 * * *` (UTC). |
| `SNAPSHOT_RETENTION` | no | Defaults to `14d`. |
| `OPENSEARCH_JAVA_OPTS` | no | Set it and the entrypoint leaves the heap alone. |

### Dashboards

| Variable | Required | Notes |
|---|---|---|
| `DASHBOARDS_COOKIE_PASSWORD` | yes | At least 32 characters. The container refuses to start without it. |
| `OPENSEARCH_PASSWORD` | yes | The `kibanaserver` password from the OpenSearch service. |
| `OPENSEARCH_HOSTS` | no | Defaults to `http://opensearch.railway.internal:9200`. |
| `OPENSEARCH_USERNAME` | no | Defaults to `kibanaserver`. |
| `PORT` | no | Defaults to `5601`. |
| `DASHBOARDS_EXTRA_CONFIG` | no | Appended verbatim to `opensearch_dashboards.yml`. |

## Resetting the admin password

`internal_users.yml` is read once, when the cluster first creates its security
index. After that the index is authoritative. Change passwords from
**Security → Internal users** in Dashboards, or from inside the OpenSearch
container:

```
plugins/opensearch-security/tools/securityadmin.sh \
  -f config/opensearch-security/internal_users.yml \
  -icl -nhnv -cacert config/certs/ca.pem \
  -cert config/certs/admin.pem -key config/certs/admin-key.pem
```

## Licence

The images and OpenSearch itself are Apache-2.0. The files in this repository
are published under the same licence.
