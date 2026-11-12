# orion-mcp: MCP Server for ORION-DBs collections.

`orion-mcp` is a [Model Context Protocol (MCP) server](https://modelcontextprotocol.io/docs/getting-started/intro) that lets you query the [ORION-DBs](https://orion-dbs.community/) collections on Google BigQuery using an LLM. It supports OpenAlex, Crossref, ORCID, DataCite, and more. 
It is an early, experimental implementation focused on open research information. Aaron Tay's [broader context about the potential of LLMs in combination with academic MCP servers](https://aarontay.substack.com/p/creating-your-own-research-assistant) is a useful general introduction.

Contributions and feedback are welcome via GitHub issues.

## How it works

`orion-mcp` loads ORION-DBs schema metadata (column names, types, and descriptions) into the LLM context. When you ask a question, the LLM writes a BigQuery SQL query, shows it to you together with an estimate of how many GB it will scan, and asks for your confirmation before running it. Queries that select all columns (`SELECT *`, also `SELECT DISTINCT *` and `table.*`) are refused at the cost estimate, before you are asked to confirm. Naming only the columns you need keeps queries fast and costs low. Results can be downloaded and analysed locally.

Query results of any size are kept **in the local R session** (named `q1`, `q2`, ...) — only a size-capped preview is sent to the LLM, so large results never overflow the conversation. The LLM can then analyse the full result by reference using built-in tools (`orion_result_summary`, `orion_result_count`, `orion_result_slice`) or write it to a file with `orion_export_result` — all without re-querying BigQuery, so follow-up questions and exports are free. After each run, the actual amount billed is reported back (including when BigQuery served the query from its 24-hour cache at no cost). The preview budget defaults to ~60,000 characters (sized to fit typical MCP client limits) and can be changed with the `MAX_RESULT_CHARS` environment variable (e.g. `-e MAX_RESULT_CHARS=200000`). The session keeps the 20 most recent results and drops older ones, so that memory use stays bounded; set `MAX_STORED_RESULTS` to change the number. Asking for a dropped result gives a message that says so; running its query again stores the result under a new name, and is billed again unless BigQuery serves it from its cache.

Two more environment variables set hard limits:

- `MAX_GB_PER_QUERY` (default `500`): the cost estimate refuses queries that would scan more than this many GB. Each run is also sent to BigQuery with `maximumBytesBilled` set from its estimate (plus BigQuery's 10 MB minimum per table), so BigQuery stops a job without charge if it would bill more than the estimate allows. Jobs carry the label `tool: orion-mcp`, which you can filter on in the Google Cloud billing export.
- `MAX_DOWNLOAD_ROWS` (default `1000000`): results with more rows are not downloaded into the R session. The query is still billed; aggregate or filter it, or use `orion_query_to_table` to keep the result in BigQuery.

The model, and so the LLM provider, sees the table schemas, the SQL, and a size-capped preview of each result, as well as the output of `orion_result_summary`, `orion_result_count` and `orion_result_slice`. The full result stays in the server's R session and in the files you export. The MCP server runs in an isolated Docker container with no access to your file system. The only file passed to the container is your Application Default Credentials file (`application_default_credentials.json`, mounted read-only), used to authenticate with BigQuery.

Schema metadata is part of the image. The image is rebuilt daily from the schema files that the ORION-DBs website publishes, and at start-up the server tries to download the current files. If that download fails, or is incomplete, the files in the image are used and one line is printed to the container's stderr. Set `SCHEMA_REFRESH=0` (e.g. `-e SCHEMA_REFRESH=0`) to skip the download; the server then starts faster and works offline with the schemas from the image. `SCHEMA_REPO` and `SCHEMA_PATH` change where the files come from.

You can browse schema metadata without a Google Cloud account.

## Installation

**Prerequisites:** [Docker Desktop](https://www.docker.com/products/docker-desktop/), [Claude Desktop](https://claude.ai/download), [gcloud CLI](https://cloud.google.com/sdk/docs/install)

If you are new to Google Cloud, you will also need a [Google account and a Cloud project](https://cloud.google.com/resource-manager/docs/creating-managing-projects) to run queries. Schema browsing works without one.

### 1. Authenticate with Google Cloud

```bash
gcloud auth application-default login
```

This opens a browser window and saves your credentials to `~/.config/gcloud/application_default_credentials.json`. You only need to do this once. Step 3 mounts only this file into the container, not the rest of `~/.config/gcloud/`. When the MCP server starts, it requests the narrowest access scope your credential type supports: `bigquery.readonly` where possible (service accounts), otherwise the standard BigQuery scope — gcloud user credentials do not support the read-only scope.

Regardless of what the credentials would allow, **the server enforces read-only SQL itself**: it executes only single `SELECT` statements. Data-modifying SQL (`INSERT`, `UPDATE`, `DELETE`, `CREATE`, `DROP`, multi-statement scripts, ...) is rejected before it runs: the server checks the SQL itself, and the free dry run must report BigQuery's statement type as `SELECT`.

Writing is still possible — but only through two dedicated tools where the destination table is an explicit argument you confirm in the conversation, never through SQL: `orion_save_result_to_bq` uploads an already-run result as a table (a free load job), and `orion_query_to_table` writes large query results directly to a table in your project without downloading them (only the query scan is billed). Both refuse to touch an existing table unless you explicitly ask to overwrite it, and both are bounded by your own IAM permissions.

### 2. Pull the Docker image

Make sure Docker Desktop is open and running, then download the server image:

```bash
docker pull ghcr.io/subugoe/orion-mcp:latest
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

First create the folder where exported query results will appear on your machine:

```bash
mkdir -p ~/Downloads/orion-exports
```

Then add the `orion-dbs` entry inside `mcpServers`. If the file already contains other servers, add a comma after the last entry before adding this one, as JSON is strict about commas.

```json
{
  "mcpServers": {
    "orion-dbs": {
      "command": "docker",
      "args": [
        "run", "--rm", "-i",
        "-v", "/Users/YOUR_USERNAME/.config/gcloud/application_default_credentials.json:/root/.config/gcloud/application_default_credentials.json:ro",
        "-v", "/Users/YOUR_USERNAME/Downloads/orion-exports:/data/exports",
        "-e", "BQ_BILLING_PROJECT=YOUR_PROJECT_ID",
        "ghcr.io/subugoe/orion-mcp:latest"
      ]
    }
  }
}
```

Replace:
- `YOUR_USERNAME` — your macOS/Linux username (on Linux use `/home/YOUR_USERNAME/...`)
- `YOUR_PROJECT_ID` — your GCP project ID, e.g. `my-project-123456`. Find it in the [Google Cloud Console](https://console.cloud.google.com/) by clicking the project selector in the top bar.

> Schema browsing (`orion_list_datasets`, `orion_list_tables`, `orion_get_db_schema`) works without a billing project. You can omit the `BQ_BILLING_PROJECT` line entirely if you only want to explore schemas.

BigQuery bills by bytes scanned, not rows returned. The cost estimate uses the approximate on-demand rate of $6.25 per TiB scanned (1 TiB = 2^40 bytes, about 1,100 GB); your actual rate can differ, for example by region or contract. The [BigQuery sandbox](https://cloud.google.com/bigquery/docs/sandbox) gives every account 1 TiB of free query processing per month.

#### How exports reach your machine

The container is isolated from your file system. When you ask Claude to export query results, files are written to `/data/exports` **inside the container**; the second `-v` line above maps that folder to `~/Downloads/orion-exports` on your machine, so exports appear there instantly. You can use any directory you like — but without this mount, exported files are lost when the container stops (the export tool and the *"check my setup"* health check will both warn you if the mount is missing).

Each export of a query result comes with a second file of the same name ending in `.sql` (for example `results.csv` and `results.sql`). It holds the SQL that produced the data, with a header comment giving the date the query ran, the rows returned and the GB billed, so you can cite the query in a methods section or run it again later.

Exports are always written directly into the export folder: a requested filename is reduced to its bare name, its extension is set to the format written (`.csv` for flat results, `.json` for nested ones), and an existing file is not overwritten; a number is appended instead (`results_1.csv` and `results_1.sql`).

To change the in-container export path, set the `EXPORT_DIR` environment variable (e.g. `-e EXPORT_DIR=/tmp/exports`).

### 4. Restart Claude Desktop

Quit and reopen Claude Desktop. You should see **orion-dbs** listed under **Settings → Developer → MCP Servers**. If it does not appear, double-check the JSON in your config file for missing commas or mismatched brackets.

## Usage

Ask Claude in plain language:

### Check your setup
- *"Is orion-dbs working? Check my setup."*

This runs a free end-to-end health check (schema metadata, credentials, billing project, BigQuery connectivity, export folder mount) and walks you through fixing anything that is missing. Run it once after installation, or whenever queries fail unexpectedly.

### No Google Cloud account required
- *"What datasets are available in ORION-DBs?"*
- *"Show me the schema for the Crossref works table."*
- *"Which versions of OpenAlex are available and how do the schemas compare?"*

### Google Cloud account required
- *"How many publications were published by University of Göttingen researchers between 2021 and 2025 in journals?"*
- *"How many open access articles were published in 2023, broken down by OA type?"*

After a query has run, you can keep digging into the stored result without paying for another query:
- *"Break that down by year."*
- *"Show me only the rows for 2023."*
- *"Give me a summary of the columns — how many missing values are there?"*


## Contributing / local development

To build the image locally instead of pulling from the registry:

```bash
git clone https://github.com/subugoe/orion-mcp
cd orion-mcp
docker build -t orion-mcp_mcp .
```

Then use `orion-mcp_mcp` as the image name in your Claude Desktop config.

The server logic lives in `R/functions.R`; `server.R` handles authentication and registers the MCP tools. Run the unit tests from the repo root before opening a pull request:

```bash
Rscript tests/test-functions.R
```

The tests need the R packages `testthat`, `dplyr`, `purrr`, `stringr`, `readr`, `tibble`, `glue`, `jsonlite` and `bigrquery`, plus `curl` and `jq` for the schema refresh script.

The same tests run in CI on every pull request and gate the image build, so a regression cannot reach the published image. They cover everything except the BigQuery round-trip itself, which the built-in health check (*"check my setup"*) verifies at install time.

The server is implemented in R using the [ellmer](https://ellmer.tidyverse.org/) and [mcptools](https://github.com/posit-dev/mcptools) packages. Contributions and bug reports are welcome via GitHub issues.

If Claude misunderstands your question, produces unexpected results, or queries the wrong dataset, please open a GitHub issue describing what you asked and what happened. That kind of feedback is just as valuable as code contributions, because it helps improve the tool descriptions that guide the LLM.

## Contact

Najko Jahn (najko.jahn@sub.uni-goettingen.de), Göttingen State and University Library.
