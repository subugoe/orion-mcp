FROM rocker/tidyverse
RUN echo 'options(repos = c(CRAN = "https://packagemanager.posit.co/cran/__linux__/jammy/latest"))' >> /usr/local/lib/R/etc/Rprofile.site

# Additional system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    cmake \
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

COPY server.R /server.R
COPY data/ /data/