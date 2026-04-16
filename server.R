suppressPackageStartupMessages({
  library(ellmer)
  library(mcptools)
  library(tidyverse)
  library(jsonlite)
  library(DBI)
  library(bigrquery)
})

SCHEMA_DIR  <- Sys.getenv("SCHEMA_DIR", "/data")
EXPORT_DIR  <- Sys.getenv("EXPORT_DIR", "/data/exports")

# Use application default credentials (gcloud ADC mounted in Docker).
# Suppresses interactive OAuth prompts in non-interactive containers.
bq_auth(token = gargle::credentials_app_default(
  scopes = "https://www.googleapis.com/auth/bigquery.readonly"
))

read_jsonl <- function(path) {
  con <- file(path, "r")
  on.exit(close(con))
  stream_in(con, verbose = FALSE)
}

schema_data <-
  list.files(SCHEMA_DIR, full.names = TRUE, pattern = "\\.jsonl$") |>
  map(read_jsonl) |>
  list_rbind()


orion_list_datasets <- function() {
  schema_data |>
    summarise(
      dataset_description = first(dataset_description),
      tables = n(),
      .by = c(project, dataset)
    ) |>
    toJSON(auto_unbox = TRUE, pretty = TRUE)
}

orion_list_tables <- function(project, dataset) {
  schema_data |>
    filter(.data$project == .env$project, .data$dataset == .env$dataset) |>
    select(table, description) |>
    toJSON(auto_unbox = TRUE, pretty = TRUE)
}

orion_get_db_schema <- function(project, dataset, table) {
  result <- schema_data |>
    filter(
      .data$project == .env$project,
      .data$dataset == .env$dataset,
      .data$table == .env$table
    )

  if (nrow(result) == 0) stop("Not found: ", project, "/", dataset, "/", table)

  result$schema[[1]] |>
    toJSON(auto_unbox = TRUE, pretty = TRUE)
}

dry_run_cache <- character(0)

normalize_sql <- function(sql) gsub("\\s+", " ", trimws(sql))

orion_estimate_query_cost <- function(query) {
  billing <- Sys.getenv("BQ_BILLING_PROJECT")
  if (billing == "") stop("BQ_BILLING_PROJECT environment variable not set")

  bytes <- as.numeric(bq_perform_query_dry_run(query, billing = billing))
  gb <- round(bytes / 1e9, 3)

  dry_run_cache <<- unique(c(dry_run_cache, normalize_sql(query)))

  list(
    bytes_processed = bytes,
    gb_processed = gb,
    cost_usd_estimate = round(bytes / 1e12 * 6.25, 4),
    message = glue::glue(
      "This query will scan {gb} GB (estimated cost: ${round(bytes / 1e12 * 6.25, 4)}).",
      " Monthly free tier usage is unknown — do not assume the query is free.",
      " ALWAYS ask the user: 'Shall I run this query?' and wait for explicit confirmation before proceeding."
    )
  ) |> toJSON(auto_unbox = TRUE, pretty = TRUE)
}

.execute_bq_query <- function(sql) {
  if (!normalize_sql(sql) %in% dry_run_cache) {
    stop(
      "STOP. This exact SQL has not been dry-run. ",
      "Do NOT modify the SQL. ",
      "Call orion_estimate_query_cost with this exact SQL, ",
      "present the cost to the user, and wait for confirmation."
    )
  }

  if (grepl("SELECT\\s+\\*|\\w+\\.\\*", sql, ignore.case = TRUE)) {
    stop(
      "SELECT * and table.* are not allowed — ",
      "specify only the columns needed to avoid scanning unnecessary data."
    )
  }

  billing <- Sys.getenv("BQ_BILLING_PROJECT")
  if (billing == "") stop("BQ_BILLING_PROJECT environment variable not set")

  con <- dbConnect(bigquery(), project = billing)
  on.exit(dbDisconnect(con))

  dbGetQuery(con, sql) |> tibble::as_tibble()
}

orion_run_bq_query <- function(query) {
  result <- .execute_bq_query(query)

  is_nested <- any(purrr::map_lgl(result, is.list))

  if (is_nested) {
    paste(
      purrr::map_chr(
        seq_len(nrow(result)),
        \(i) toJSON(as.list(result[i, ]), auto_unbox = TRUE)
      ),
      collapse = "\n"
    )
  } else {
    toJSON(result, auto_unbox = TRUE, pretty = TRUE)
  }
}

orion_export_bq_query <- function(query, filename = NULL) {
  result <- .execute_bq_query(query)

  is_nested <- any(purrr::map_lgl(result, is.list))
  ext <- if (is_nested) "json" else "csv"

  if (is.null(filename)) {
    timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
    filename <- paste0("orion_export_", timestamp, ".", ext)
  }

  dir.create(EXPORT_DIR, showWarnings = FALSE, recursive = TRUE)
  path <- file.path(EXPORT_DIR, filename)

  if (is_nested) {
    write(toJSON(result, auto_unbox = TRUE, pretty = TRUE), path)
  } else {
    readr::write_csv(result, path)
  }

  list(
    path = path,
    format = ext,
    rows = nrow(result),
    columns = ncol(result),
    message = glue::glue("Exported {nrow(result)} rows × {ncol(result)} columns to {path}")
  ) |> toJSON(auto_unbox = TRUE, pretty = TRUE)
}

# Silence "Method not found" for prompts/list and resources/list.
# mcptools declares these capabilities but doesn't implement the handlers.
# Remove once https://github.com/posit-dev/mcptools/issues/59 is fixed.
local({
  orig <- mcptools:::handle_message_from_client
  assignInNamespace(
    "handle_message_from_client",
    function(line) {
      msg <- tryCatch(jsonlite::parse_json(line), error = function(e) NULL)
      result <- if (!is.null(msg$method)) {
        switch(msg$method,
          "prompts/list"   = list(prompts = list()),
          "resources/list" = list(resources = list()),
          NULL
        )
      }
      if (!is.null(result)) {
        mcptools:::cat_json(list(jsonrpc = "2.0", id = msg$id, result = result))
        return(invisible(NULL))
      }
      orig(line)
    },
    ns = "mcptools"
  )
})

mcp_server(
  tools = list(
    tool(
      orion_list_datasets,
      paste(
        "STEP 1 OF QUERY WORKFLOW: List all ORION-DBs datasets available on BigQuery from various providers of open research information.",
        "Does NOT return schemas — call orion_list_tables next to explore a specific dataset.",
        "Use this as the entry point whenever the user asks about available data or wants to run a query.",
        "IMPORTANT: Use the dataset descriptions as-is — do NOT infer recency from dates embedded in dataset names. 'instant' means the most recent snapshot.",
        "For more info see <https://orion-dbs.community/>"
      )
    ),
    tool(
      orion_list_tables,
      paste(
        "STEP 2 OF QUERY WORKFLOW: List all tables in a specific project/dataset with descriptions.",
        "Call this after orion_list_datasets to identify which table to query.",
        "Use the table descriptions to pick the right table before fetching its full schema."
      ),
      arguments = list(
        project = type_string("The GCP project ID"),
        dataset = type_string("The BigQuery dataset name")
      )
    ),
    tool(
      orion_get_db_schema,
      paste(
        "STEP 3 OF QUERY WORKFLOW: Get the full BigQuery schema for a specific table.",
        "Call this after orion_list_tables to understand column names and types before writing SQL.",
        "Also useful when comparing table structures across datasets.",
        "Schema reading rules:",
        "- REPEATED fields must be flattened with UNNEST() in queries.",
        "- RECORD fields are accessed via dot notation (e.g. open_access.oa_status).",
        "- Identify the primary identifier column (e.g. doi, id) — you will need it for COUNT DISTINCT and joins."
      ),
      arguments = list(
        project = type_string("The GCP project ID"),
        dataset = type_string("The BigQuery dataset name"),
        table = type_string("The BigQuery table name")
      )
    ),
    tool(
      orion_estimate_query_cost,
      paste(
        "STEP 4 OF QUERY WORKFLOW: Perform a BigQuery dry run to validate SQL syntax and estimate scan cost.",
        "This does NOT execute the query — it only returns estimated bytes processed.",
        "Dry runs are completely free and must ALWAYS be called before orion_run_bq_query.",
        "Takes exactly one argument — query — which must be the complete, fully-qualified SQL string.",
        "Cost calculation: $6.25 per TiB scanned (1 TiB = 1,000 GB).",
        "After receiving the cost estimate, STOP and present it to the user in plain language,",
        "e.g. 'This query will scan 4.2 GB and cost approximately $0.03. Shall I run it?'",
        "Do NOT call orion_run_bq_query until the user explicitly confirms they want to proceed.",
        "If the estimate exceeds 100 GB, highlight this prominently and strongly recommend the user confirm."
      ),
      arguments = list(
        query = type_string("The fully-qualified BigQuery SQL query to dry-run (include project.dataset.table in the query itself)")
      )
    ),
    tool(
      orion_run_bq_query,
      paste(
        "STEP 5 OF QUERY WORKFLOW: Execute a BigQuery SQL query,",
        "return results, and summarise them in plain language.",
        "PREREQUISITE: orion_estimate_query_cost MUST have been called",
        "for this exact SQL AND the user must have explicitly confirmed",
        "they want to proceed after seeing the cost.",
        "Never skip the cost confirmation step, even for small queries.",
        "Takes exactly one argument — query — which must be the",
        "complete, fully-qualified SQL string.",
        "After receiving results, ALWAYS provide a concise",
        "natural-language summary of the key findings.",
        "If the result contains more than 100 rows, ask the user:",
        "'The results contain X rows.",
        "Would you like me to export them to a file?'",
        "If the user confirms, call orion_export_bq_query with the",
        "identical SQL — BigQuery caches results for 24 hours so",
        "the export will cost nothing.",
        "SQL rules:",
        "- Never use SELECT * — name only the columns needed to minimise bytes scanned.",
        "- Never use COUNT(*) — always count distinct over a unique identifier (e.g. COUNT(DISTINCT doi)).",
        "- Always lowercase identifiers before joining across collections: LOWER(doi), LOWER(orcid), LOWER(issn).",
        "- DOI fields may be stored as bare DOIs ('10.1234/foo') or as URLs ('https://doi.org/10.1234/foo') depending on the dataset.",
        "- Always normalise DOIs before joining using REGEXP_REPLACE (not REGEXP_EXTRACT) to avoid introducing NULLs:",
        "  LOWER(REGEXP_REPLACE(doi, r'^https?://doi\\.org/', '')) — this safely strips the prefix if present and leaves bare DOIs unchanged."
      ),
      arguments = list(
        query = type_string("The fully-qualified BigQuery SQL query to execute (include project.dataset.table in the query itself)")
      )
    ),
    tool(
      orion_export_bq_query,
      paste(
        "ALTERNATIVE TO STEP 5: Execute a BigQuery SQL query and export full results to a file.",
        "Use this instead of orion_run_bq_query when the user wants to save or download the data,",
        "or when results are expected to be large (many rows) and returning them inline is impractical.",
        "Flat results (no nested/repeated fields) are exported as CSV; nested results as JSON.",
        "PREREQUISITE: orion_estimate_query_cost MUST have been called for this exact SQL",
        "AND the user must have explicitly confirmed they want to proceed.",
        "Returns the file path, format, and row/column count — not the data itself.",
        "IMPORTANT — accessing the exported file: the path returned (e.g. /data/exports/results.csv)",
        "is inside the Docker container, not on the host machine.",
        "To access the file, the user must mount a host directory to /data/exports when starting the container,",
        "e.g. add '-v ~/Downloads/orion-exports:/data/exports' to their docker run command.",
        "Without this mount the file is lost when the container stops.",
        "If the user has not set up a volume mount, tell them how to add it before they try to open the file."
      ),
      arguments = list(
        query = type_string("The fully-qualified BigQuery SQL query to execute (include project.dataset.table in the query itself)"),
        filename = type_string("Optional filename for the export (e.g. 'results.csv'). Auto-generated with timestamp if omitted.")
      )
    )
  )
)
