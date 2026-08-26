# OpenSearch node for Railway.
#
# One layer on top of the published image. The image itself is left alone --
# everything this adds is boot-time work (see entrypoint.sh) plus the two
# packages that work needs.
FROM opensearchproject/opensearch:3

USER root

# openssl mints this deployment's own transport CA, setpriv drops back to the
# opensearch user, and curl registers the snapshot repository once the node is
# up. --allowerasing lets curl replace the base image's curl-minimal.
RUN dnf install -y --allowerasing --setopt=install_weak_deps=False \
        openssl util-linux curl \
 && dnf clean all \
 && rm -rf /var/cache/dnf \
 && setpriv --reuid=1000 --regid=1000 --init-groups id \
 && openssl version \
 && curl --version | head -1

# repository-s3 is not part of the distribution bundle, and a snapshot
# repository cannot be added to a running cluster without it.
RUN bin/opensearch-plugin list | grep -qx repository-s3 \
 || bin/opensearch-plugin install --batch repository-s3

# The entrypoint rewrites internal_users.yml and leaves every other security
# configuration file as shipped, so fail the build -- not the deployment -- if
# the distribution ever stops shipping them.
RUN test -s config/opensearch-security/roles_mapping.yml \
 && test -s config/opensearch-security/roles.yml \
 && test -s config/opensearch-security/config.yml \
 && test -s config/opensearch-security/action_groups.yml

COPY opensearch/opensearch.yml /opt/opensearch-railway/opensearch.yml
COPY opensearch/entrypoint.sh /usr/local/bin/opensearch-railway-entrypoint.sh
RUN chmod 0755 /usr/local/bin/opensearch-railway-entrypoint.sh \
 && bash -n /usr/local/bin/opensearch-railway-entrypoint.sh \
 && chown -R 1000:0 config plugins /opt/opensearch-railway

# Deliberately left as root: the entrypoint needs it to chown the volume
# Railway mounts, and drops to uid 1000 before starting the node.
ENTRYPOINT ["/usr/local/bin/opensearch-railway-entrypoint.sh"]
CMD ["opensearch"]
