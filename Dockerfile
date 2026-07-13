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
    bigrquery \
    gargle \
    DBI \
    dbplyr \
    jsonlite \
    ellmer

# Install mcptools separately (has complex dependencies)
RUN R -e 'install.packages("mcptools", type = "source")'

COPY R /app/R
COPY server.R /app/server.R
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]