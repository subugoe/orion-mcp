# ORION-DBs MCP Server

`orion-mcp` is a [Model Context Protocol (MCP) server](https://modelcontextprotocol.io/docs/getting-started/intro) that lets you query the [ORION-DBs](https://orion-dbs.community/) collections on Google BigQuery using natural language. They support OpenAlex, Crossref, ORCID, DataCite, and more.

This implementation is experimental. Please feel free to contribute via GitHub issues.

Aaron Tay's [Creating your own research assistant with Claude](https://aarontay.substack.com/p/creating-your-own-research-assistant) gives a good overview of how Claude Desktop and MCP servers can support research and library workflows. `orion-mcp` is a specific implementation focused on open research information databases.

## How it works

`orion-mcp` loads ORION-DBs schema metadata (column names, types, and descriptions) into the LLM context. When you ask a question, the LLM writes a BigQuery SQL query, runs a free dry run to estimate cost, and executes it after your confirmation. Results can be downloaded and analysed locally.

The tool does not send raw data to the LLM provider; it only shares SQL queries. The MCP server runs in an isolated Docker container with no access to your file system. The only information passed to the container is your Google Cloud credentials, used to authenticate with BigQuery via Application Default Credentials (ADC).

You can browse schema metadata without a Google Cloud account.

## Installation

**Prerequisites:** [Docker Desktop](https://www.docker.com/products/docker-desktop/), [Claude Desktop](https://claude.ai/download), [gcloud CLI](https://cloud.google.com/sdk/docs/install)

If you are new to Google Cloud, you will also need a [Google account and a Cloud project](https://cloud.google.com/resource-manager/docs/creating-managing-projects) to run queries. Schema browsing works without one.

### 1. Authenticate with Google Cloud

```bash
gcloud auth application-default login
```

This opens a browser window and saves credentials to `~/.config/gcloud/`. You only need to do this once. When the MCP server starts, it requests only a `bigquery.readonly` access token, the narrowest scope needed to run queries.

### 2. Pull the Docker image

Make sure Docker Desktop is open and running, then download the server image:

```bash
docker pull ghcr.io/orion-dbs-community/orion-mcp:latest
```

### 3. Add the server to Claude Desktop

Open your Claude Desktop config file in a text editor:

- **macOS:** `~/Library/Application Support/Claude/claude_desktop_config.json`
  > `Library` is a hidden folder. Open it from Terminal with:
  > ```bash
  > open ~/Library/Application\ Support/Claude/claude_desktop_config.json
  > ```
  > Or in Finder: **Go → Go to Folder** (`⇧⌘G`) and paste `~/Library/Application Support/Claude/`
- **Linux:** `~/.config/Claude/claude_desktop_config.json`

Add the `orion-dbs` entry inside `mcpServers`. If the file already contains other servers, add a comma after the last entry before adding this one, as JSON is strict about commas.

```json
{
  "mcpServers": {
    "orion-dbs": {
      "command": "docker",
      "args": [
        "run", "--rm", "-i",
        "-v", "/Users/YOUR_USERNAME/.config/gcloud:/root/.config/gcloud:ro",
        "-e", "BQ_BILLING_PROJECT=YOUR_PROJECT_ID",
        "ghcr.io/orion-dbs-community/orion-mcp:latest"
      ]
    }
  }
}
```

Replace:
- `YOUR_USERNAME` — your macOS/Linux username (on Linux use `/home/YOUR_USERNAME/...`)
- `YOUR_PROJECT_ID` — your GCP project ID, e.g. `my-project-123456`. Find it in the [Google Cloud Console](https://console.cloud.google.com/) by clicking the project selector in the top bar.

> Schema browsing (`orion_list_datasets`, `orion_list_tables`, `orion_get_db_schema`) works without a billing project. You can omit the `BQ_BILLING_PROJECT` line entirely if you only want to explore schemas.

#### Accessing exported files

When you ask Claude to export query results, files are written to `/data/exports` **inside the container**. To access them on your machine, add a volume mount:

```json
{
  "mcpServers": {
    "orion-dbs": {
      "command": "docker",
      "args": [
        "run", "--rm", "-i",
        "-v", "/Users/YOUR_USERNAME/.config/gcloud:/root/.config/gcloud:ro",
        "-v", "/Users/YOUR_USERNAME/Downloads/orion-exports:/data/exports",
        "-e", "BQ_BILLING_PROJECT=YOUR_PROJECT_ID",
        "ghcr.io/orion-dbs-community/orion-mcp:latest"
      ]
    }
  }
}
```

The second `-v` line mounts `~/Downloads/orion-exports` on your machine to `/data/exports` in the container. Exported CSVs and JSON files will appear there. You can use any directory you like, just create it first (`mkdir ~/Downloads/orion-exports`).

To change the in-container export path, set the `EXPORT_DIR` environment variable (e.g. `-e EXPORT_DIR=/tmp/exports`).

### 4. Restart Claude Desktop

Quit and reopen Claude Desktop. You should see **orion-dbs** listed under **Settings → Developer → MCP Servers**. If it does not appear, double-check the JSON in your config file for missing commas or mismatched brackets.

## Usage

Ask Claude in plain language:

### No Google Cloud account required
- *"What datasets are available in ORION-DBs?"*
- *"Show me the schema for the Crossref works table."*
- *"Which versions of OpenAlex are available and how do the schemas compare?"*

### Google Cloud account required
- *"How many publications were published by University of Göttingen researchers between 2021 and 2025 in journals?"*
- *"How many open access articles were published in 2023, broken down by OA type?"*

## Cost and safety

BigQuery bills by bytes scanned (not rows returned). Two safeguards are built in:

- **Dry-run before every query** — Claude always calls `orion_estimate_query_cost` first and reports how many GB the query will scan. It will not proceed without your explicit confirmation.
- **No `SELECT *`** — queries that select all columns are blocked. Naming only the columns needed is the main lever for controlling cost.

The [BigQuery sandbox](https://cloud.google.com/bigquery/docs/sandbox) gives every account 1 TB of free queries per month.


## Contributing / local development

To build the image locally instead of pulling from the registry:

```bash
git clone https://github.com/orion-dbs-community/orion-mcp
cd orion-mcp
docker build -t orion-mcp_mcp .
```

Then use `orion-mcp_mcp` as the image name in your Claude Desktop config.

## Contact

Najko Jahn (najko.jahn@sub.uni-goettingen.de)
