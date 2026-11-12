FROM rocker/r-ver:4.5.3

# The base image is Ubuntu 24.04 (noble), so the package repo must be a noble
# one; the old line pointed at jammy (22.04) binaries. This is a dated
# Posit Package Manager snapshot, so rebuilds get the same package versions.
# 2026-11-10 gives bigrquery 1.6.2, mcptools 1.0.3, ellmer 0.5.1. Keep it in
# sync with the test job in .github/workflows/docker-publish.yml.
RUN echo 'options(repos = c(CRAN = "https://p3m.dev/cran/__linux__/noble/2026-11-10"))' >> /usr/local/lib/R/etc/Rprofile.site

# curl and jq are needed by refresh-schemas.sh; libuv1t64 is the one run-time
# library the binary R packages need (fs) that the base image does not have.
# The other libraries they need are in the base image.
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    libuv1t64 \
    && rm -rf /var/lib/apt/lists/*

# Only the packages the code uses (dplyr, purrr, stringr, readr, tibble, glue,
# jsonlite, bigrquery, gargle, ellmer, mcptools), as binaries from the snapshot.
# bigrquery pinned: R/functions.R (bq_dry_run_stats) calls its internal
# bq_post() and bq_path(), which may change between releases. The snapshot
# above provides 1.6.2; the build stops if that ever stops being true.
RUN install2.r --error --skipinstalled \
    dplyr purrr stringr readr tibble glue jsonlite \
    gargle bigrquery ellmer mcptools \
  && Rscript -e 'stopifnot(packageVersion("bigrquery") == "1.6.2")' \
  && rm -rf /tmp/downloaded_packages /tmp/Rtmp* \
  && find /usr/local/lib/R/site-library -mindepth 2 -maxdepth 2 \
       \( -name help -o -name doc -o -name html -o -name tests -o -name examples \) \
       -exec rm -rf {} +

COPY R /app/R
COPY server.R /app/server.R
COPY refresh-schemas.sh /refresh-schemas.sh
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /refresh-schemas.sh

# Schema snapshot baked in at build time, so the server has schemas even when
# the start-up refresh cannot reach GitHub. The scheduled CI build passes a new
# SCHEMA_SNAPSHOT value each run so this layer is not served from the build
# cache. An optional build secret `github_token` avoids the GitHub API rate
# limit on shared CI runners.
ARG SCHEMA_SNAPSHOT=local
RUN --mount=type=secret,id=github_token,required=false \
    echo "Schema snapshot: ${SCHEMA_SNAPSHOT}" \
    && GITHUB_TOKEN="$(cat /run/secrets/github_token 2>/dev/null || true)" /refresh-schemas.sh

ENTRYPOINT ["/entrypoint.sh"]
