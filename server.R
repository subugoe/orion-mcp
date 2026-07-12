suppressPackageStartupMessages({
  library(ellmer)
  library(mcptools)
  library(tidyverse)
  library(jsonlite)
  library(DBI)
  library(bigrquery)
})

SCHEMA_DIR <- Sys.getenv("SCHEMA_DIR", "/data")
EXPORT_DIR <- Sys.getenv("EXPORT_DIR", "/data/exports")

# Character budget for inline query results (~4 characters per token).
# Full results are always kept in the R session; only the preview sent
# to the LLM is capped.
MAX_RESULT_CHARS <- as.integer(Sys.getenv("MAX_RESULT_CHARS", "80000"))

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
  cost <- round(bytes / 1e12 * 6.25, 4)

  dry_run_cache <<- unique(c(dry_run_cache, normalize_sql(query)))

  list(
    bytes_processed = bytes,
    gb_processed = gb,
    cost_usd_estimate = cost,
    canonical_sql = normalize_sql(query),
    message = glue::glue(
      "This query will scan {gb} GB (estimated cost: ${cost}).",
      " Present this to the user in exactly this order:",
      " (1) the full SQL verbatim in a fenced ```sql code block —",
      " never paraphrase or summarise the query instead of showing it;",
      " (2) a one-sentence plain-English explanation of what the query does",
      " (which tables it reads and what it filters, joins, or aggregates),",
      " since the user may still be learning SQL and BigQuery;",
      " (3) the GB scanned and estimated cost, then ask: 'Shall I run this query?'.",
      " Monthly free tier usage is unknown — do not assume the query is free.",
      " Wait for explicit confirmation before proceeding.",
      " If confirmed, pass canonical_sql verbatim",
      " to orion_run_bq_query or orion_export_bq_query.",
      " Do NOT modify, reformat, or re-derive the SQL."
    )
  ) |> toJSON(auto_unbox = TRUE, pretty = TRUE)
}

.execute_bq_query <- function(sql) {
  if (!normalize_sql(sql) %in% dry_run_cache) {
    stop(
      "Cost estimate required. Call orion_estimate_query_cost with this ",
      "exact SQL first, show the user the SQL and the estimated cost, and ",
      "wait for their confirmation before running the query."
    )
  }

  # Blank out string literals so SELECT * detection doesn't false-positive
  # on '.*' sequences inside regex patterns or quoted values.
  sql_no_strings <- gsub("'[^']*'", "''", sql)
  sql_no_strings <- gsub("\"[^\"]*\"", "\"\"", sql_no_strings)
  if (grepl("SELECT\\s+\\*|\\w+\\.\\*", sql_no_strings, ignore.case = TRUE)) {
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

# ---- Stored results ---------------------------------------------------------
# Every executed query keeps its full result in the R session under a stable
# name (q1, q2, ...). Only a size-capped preview travels to the LLM; the
# analysis tools below operate on the complete data by reference.

results_env <- new.env(parent = emptyenv())
result_counter <- 0L

store_result <- function(df) {
  result_counter <<- result_counter + 1L
  name <- paste0("q", result_counter)
  assign(name, df, envir = results_env)
  name
}

get_result <- function(name) {
  if (!exists(name, envir = results_env, inherits = FALSE)) {
    stored <- ls(results_env)
    stop(
      "No stored result named '", name, "'. ",
      if (length(stored) > 0) {
        paste0("Available results: ", toString(stored), ".")
      } else {
        "No query results are stored in this session yet — run a query first."
      }
    )
  }
  get(name, envir = results_env, inherits = FALSE)
}

has_nested <- function(df) any(map_lgl(df, is.list))

# Serialize a result for the LLM: CSV for flat data (far more
# token-efficient than JSON), JSON lines for nested data. Output is capped
# at `budget` characters, cutting only at complete rows.
render_rows <- function(df, budget = MAX_RESULT_CHARS) {
  nested <- has_nested(df)

  if (nested) {
    header <- NULL
    body <- map_chr(
      seq_len(nrow(df)),
      \(i) toJSON(as.list(df[i, ]), auto_unbox = TRUE)
    )
  } else {
    flat <- df |>
      mutate(across(where(is.character), \(x) str_replace_all(x, "[\r\n]+", " ")))
    lines <- strsplit(readr::format_csv(flat), "\n", fixed = TRUE)[[1]]
    header <- lines[1]
    body <- lines[-1]
  }

  header_chars <- if (is.null(header)) 0L else nchar(header) + 1L
  fits <- (cumsum(nchar(body) + 1L) + header_chars) <= budget
  keep <- if (length(body) == 0L || !any(fits)) 0L else max(which(fits))

  list(
    text = paste(c(header, body[seq_len(keep)]), collapse = "\n"),
    rows_shown = keep,
    truncated = keep < nrow(df),
    format = if (nested) "json" else "csv"
  )
}

orion_run_bq_query <- function(query) {
  result <- .execute_bq_query(query)
  name <- store_result(result)
  rendered <- render_rows(result)

  size_note <- if (rendered$truncated) {
    glue::glue(
      "Showing only the first {rendered$rows_shown} of {nrow(result)} rows — ",
      "the full output exceeds the response budget. The COMPLETE result is ",
      "stored in the R session as '{name}'. Do NOT draw conclusions from the ",
      "truncated rows alone: use orion_result_summary, orion_result_count, or ",
      "orion_result_slice on '{name}' to analyse the full data, or ",
      "orion_export_bq_query to save everything to a file."
    )
  } else {
    glue::glue(
      "Complete result shown below; also stored in the R session as '{name}'."
    )
  }

  glue::glue(
    "Result '{name}': {nrow(result)} rows x {ncol(result)} columns ",
    "({rendered$format} below). {size_note}\n",
    "SQL: {normalize_sql(query)}\n",
    "PRESENTATION INSTRUCTIONS: The user may be new to SQL and BigQuery — ",
    "support their learning. When presenting these results: ",
    "(1) summarise the key findings in plain language; ",
    "(2) explain in one or two jargon-free sentences how the query worked — ",
    "which tables it read and what the filters, joins, or aggregations did; ",
    "(3) mention that the full data is held in the local R session as ",
    "'{name}' (it was not uploaded anywhere) and can be analysed further ",
    "or exported to a file on request.\n",
    "---\n",
    "{rendered$text}"
  )
}

# ---- Analysis tools on stored results ---------------------------------------

summarise_column <- function(col, nm) {
  if (is.list(col)) {
    return(list(
      column = nm,
      type = "nested (use UNNEST in SQL to analyse)",
      missing = sum(map_lgl(col, is.null))
    ))
  }

  info <- list(
    column = nm,
    type = paste(class(col), collapse = "/"),
    missing = sum(is.na(col)),
    distinct = n_distinct(col)
  )

  if (is.numeric(col) && any(!is.na(col))) {
    info <- c(info, list(
      min = min(col, na.rm = TRUE),
      mean = round(mean(col, na.rm = TRUE), 3),
      max = max(col, na.rm = TRUE)
    ))
  } else if (is.character(col)) {
    info <- c(info, list(
      examples = toString(head(unique(col[!is.na(col)]), 3))
    ))
  }

  info
}

orion_result_summary <- function(name) {
  df <- get_result(name)

  list(
    result = name,
    rows = nrow(df),
    columns = ncol(df),
    column_summary = unname(imap(df, summarise_column)),
    message = paste(
      "Per-column overview of the full stored result (not just the preview).",
      "When presenting it, explain in plain language what the columns contain",
      "and point out anything the user should know (e.g. missing values),",
      "as the user may be new to data analysis."
    )
  ) |> toJSON(auto_unbox = TRUE, pretty = TRUE)
}

check_columns <- function(df, cols, name) {
  missing_cols <- setdiff(cols, names(df))
  if (length(missing_cols) > 0) {
    stop(
      "Columns not in result '", name, "': ", toString(missing_cols),
      ". Available columns: ", toString(names(df))
    )
  }
}

orion_result_count <- function(name, by) {
  df <- get_result(name)
  cols <- str_trim(str_split_1(by, ","))
  check_columns(df, cols, name)

  counts <- df |> count(across(all_of(cols)), sort = TRUE)
  total_groups <- nrow(counts)
  rendered <- render_rows(head(counts, 100))

  glue::glue(
    "Counts over the FULL stored result '{name}' ",
    "({total_groups} distinct groups, top {rendered$rows_shown} shown, ",
    "column 'n' = rows per group).\n",
    "Explain to the user in plain language what was counted and what the ",
    "top groups mean.\n",
    "---\n",
    "{rendered$text}"
  )
}

orion_result_slice <- function(name, columns = NULL, filter_column = NULL,
                               filter_op = NULL, filter_value = NULL, n = 50) {
  df <- get_result(name)

  filter_note <- "no filter"
  if (!is.null(filter_column)) {
    check_columns(df, filter_column, name)
    if (is.null(filter_op) || is.null(filter_value)) {
      stop("filter_column requires both filter_op and filter_value.")
    }

    col <- df[[filter_column]]
    value <- filter_value
    if (is.numeric(col)) {
      value <- suppressWarnings(as.numeric(value))
      if (is.na(value)) {
        stop("Column '", filter_column, "' is numeric but filter_value ",
             "'", filter_value, "' is not a number.")
      }
    }

    keep <- switch(filter_op,
      "==" = col == value,
      "!=" = col != value,
      ">"  = col > value,
      "<"  = col < value,
      ">=" = col >= value,
      "<=" = col <= value,
      "contains" = str_detect(
        str_to_lower(as.character(col)), fixed(str_to_lower(value))
      ),
      stop("Unsupported filter_op '", filter_op,
           "'. Use ==, !=, >, <, >=, <=, or contains.")
    )
    df <- df[which(keep), , drop = FALSE]
    filter_note <- glue::glue("{filter_column} {filter_op} {filter_value}")
  }

  if (!is.null(columns)) {
    cols <- str_trim(str_split_1(columns, ","))
    check_columns(df, cols, name)
    df <- select(df, all_of(cols))
  }

  total <- nrow(df)
  rendered <- render_rows(head(df, n))

  glue::glue(
    "Slice of stored result '{name}' ({filter_note}): ",
    "{total} rows matched, showing {rendered$rows_shown}.\n",
    "Explain to the user in plain language which subset this is.\n",
    "---\n",
    "{rendered$text}"
  )
}

# ---- Export ------------------------------------------------------------------

# Check whether EXPORT_DIR is a bind mount to the host. Returns NA if this
# cannot be determined (e.g. no /proc/mounts).
export_dir_mounted <- function() {
  mounts <- tryCatch(readLines("/proc/mounts"), error = function(e) NULL)
  if (is.null(mounts)) return(NA)
  any(grepl(paste0(" ", EXPORT_DIR, " "), mounts, fixed = TRUE))
}

orion_export_bq_query <- function(query, filename = NULL) {
  result <- .execute_bq_query(query)
  name <- store_result(result)

  is_nested <- has_nested(result)
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

  mounted <- export_dir_mounted()
  mount_note <- if (isFALSE(mounted)) {
    glue::glue(
      "WARNING: {EXPORT_DIR} is NOT mounted to a host folder — this file ",
      "exists only inside the Docker container and will be LOST when the ",
      "container stops. Tell the user to add ",
      "'-v /path/on/their/machine:{EXPORT_DIR}' to the docker run args in ",
      "their MCP config (see README) and re-run the export."
    )
  } else {
    glue::glue(
      "The file appears in the host folder the user mounted to {EXPORT_DIR}."
    )
  }

  list(
    path = path,
    format = ext,
    rows = nrow(result),
    columns = ncol(result),
    result_name = name,
    message = glue::glue(
      "Exported {nrow(result)} rows x {ncol(result)} columns to {path} ",
      "(a path inside the container). {mount_note} ",
      "The result is also stored in the R session as '{name}' for the ",
      "analysis tools. ",
      "SQL: {normalize_sql(query)}. ",
      "When presenting this to the user, say in plain language what was ",
      "exported, where the file appears on their machine, and briefly ",
      "explain what the query did — the user may be learning SQL and ",
      "BigQuery."
    )
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
        "Cost calculation: $6.25 per TB scanned (1 TB = 1,000 GB; the approximate BigQuery on-demand rate).",
        "After receiving the estimate, STOP and present it following the returned message exactly:",
        "show the full SQL in a fenced code block, explain in plain language what it does,",
        "state the GB scanned and cost, then ask 'Shall I run this query?'.",
        "Do NOT call orion_run_bq_query until the user explicitly confirms they want to proceed.",
        "CRITICAL: the SQL passed to orion_run_bq_query MUST be",
        "byte-for-byte identical to the SQL passed here.",
        "Do NOT reformat, rewrite, or improve the SQL after the dry run.",
        "If the user asks to change the query in any way,",
        "call orion_estimate_query_cost again with the new SQL",
        "before presenting a cost estimate or running it.",
        "Never reuse a previous cost estimate for modified SQL.",
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
        "Every result is stored in the R session under a stable name (q1, q2, ...)",
        "and only a size-capped preview is returned inline.",
        "If the response says the preview was TRUNCATED, do not reason from the",
        "partial rows — use orion_result_summary, orion_result_count, or",
        "orion_result_slice on the stored result, or orion_export_bq_query",
        "to save everything to a file (BigQuery caches results for 24 hours,",
        "so re-running the identical SQL costs nothing).",
        "SQL rules:",
        "- Never use SELECT * — name only the columns needed to minimise bytes scanned.",
        "- Never use COUNT(*) — always count distinct over a unique identifier (e.g. COUNT(DISTINCT doi)).",
        "- Always lowercase identifiers before joining across collections: LOWER(doi), LOWER(orcid), LOWER(issn).",
        "- DOI fields may be stored as bare DOIs ('10.1234/foo') or as URLs ('https://doi.org/10.1234/foo') depending on the dataset.",
        "- Always normalise DOIs before joining using REGEXP_REPLACE (not REGEXP_EXTRACT) to avoid introducing NULLs:",
        "  LOWER(REGEXP_REPLACE(doi, r'^https?://doi\\.org/', '')) — this safely strips the prefix if present and leaves bare DOIs unchanged.",
        " - Use ROR IDs when searching for an institution first"
      ),
      arguments = list(
        query = type_string("The fully-qualified BigQuery SQL query to execute (include project.dataset.table in the query itself)")
      )
    ),
    tool(
      orion_result_summary,
      paste(
        "ANALYSIS TOOL (after STEP 5): Per-column summary of a stored query result",
        "(type, missing values, distinct count, min/mean/max or example values).",
        "Operates on the FULL result held in the R session, not the truncated preview.",
        "Use this first when a query result was truncated, to understand the data",
        "before slicing or counting. Costs nothing — no BigQuery access involved."
      ),
      arguments = list(
        name = type_string("Name of the stored result (e.g. 'q1'), as reported by orion_run_bq_query")
      )
    ),
    tool(
      orion_result_count,
      paste(
        "ANALYSIS TOOL (after STEP 5): Frequency counts over one or more columns",
        "of a stored query result, sorted by count (top 100 groups).",
        "Operates on the FULL result held in the R session, not the truncated preview.",
        "Use for questions like 'how does this break down by year / institution / type?'",
        "without re-querying BigQuery. Costs nothing — no BigQuery access involved."
      ),
      arguments = list(
        name = type_string("Name of the stored result (e.g. 'q1')"),
        by = type_string("Comma-separated column names to group by (e.g. 'year' or 'institution,year')")
      )
    ),
    tool(
      orion_result_slice,
      paste(
        "ANALYSIS TOOL (after STEP 5): Return selected rows and columns from a",
        "stored query result, with an optional single filter.",
        "Operates on the FULL result held in the R session, not the truncated preview.",
        "Use to inspect specific subsets of a large result (e.g. one institution,",
        "one year) without re-querying BigQuery. Costs nothing."
      ),
      arguments = list(
        name = type_string("Name of the stored result (e.g. 'q1')"),
        columns = type_string("Optional comma-separated column names to return (all columns if omitted)", required = FALSE),
        filter_column = type_string("Optional column to filter on", required = FALSE),
        filter_op = type_string("Filter operator: ==, !=, >, <, >=, <=, or contains (case-insensitive substring)", required = FALSE),
        filter_value = type_string("Value to compare against (numbers as plain strings, e.g. '2023')", required = FALSE),
        n = type_integer("Maximum rows to return (default 50)", required = FALSE)
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
        "The response says whether the export folder is mounted to the host;",
        "if it is not, relay the warning to the user so they can add the volume mount",
        "before the file is lost when the container stops."
      ),
      arguments = list(
        query = type_string("The fully-qualified BigQuery SQL query to execute (include project.dataset.table in the query itself)"),
        filename = type_string("Optional filename for the export (e.g. 'results.csv'). Auto-generated with timestamp if omitted.", required = FALSE)
      )
    )
  )
)
