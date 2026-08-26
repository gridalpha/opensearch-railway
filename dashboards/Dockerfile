# OpenSearch Dashboards for Railway.
#
# One layer on top of the published image, adding only the boot-time step that
# writes opensearch_dashboards.yml -- the settings that matter here have no
# environment-variable mapping in the stock entrypoint.
FROM opensearchproject/opensearch-dashboards:3

USER root

COPY dashboards/entrypoint.sh /usr/local/bin/opensearch-dashboards-railway-entrypoint.sh
RUN chmod 0755 /usr/local/bin/opensearch-dashboards-railway-entrypoint.sh \
 && bash -n /usr/local/bin/opensearch-dashboards-railway-entrypoint.sh \
 && chown -R 1000:0 /usr/share/opensearch-dashboards/config \
 && chmod 0770 /usr/share/opensearch-dashboards/config

# No volume, so nothing needs root at runtime.
USER 1000

ENTRYPOINT ["/usr/local/bin/opensearch-dashboards-railway-entrypoint.sh"]
CMD ["opensearch-dashboards"]
