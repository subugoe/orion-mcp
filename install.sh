#!/usr/bin/env bash
set -euo pipefail

IMAGE="ghcr.io/orion-dbs-community/orion-mcp:latest"
ADC_FILE="$HOME/.config/gcloud/application_default_credentials.json"

# ── colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${BOLD}$*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }
die()     { echo -e "${RED}✗ $*${RESET}" >&2; exit 1; }

echo ""
echo -e "${BOLD}ORION-DBs MCP Server — installer${RESET}"
echo "──────────────────────────────────"
echo ""

# ── 1. Check Docker ────────────────────────────────────────────────────────────
info "Checking Docker..."
if ! command -v docker &>/dev/null; then
  die "Docker is not installed. Install Docker Desktop from https://www.docker.com/products/docker-desktop/ and re-run this script."
fi
if ! docker info &>/dev/null 2>&1; then
  die "Docker is installed but not running. Please start Docker Desktop and re-run this script."
fi
success "Docker is running."

# ── 2. Check gcloud ────────────────────────────────────────────────────────────
info "Checking Google Cloud CLI..."
if ! command -v gcloud &>/dev/null; then
  die "gcloud CLI is not installed. Install it from https://cloud.google.com/sdk/docs/install and re-run this script."
fi
success "gcloud CLI found."

# ── 3. Check Application Default Credentials ───────────────────────────────────
info "Checking Google Cloud credentials..."
if [ ! -f "$ADC_FILE" ]; then
  echo ""
  warn "No Application Default Credentials found."
  echo ""
  echo "  Run the following command, then re-run this installer:"
  echo ""
  echo -e "  ${BOLD}gcloud auth application-default login \\${RESET}"
  echo -e "  ${BOLD}  --scopes=https://www.googleapis.com/auth/bigquery.readonly${RESET}"
  echo ""
  echo "  This limits the credentials to read-only BigQuery access."
  echo ""
  exit 1
fi
success "Application Default Credentials found."

# ── 4. Pull Docker image ───────────────────────────────────────────────────────
info "Pulling Docker image..."
if docker pull "$IMAGE"; then
  success "Image pulled: $IMAGE"
else
  warn "Could not pull from registry. Attempting local build..."
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "$SCRIPT_DIR/Dockerfile" ]; then
    docker build -t orion-mcp_mcp "$SCRIPT_DIR"
    IMAGE="orion-mcp_mcp"
    success "Local image built: $IMAGE"
  else
    die "Could not pull image and no Dockerfile found. Please check your internet connection or clone the repo first."
  fi
fi

# ── 5. Billing project ─────────────────────────────────────────────────────────
echo ""
echo "A GCP billing project is required to run SQL queries (dataset browsing works without one)."
echo "You can find your project ID at https://console.cloud.google.com/"
echo ""
read -r -p "Enter your GCP billing project ID (leave blank to skip): " BQ_PROJECT
BQ_PROJECT="${BQ_PROJECT:-}"

# ── 6. Detect OS and set paths ─────────────────────────────────────────────────
OS="$(uname -s)"
case "$OS" in
  Darwin)
    CONFIG_DIR="$HOME/Library/Application Support/Claude"
    GCLOUD_MOUNT="/Users/$USER/.config/gcloud"
    ;;
  Linux)
    CONFIG_DIR="$HOME/.config/Claude"
    GCLOUD_MOUNT="/home/$USER/.config/gcloud"
    ;;
  *)
    die "Unsupported OS: $OS. Please follow the manual setup instructions in the README."
    ;;
esac

CONFIG_FILE="$CONFIG_DIR/claude_desktop_config.json"

# ── 7. Ensure config file exists ───────────────────────────────────────────────
mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_FILE" ]; then
  echo '{"mcpServers":{}}' > "$CONFIG_FILE"
fi

# ── 8. Merge orion-dbs entry ───────────────────────────────────────────────────
info "Writing MCP server config..."

python3 - "$CONFIG_FILE" "$IMAGE" "$GCLOUD_MOUNT" "$BQ_PROJECT" <<'PYEOF'
import json, sys

config_path, image, gcloud_mount, bq_project = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

with open(config_path, "r") as f:
    cfg = json.load(f)

cfg.setdefault("mcpServers", {})

args = [
    "run", "--rm", "-i",
    "-v", f"{gcloud_mount}:/root/.config/gcloud:ro",
    "-e", "SCHEMA_DIR=/data",
]
if bq_project:
    args += ["-e", f"BQ_BILLING_PROJECT={bq_project}"]
args.append(image)

cfg["mcpServers"]["orion-dbs"] = {
    "command": "docker",
    "args": args
}

with open(config_path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")

PYEOF

success "Config written to: $CONFIG_FILE"

# ── 9. Done ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Installation complete!${RESET}"
echo ""
echo "  Next step: quit and reopen Claude Desktop."
echo "  Then check Settings → Developer → MCP Servers — you should see 'orion-dbs'."
echo ""
if [ -z "$BQ_PROJECT" ]; then
  warn "No billing project set. You can browse schemas without one, but query execution will be unavailable."
  echo "  To add it later, re-run this installer or edit $CONFIG_FILE manually."
  echo ""
fi
