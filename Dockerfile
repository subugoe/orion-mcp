FROM rocker/tidyverse:4.5.3

# Add r2u binary package repo
RUN wget -q -O /etc/apt/trusted.gpg.d/cranapt_key.asc \
    https://r2u.stat.illinois.edu/ubuntu/KEY.gpg && \
    echo "deb [arch=amd64,arm64] https://r2u.stat.illinois.edu/ubuntu jammy main" \
    > /etc/apt/sources.list.d/cranapt.list && \
    apt-get update

# Now install R packages as binaries via apt
RUN apt-get install -y --no-install-recommends \
    r-cran-bigrquery r-cran-gargle r-cran-dbi \
    r-cran-dbplyr r-cran-jsonlite r-cran-ellmer \
    && rm -rf /var/lib/apt/lists/*

# Install mcptools separately (has complex dependencies)
RUN R -e 'install.packages("mcptools", type = "source")'

COPY server.R /server.R
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]