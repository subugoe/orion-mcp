#!/bin/sh
# A failed schema refresh must never stop the server, so no `set -e` here and
# the refresh runs in best-effort mode (see refresh-schemas.sh).

"$(dirname "$0")/refresh-schemas.sh" --best-effort || true

cd /app
exec Rscript server.R
