# orion-mcp: MCP server for ORION-DBs collections

`orion-mcp` lets you query the [ORION-DBs](https://orion-dbs.community/) collections on Google BigQuery by talking to an LLM such as Claude. The collections hold open research information from OpenAlex, Crossref, OpenAIRE, ORCID, DataCite and other sources.

It is a [Model Context Protocol (MCP) server](https://modelcontextprotocol.io/docs/getting-started/intro): a small program that runs on your computer and gives the LLM a set of tools. It is an early, experimental implementation. A [blog post](https://subugoe.github.io/scholcomm_analytics/posts/orion_mcp_intro/) walks through an example session, and Aaron Tay gives [broader context on LLMs and academic MCP servers](https://aarontay.substack.com/p/creating-your-own-research-assistant).

Feedback and contributions are welcome via GitHub issues.

## What happens when you ask a question

1. The LLM looks up which datasets and tables exist and reads the schema of the tables it needs. This uses schema files published by the ORION-DBs website. It needs no Google account and costs nothing.
2. It writes a BigQuery SQL query and asks BigQuery for a dry run. The dry run is free. It checks the SQL and reports how much data the query would scan.
3. It shows you the SQL, the amount of data and the estimated cost, and asks whether to run it.
4. After you agree, the query runs on BigQuery in your own Google Cloud project. The full result is kept on your computer under a name (`q1`, `q2`, ...). The LLM receives a preview.
5. You can ask follow-up questions about a stored result (summaries, counts, subsets) or export it to a file. Neither queries BigQuery again, so both are free.

## What runs where

| Part | Where | What it does |
|---|---|---|
| Claude Desktop | Your computer | The chat. Starts `orion-mcp` and calls its tools. |
| `orion-mcp` | A Docker container on your computer | Holds the schema files, talks to BigQuery with your Google login, keeps query results, writes exports. |
| BigQuery | Google Cloud | Runs the SQL. Scans are billed to your project. |
| The LLM | Its provider (for Claude: Anthropic) | Sees your questions, the table schemas, the SQL, and a size-capped preview of each result. It does not see your Google login or the full results. |

The container can read one file from your computer (your Google login file, read-only) and write to one folder (for exports). It has no other access to your files.

## What you need

- [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- [Claude Desktop](https://claude.ai/download)
- To run queries: the [gcloud CLI](https://cloud.google.com/sdk/docs/install) and a [Google Cloud project](https://cloud.google.com/resource-manager/docs/creating-managing-projects). Looking at datasets and schemas works without them.

The steps below were tested on macOS. Paths for Linux are given. Windows has not been tested.

## Set up with Claude Desktop

### 1. Log in to Google Cloud

```bash
gcloud auth application-default login
```

A browser window opens. Afterwards your login is stored in `~/.config/gcloud/application_default_credentials.json`. You do this once.

Do this step before step 4. If the file does not exist when the server first starts, Docker creates an empty folder with that name in its place, and the login then fails until you delete that folder.

### 2. Download the server

Open Docker Desktop and wait until it is running. Then:

```bash
docker pull ghcr.io/subugoe/orion-mcp:latest
```

### 3. Create a folder for exports

```bash
mkdir -p ~/Downloads/orion-exports
```

Files you ask Claude to export will appear here. Any folder works; use the same path in step 4.

### 4. Add the server to Claude Desktop

In Claude Desktop, open **Settings > Developer > Edit Config**. This shows the file `claude_desktop_config.json`. Open it in a text editor. If the menu entry is missing, the file is here:

- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
- Linux: `~/.config/Claude/claude_desktop_config.json`

On macOS, `Library` is a hidden folder. This opens the file from the Terminal:

```bash
open ~/Library/Application\ Support/Claude/claude_desktop_config.json
```

Add the `orion-dbs` entry inside `mcpServers`:

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

- `YOUR_USERNAME` with your user name, in both lines. On Linux the paths start with `/home/YOUR_USERNAME/`.
- `YOUR_PROJECT_ID` with your Google Cloud project ID, for example `my-project-123456`. The [Google Cloud Console](https://console.cloud.google.com/) shows it in the project selector in the top bar.

If the file already lists other servers, put a comma after the previous entry. A missing or extra comma makes the file invalid.

What the lines mean:

- The first `-v` line gives the container your Google login file, read-only.
- The second `-v` line connects your export folder to `/data/exports` inside the container.
- The `-e` line names the project that is billed for your queries.

### 5. Restart Claude Desktop and check

Quit Claude Desktop completely and open it again. **orion-dbs** should be listed under **Settings > Developer**. Then ask in a new chat:

> Is orion-dbs working? Check my setup.

This runs a free check of five things: schema files, Google login, billing project, connection to BigQuery, and the export folder. If one of them fails, Claude tells you what to change. Run it again whenever queries stop working.

Claude Desktop asks for your permission when a tool is used. Tools that only read are marked as read-only. Keep the question switched on for the tools that run billed queries or write tables (see [Tools](#tools)).

### Without a Google account

To look at datasets and schemas only, this shorter entry is enough. Steps 1 and 3 are not needed.

```json
{
  "mcpServers": {
    "orion-dbs": {
      "command": "docker",
      "args": ["run", "--rm", "-i", "ghcr.io/subugoe/orion-mcp:latest"]
    }
  }
}
```

### Other applications

Any MCP client that can start a local command can use the same `docker run` command. We use it with Claude Desktop and with [orion-chat](https://github.com/subugoe/orion-chat).

## Using it

Ask in plain language.

Without a Google account:

- *What datasets are available in ORION-DBs?*
- *Show me the schema for the Crossref works table.*
- *Which versions of OpenAlex are available and how do the schemas compare?*

With a Google Cloud project:

- *How many publications were published by University of Göttingen researchers between 2021 and 2025 in journals?*
- *How many open access articles were published in 2023, broken down by OA type?*

After a query has run, without paying for another one:

- *Break that down by year.*
- *Show me only the rows for 2023.*
- *Give me a summary of the columns. How many missing values are there?*
- *Export the result as a CSV file.*

Read the SQL before you agree to run it. The dry run checks that the query is valid, not that it answers your question.

## Costs

BigQuery bills by the amount of data a query scans, not by the rows it returns. The estimate uses the approximate on-demand rate of $6.25 per TiB (2^40 bytes, about 1,100 GB). Your rate can differ, for example by region or contract. Every account has 1 TiB of query processing free per month ([BigQuery pricing](https://cloud.google.com/bigquery/pricing)).

The session in the blog post, five queries and an export, scanned about 46 GB, which is under $0.30.

Naming only the columns you need keeps the scan small. For this reason the server refuses `SELECT *` (also `SELECT DISTINCT *` and `table.*`) at the estimate, before you are asked to confirm.

After each run the server reports the amount BigQuery billed. A query repeated unchanged within 24 hours is served from BigQuery's cache at no cost. The use of your LLM is paid for separately, for example through a Claude subscription.

## Exports

When you ask for an export, the server writes the file to `/data/exports` inside the container. The second `-v` line in the config connects that folder to `~/Downloads/orion-exports` on your computer, so the file appears there. Without this line, exported files are lost when the container stops. The export tool and the setup check both warn you if it is missing.

- Flat results are written as `.csv`, nested results as `.json`.
- Each export of a query result comes with a second file of the same name ending in `.sql`. It holds the SQL that produced the data and a header with the date the query ran, the rows returned and the GB billed. You can cite it in a methods section or run it again later.
- Files always go directly into the export folder. A requested file name is reduced to its bare name, and an existing file is not overwritten; a number is appended instead (`results_1.csv` and `results_1.sql`).

## Safeguards

### Read-only SQL

The server runs only single `SELECT` statements. Data-modifying SQL (`INSERT`, `UPDATE`, `DELETE`, `CREATE`, `DROP`, ...) and scripts with several statements are refused in two ways: the server checks the SQL itself, and the dry run must report BigQuery's own classification of the statement as `SELECT`. This holds whatever your Google login would allow. A personal gcloud login cannot be limited to read-only access, so the server does not rely on it; a service account gets the read-only scope.

### Estimate before run

A query can only run if the same SQL has had a dry run in the current session. Line breaks, spacing and comments may differ; any other difference counts as a new query and needs its own estimate. Whether to run it is your decision in the chat.

### Cost limits

The estimate refuses queries that would scan more than 500 GB (`MAX_GB_PER_QUERY`). Each run is sent to BigQuery with a cap taken from its estimate, so BigQuery stops a job without charge if it would bill more than you were shown. Jobs carry the label `tool: orion-mcp`, which you can filter on in the Google Cloud billing export.

### Result size

Results with more than 1,000,000 rows are not downloaded (`MAX_DOWNLOAD_ROWS`). The query is still billed. Aggregate or filter it, or keep the result in BigQuery with `orion_query_to_table`.

### Writing to BigQuery

Only two tools can write to BigQuery, never SQL. In both, the destination table is an explicit argument that you confirm in the chat. Both refuse to touch an existing table unless you ask to overwrite it, and both are limited by your own permissions in Google Cloud.

### What the LLM provider sees

Your questions, the table schemas, the SQL, a preview of each result (up to about 60,000 characters), and the output of the summary, count and slice tools. The full results stay in the container and in the files you export.

## Tools

| Tool | What it does | Cost |
|---|---|---|
| `orion_health_check` | Checks the setup | Free |
| `orion_list_datasets`, `orion_list_tables`, `orion_get_db_schema` | Look up datasets, tables and columns | Free, no Google account |
| `orion_estimate_query_cost` | Dry run: checks the SQL and estimates the scan | Free |
| `orion_run_bq_query` | Runs a query and stores the result | Billed |
| `orion_export_bq_query` | Runs a query and writes the result straight to a file | Billed |
| `orion_result_summary`, `orion_result_count`, `orion_result_slice` | Work on a stored result | Free |
| `orion_export_result` | Writes a stored result to a file | Free |
| `orion_query_to_table` | Runs a query and writes the result to a BigQuery table | Billed; writes to your project |
| `orion_save_result_to_bq` | Uploads a stored result as a BigQuery table | Free; writes to your project |

The server keeps the 20 most recent results and drops older ones. Asking for a dropped result gives a message that says so. Running its query again stores it under a new name and is billed again, unless BigQuery serves it from its cache. All stored results are gone when Claude Desktop is closed.

## Settings

All settings are optional, except the billing project for running queries. Add them to the config as a further pair before the image name, for example `"-e", "MAX_GB_PER_QUERY=50",`.

| Variable | Default | Meaning |
|---|---|---|
| `BQ_BILLING_PROJECT` | none | Google Cloud project billed for queries. Without it, only schema browsing works. |
| `MAX_GB_PER_QUERY` | `500` | Largest scan the estimate accepts, in GB. |
| `MAX_DOWNLOAD_ROWS` | `1000000` | Largest result that is downloaded, in rows. |
| `MAX_RESULT_CHARS` | `60000` | Size of the result preview sent to the LLM, in characters. |
| `MAX_STORED_RESULTS` | `20` | Number of results kept in the session. |
| `SCHEMA_REFRESH` | `1` | `0` skips the download of schema files at start-up. |
| `SCHEMA_REPO`, `SCHEMA_PATH` | `orion-dbs-community/website`, `data` | GitHub repository and folder the schema files come from. |
| `EXPORT_DIR` | `/data/exports` | Export folder inside the container. |

### Schema files

The image contains the schema files from the day it was built, and it is rebuilt daily. At start-up the server also downloads the current files. If that fails, it uses the ones in the image. With `SCHEMA_REFRESH=0` the server starts in about a second and works without a network connection for schema browsing.

## Updating

```bash
docker pull ghcr.io/subugoe/orion-mcp:latest
```

Then quit and reopen Claude Desktop.

## Troubleshooting

**orion-dbs is not listed, or shows an error, in Claude Desktop.**

- Check that Docker Desktop is running.
- Check the config file for a missing comma or bracket.
- If Claude Desktop cannot find `docker`, replace `"docker"` in `"command"` with its full path. `which docker` in the Terminal shows it, for example `/usr/local/bin/docker`.

**The setup check reports missing Google credentials.**

- Run `gcloud auth application-default login` again, then restart Claude Desktop.
- Look at `~/.config/gcloud/`. If `application_default_credentials.json` is a folder and not a file, delete the folder and log in again (see step 1).
- Check the user name in the first `-v` line.

**Queries fail although the login works.**

- Check `BQ_BILLING_PROJECT`: it must be the project ID, not the project name.
- The BigQuery API must be enabled for the project in the Google Cloud Console.

**An exported file does not appear.**

- Check that the folder in the second `-v` line exists and that the path is spelled as in step 3.

**A query is refused as too large.**

- Ask for fewer columns or a filter, or raise `MAX_GB_PER_QUERY`.

If Claude misunderstands your question, returns unexpected results or picks the wrong dataset, please open a GitHub issue that says what you asked and what happened. We use these reports to improve the tool descriptions that guide the LLM.

## Development

To build the image yourself:

```bash
git clone https://github.com/subugoe/orion-mcp
cd orion-mcp
docker build -t orion-mcp:dev .
```

Then use `orion-mcp:dev` as the image name in the config.

The server logic is in `R/functions.R`. `server.R` handles the Google login and registers the MCP tools. `refresh-schemas.sh` downloads the schema files, at build time and at start-up. The server is written in R with [ellmer](https://ellmer.tidyverse.org/), [mcptools](https://github.com/posit-dev/mcptools) and [bigrquery](https://bigrquery.r-dbi.org/).

Run the tests from the repository root before opening a pull request:

```bash
Rscript tests/test-functions.R
```

They need the R packages `testthat`, `dplyr`, `purrr`, `stringr`, `readr`, `tibble`, `glue`, `jsonlite` and `bigrquery`, and `curl` and `jq` for the schema refresh script. The same tests run on every pull request and must pass before an image is published. They cover everything except the exchange with BigQuery itself, which the setup check verifies on your machine.

## Contact

Najko Jahn (najko.jahn@sub.uni-goettingen.de), Göttingen State and University Library.
