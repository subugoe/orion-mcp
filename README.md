# ORION-DBs MCP Server

Connects Claude Desktop to the [ORION-DBs](https://orion-dbs.community/) collection on Google BigQuery, so you can explore open research information datasets (OpenAlex, Crossref, ORCID, DataCite, and more) by asking questions in plain language.

## What it does

Claude can list datasets, inspect table schemas, estimate query costs, and run SQL queries.

| Function | Description | GCP Account Required |
|----------|-------------|---------------------|
| `orion_list_datasets` | List all available datasets in ORION-DBs | ❌ No |
| `orion_list_tables` | Display all tables in a specific dataset | ❌ No |
| `orion_get_db_schema` | Inspect the full schema of a table | ❌ No |
| `orion_estimate_query_cost` | Estimate bytes scanned (and cost) before running a query | ✅ Yes |
| `orion_run_bq_query` | Execute a SQL query against BigQuery | ✅ Yes |

## Security

**Does this give Claude access to my files?**
No. The MCP server runs in an isolated Docker container with no access to your filesystem. The only thing shared with the container is your Google Cloud credentials directory (`~/.config/gcloud`), mounted read-only so the server can authenticate to BigQuery.

**Can Claude read my private BigQuery datasets?**
Only if you tell it their names — Claude has no way to enumerate your private datasets. Note that accessing a private dataset requires both the right OAuth scope *and* the `roles/bigquery.dataViewer` IAM role on that dataset. The installer sets up credentials with the `bigquery.readonly` scope, which is the minimum needed to run queries. For your own GCP projects, your account likely already has the necessary IAM role, so if Claude were given a private dataset name it could query it. The practical protection is that Claude only knows what you tell it.

**Can it run up a big BigQuery bill without me knowing?**
No. Every query is preceded by a free dry-run that estimates the cost. Claude is instructed to present the estimate and wait for your explicit confirmation before executing. `SELECT *` queries are blocked entirely.

**Do query results leave my machine?**
Results appear in your Claude conversation — the same as anything else you discuss with Claude. They are not sent anywhere else.

## Quick start

**Prerequisites:** [Docker Desktop](https://www.docker.com/products/docker-desktop/), [Claude Desktop](https://claude.ai/download), [gcloud CLI](https://cloud.google.com/sdk/docs/install)

**1. Authenticate with Google Cloud**

```bash
gcloud auth application-default login \
  --scopes=https://www.googleapis.com/auth/bigquery.readonly
```

This opens a browser window and stores credentials in `~/.config/gcloud/`. You only need to do this once. The `bigquery.readonly` scope limits access to read-only BigQuery operations.

**2. Run the installer**

```bash
curl -fsSL https://raw.githubusercontent.com/orion-dbs-community/orion-mcp/main/install.sh | bash
```

Or, if you have already cloned the repo:

```bash
./install.sh
```

The installer will:
- Check Docker and gcloud are available
- Pull the pre-built Docker image
- Ask for your GCP billing project ID (needed to run queries; leave blank to skip)
- Write the MCP server entry into your Claude Desktop config

**3. Restart Claude Desktop**

Quit and reopen Claude Desktop. You should see **orion-dbs** listed under Settings → Developer → MCP Servers.

<details>
<summary>Manual setup (advanced / Windows)</summary>

### 1. Authenticate

```bash
gcloud auth application-default login \
  --scopes=https://www.googleapis.com/auth/bigquery.readonly
```

### 2. Pull the image

```bash
docker pull ghcr.io/orion-dbs-community/orion-mcp:latest
```

### 3. Edit Claude Desktop config

#### macOS — `~/Library/Application Support/Claude/claude_desktop_config.json`

```json
{
  "mcpServers": {
    "orion-dbs": {
      "command": "docker",
      "args": [
        "run", "--rm", "-i",
        "-v", "/Users/YOUR_USERNAME/.config/gcloud:/root/.config/gcloud:ro",
        "-e", "SCHEMA_DIR=/data",
        "-e", "BQ_BILLING_PROJECT=YOUR_PROJECT_ID",
        "ghcr.io/orion-dbs-community/orion-mcp:latest"
      ]
    }
  }
}
```

#### Linux — `~/.config/Claude/claude_desktop_config.json`

```json
{
  "mcpServers": {
    "orion-dbs": {
      "command": "docker",
      "args": [
        "run", "--rm", "-i",
        "-v", "/home/YOUR_USERNAME/.config/gcloud:/root/.config/gcloud:ro",
        "-e", "SCHEMA_DIR=/data",
        "-e", "BQ_BILLING_PROJECT=YOUR_PROJECT_ID",
        "ghcr.io/orion-dbs-community/orion-mcp:latest"
      ]
    }
  }
}
```

Replace `YOUR_USERNAME` with your username and `YOUR_PROJECT_ID` with your GCP project ID.

### 4. Restart Claude Desktop

</details>

## Usage

Ask Claude in plain language:

**No Google Cloud account required**
- *"What datasets are available in ORION-DBs?"*
- *"Show me the schema for the Crossref works table."*
- *"Which versions of OpenAlex are available and how do the schemas compare?"*

**Google Cloud account required**
- *"How many publications were published by University of Göttingen researchers between 2021 and 2025 in journals?"*
- *"How many open access articles were published in 2023, broken down by OA type?"*

## Cost and safety

BigQuery bills by bytes scanned (not rows returned). Two safeguards are built in:

- **Dry-run before every query** — Claude always calls `orion_estimate_query_cost` first and reports how many GB the query will scan. It will not proceed without your explicit confirmation.
- **No `SELECT *`** — queries that select all columns are blocked. Naming only the columns needed is the main lever for controlling cost.

The [BigQuery sandbox](https://cloud.google.com/bigquery/docs/sandbox) gives every account 1 TB of free queries per month.

## How authentication works

The MCP server runs in a Docker container and authenticates via Application Default Credentials (ADC): your local `gcloud` credentials are mounted read-only into the container. No service account keys are created or shared.

## Contributing / local development

To build the image locally instead of pulling from the registry:

```bash
git clone https://github.com/orion-dbs-community/orion-mcp
cd orion-mcp
docker build -t orion-mcp_mcp .
```

Then update the image name in your Claude Desktop config to `orion-mcp_mcp`.

If you pull new changes, rebuild before restarting Claude Desktop:

```bash
docker build -t orion-mcp_mcp .
```
