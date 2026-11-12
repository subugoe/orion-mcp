#!/bin/sh
# Download the ORION-DBs schema files (collection_info_*.jsonl) into SCHEMA_DIR.
#
# The files go to a temporary directory first. SCHEMA_DIR is touched only
# when every file arrived and holds non-empty, valid JSON lines, so an
# interrupted or partial download leaves the previous files in place.
#
#   refresh-schemas.sh                strict: exit 1 on any failure (image build)
#   refresh-schemas.sh --best-effort  start-up: print one line to stderr on
#                                     failure and exit 0, so the server starts
#                                     with the files already in SCHEMA_DIR.
#                                     Does nothing when SCHEMA_REFRESH=0.
#
# GITHUB_TOKEN (optional) raises the GitHub API rate limit from 60 requests
# per hour per IP address, which CI runners and campus networks can exceed.
# SCHEMA_API_URL exists so the tests can point the script at a local file.

SCHEMA_REPO="${SCHEMA_REPO:-orion-dbs-community/website}"
SCHEMA_PATH="${SCHEMA_PATH:-data}"
SCHEMA_API_URL="${SCHEMA_API_URL:-https://api.github.com}"
DATA_DIR="${SCHEMA_DIR:-/data}"

best_effort=0
[ "${1:-}" = "--best-effort" ] && best_effort=1

if [ "$best_effort" = 1 ] && [ "${SCHEMA_REFRESH:-1}" = "0" ]; then
  echo "SCHEMA_REFRESH=0: using the schemas already in ${DATA_DIR}." >&2
  exit 0
fi

tmp=""
cleanup() { [ -n "$tmp" ] && rm -rf "$tmp"; }
trap cleanup EXIT

# Print one line to stderr and stop. Exit status depends on the mode.
give_up() {
  echo "Schema refresh failed: $1. Keeping the schemas in ${DATA_DIR}." >&2
  [ "$best_effort" = 1 ] && exit 0
  exit 1
}

command -v curl >/dev/null 2>&1 || give_up "curl is not installed"
command -v jq >/dev/null 2>&1 || give_up "jq is not installed"

echo "Fetching schemas from github.com/${SCHEMA_REPO}/${SCHEMA_PATH} ..." >&2

mkdir -p "$DATA_DIR" 2>/dev/null || give_up "cannot create ${DATA_DIR}"
# Inside DATA_DIR so the final mv stays on one filesystem (atomic per file)
tmp=$(mktemp -d "${DATA_DIR}/.refresh.XXXXXX" 2>/dev/null) \
  || give_up "${DATA_DIR} is not writable"

listing=$(curl -sf --max-time 30 --retry 2 \
  ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} \
  "${SCHEMA_API_URL}/repos/${SCHEMA_REPO}/contents/${SCHEMA_PATH}") \
  || give_up "could not list files in ${SCHEMA_REPO}"

urls=$(printf '%s' "$listing" \
  | jq -r '.[] | select(.name | endswith(".jsonl")) | .download_url' 2>/dev/null) \
  || give_up "unexpected response from ${SCHEMA_API_URL}"
[ -n "$urls" ] || give_up "no .jsonl files found in ${SCHEMA_REPO}/${SCHEMA_PATH}"

names=""
for url in $urls; do
  name=$(basename "$url")
  case "$name" in
    *.jsonl) ;;
    *) give_up "unexpected file name ${name}" ;;
  esac
  curl -sf --max-time 120 --retry 2 "$url" -o "${tmp}/${name}" \
    || give_up "could not download ${name}"
  [ -s "${tmp}/${name}" ] || give_up "${name} is empty"
  # Every line must be a JSON object; jq exits non-zero on a parse error.
  jq -en '[inputs | type == "object"] | length > 0 and all' \
    "${tmp}/${name}" >/dev/null 2>&1 \
    || give_up "${name} is not valid JSON lines"
  names="${names} ${name}"
  echo "  -> ${name}" >&2
done

# Everything arrived and parses: replace the files.
for name in $names; do
  mv -f "${tmp}/${name}" "${DATA_DIR}/${name}" \
    || give_up "could not write ${name} to ${DATA_DIR}"
done
# Drop collections that no longer exist upstream
for old in "$DATA_DIR"/*.jsonl; do
  [ -e "$old" ] || continue
  case "$names " in
    *" $(basename "$old") "*) ;;
    *) rm -f "$old" ;;
  esac
done

echo "Schema refresh complete." >&2
