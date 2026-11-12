FROM rocker/tidyverse:4.5.3
RUN echo 'options(repos = c(CRAN = "https://packagemanager.posit.co/cran/__linux__/jammy/latest"))' >> /usr/local/lib/R/etc/Rprofile.site

# Additional system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    cmake \
    curl \
    jq \
    libmbedtls-dev \
    libzmq3-dev \
    libsodium-dev \
    && rm -rf /var/lib/apt/lists/*

# Install R packages
RUN install2.r \
    gargle \
    DBI \
    dbplyr \
    jsonlite \
    ellmer

# bigrquery pinned: R/functions.R (bq_dry_run_stats) calls its internal
# bq_post() and bq_path(), which may change between releases.
RUN R -e 'install.packages("remotes"); remotes::install_version("bigrquery", version = "1.6.2", upgrade = "never")'

# Install mcptools separately (has complex dependencies)
RUN R -e 'install.packages("mcptools", type = "source")'

COPY R /app/R
COPY server.R /app/server.R
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]