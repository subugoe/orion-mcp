# Core logic for the orion-mcp server. Sourced by server.R (which handles
# auth and starts the MCP server) and by tests/test-functions.R (which
# exercises everything that doesn't need BigQuery).
#
# Expects tidyverse, glue, jsonlite, and bigrquery to be attached.

SCHEMA_DIR <- Sys.getenv("SCHEMA_DIR", "/data")
EXPORT_DIR <- Sys.getenv("EXPORT_DIR", "/data/exports")

# Character budget for inline query results (~4 characters per token).
# Full results are always kept in the R session; only the preview sent
# to the LLM is capped. Chosen so that preview plus message stays under
# the ~25k-token tool-result cap that MCP clients like Claude Code apply.
MAX_RESULT_CHARS <- as.integer(Sys.getenv("MAX_RESULT_CHARS", "60000"))

read_jsonl <- function(path) {
  con <- file(path, "r")
  on.exit(close(con))
  stream_in(con, verbose = FALSE)
}

load_schema_data <- function(dir = SCHEMA_DIR) {
  list.files(dir, full.names = TRUE, pattern = "\\.jsonl$") |>
    map(read_jsonl) |>
    list_rbind()
}

# ---- Schema browsing ---------------------------------------------------------

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

  if (nrow(result) == 0) {
    stop(glue("Not found: {project}/{dataset}/{table}"))
  }

  result$schema[[1]] |>
    toJSON(auto_unbox = TRUE, pretty = TRUE)
}

# ---- Cost estimation and query execution ------------------------------------

dry_run_cache <- character(0)

normalize_sql <- function(sql) str_squish(sql)

# The OAuth token may carry a write-capable scope (gcloud user credentials
# do not support bigquery.readonly), so read-only access is enforced here
# instead: exactly one statement, and it must be a SELECT (optionally
# starting with WITH). Blocks DML/DDL and multi-statement scripts
# regardless of what the credentials would allow. Returns the SQL with
# string literals and comments blanked, for further pattern checks.
assert_read_only_sql <- function(sql) {
  clean <- sql |>
    str_replace_all("'[^']*'", "''") |>
    str_replace_all('"[^"]*"', '""') |>
    str_remove_all(regex("/\\*.*?\\*/", dotall = TRUE)) |>
    str_remove_all("--[^\n]*") |>
    str_squish() |>
    str_remove(";$")

  if (str_detect(clean, fixed(";"))) {
    stop(glue(
      "Multi-statement SQL scripts are not allowed — submit a single ",
      "SELECT query."
    ))
  }
  if (!str_detect(clean, regex("^(WITH|SELECT)\\b", ignore_case = TRUE))) {
    stop(glue(
      "Only read-only SELECT queries are allowed. Data-modifying ",
      "statements (INSERT, UPDATE, DELETE, MERGE, CREATE, DROP, ALTER, ",
      "TRUNCATE, ...) are blocked by this server regardless of the ",
      "credentials' permissions."
    ))
  }

  invisible(clean)
}

orion_estimate_query_cost <- function(query) {
  billing <- Sys.getenv("BQ_BILLING_PROJECT")
  if (billing == "") stop("BQ_BILLING_PROJECT environment variable not set")

  assert_read_only_sql(query)

  bytes <- as.numeric(bq_perform_query_dry_run(query, billing = billing))
  gb <- round(bytes / 1e9, 3)
  cost <- round(bytes / 1e12 * 6.25, 4)
  # Avoid scientific notation ("1e-04") in the user-facing message
  cost_display <- format(cost, scientific = FALSE)

  dry_run_cache <<- unique(c(dry_run_cache, normalize_sql(query)))

  list(
    bytes_processed = bytes,
    gb_processed = gb,
    cost_usd_estimate = cost,
    canonical_sql = normalize_sql(query),
    message = glue(
      "This query will scan {gb} GB (estimated cost: ${cost_display}). ",
      "Present this to the user in exactly this order: ",
      "(1) the full SQL verbatim in a fenced ```sql code block — ",
      "never paraphrase or summarise the query instead of showing it; ",
      "(2) a one-sentence plain-English explanation of what the query does ",
      "(which tables it reads and what it filters, joins, or aggregates), ",
      "since the user may still be learning SQL and BigQuery; ",
      "(3) the GB scanned and estimated cost, then ask: ",
      "'Shall I run this query?'. ",
      "Monthly free tier usage is unknown — do not assume the query is ",
      "free. Wait for explicit confirmation before proceeding. ",
      "If confirmed, pass canonical_sql verbatim to orion_run_bq_query or ",
      "orion_export_bq_query. Do NOT modify, reformat, or re-derive the SQL."
    )
  ) |> toJSON(auto_unbox = TRUE, pretty = TRUE)
}

# Gate every execution path: cost estimate done, read-only single SELECT,
# no SELECT *, billing project set. Returns the billing project.
validate_query <- function(sql) {
  if (!normalize_sql(sql) %in% dry_run_cache) {
    stop(glue(
      "Cost estimate required. Call orion_estimate_query_cost with this ",
      "exact SQL first, show the user the SQL and the estimated cost, and ",
      "wait for their confirmation before running the query."
    ))
  }

  # Also blanks string literals so SELECT * detection below doesn't
  # false-positive on '.*' sequences inside regex patterns or quoted values.
  sql_no_strings <- assert_read_only_sql(sql)

  if (str_detect(sql_no_strings,
                 regex("SELECT\\s+\\*|\\w+\\.\\*", ignore_case = TRUE))) {
    stop(glue(
      "SELECT * and table.* are not allowed — specify only the columns ",
      "needed to avoid scanning unnecessary data."
    ))
  }

  billing <- Sys.getenv("BQ_BILLING_PROJECT")
  if (billing == "") stop("BQ_BILLING_PROJECT environment variable not set")

  billing
}

job_billing_note <- function(query_stats) {
  cache_hit <- isTRUE(query_stats$cacheHit)
  gb_billed <- round(as.numeric(query_stats$totalBytesBilled %||% 0) / 1e9, 3)

  if (cache_hit) {
    glue(
      "This run was served from BigQuery's 24-hour query cache — 0 bytes ",
      "billed. Re-running a byte-identical query within 24 hours is free."
    )
  } else {
    glue("BigQuery billed {gb_billed} GB for this run.")
  }
}

execute_bq_query <- function(sql) {
  billing <- validate_query(sql)

  job <- bq_perform_query(sql, billing = billing)
  bq_job_wait(job, quiet = TRUE)

  meta <- bq_job_meta(job)
  query_stats <- meta$statistics$query
  billing_note <- job_billing_note(query_stats)

  dest <- meta$configuration$query$destinationTable
  result <- bq_table(dest$projectId, dest$datasetId, dest$tableId) |>
    bq_table_download(quiet = TRUE)

  list(
    result = result,
    cache_hit = isTRUE(query_stats$cacheHit),
    billing_note = billing_note
  )
}

# ---- Stored results ---------------------------------------------------------
# Every executed query keeps its full result in the R session under a stable
# name (q1, q2, ...). Only a size-capped preview travels to the LLM; the
# analysis tools below operate on the complete data by reference.

results_env <- new.env(parent = emptyenv())
result_counter <- 0L

store_result <- function(df) {
  result_counter <<- result_counter + 1L
  name <- as.character(glue("q{result_counter}"))
  assign(name, df, envir = results_env)
  name
}

get_result <- function(name) {
  if (!exists(name, envir = results_env, inherits = FALSE)) {
    stored <- ls(results_env)
    hint <- if (length(stored) > 0) {
      glue("Available results: {str_flatten(stored, ', ')}.")
    } else {
      "No query results are stored in this session yet — run a query first."
    }
    stop(glue("No stored result named '{name}'. {hint}"))
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
    lines <- format_csv(flat) |>
      str_remove("\n$") |>
      str_split_1(fixed("\n"))
    header <- lines[1]
    body <- lines[-1]
  }

  header_chars <- if (is.null(header)) 0L else nchar(header) + 1L
  fits <- (cumsum(nchar(body) + 1L) + header_chars) <= budget
  keep <- if (length(body) == 0L || !any(fits)) 0L else max(which(fits))

  list(
    text = str_flatten(c(header, body[seq_len(keep)]), "\n"),
    rows_shown = keep,
    truncated = keep < nrow(df),
    format = if (nested) "json" else "csv"
  )
}

orion_run_bq_query <- function(query) {
  run <- execute_bq_query(query)
  result <- run$result
  name <- store_result(result)
  rendered <- render_rows(result)

  size_note <- if (rendered$truncated) {
    glue(
      "Showing only the first {rendered$rows_shown} of {nrow(result)} rows — ",
      "the full output exceeds the response budget. The COMPLETE result is ",
      "stored in the R session as '{name}'. Do NOT draw conclusions from ",
      "the truncated rows alone: use orion_result_summary, ",
      "orion_result_count, or orion_result_slice on '{name}' to analyse ",
      "the full data, or orion_export_result to save it to a file (free — ",
      "the data is already in the R session)."
    )
  } else {
    glue(
      "Complete result shown below; also stored in the R session as '{name}'."
    )
  }

  glue(
    "Result '{name}': {nrow(result)} rows x {ncol(result)} columns ",
    "({rendered$format} below). {size_note} {run$billing_note}\n",
    "SQL: {normalize_sql(query)}\n",
    "PRESENTATION INSTRUCTIONS: The user may be new to SQL and BigQuery — ",
    "support their learning. When presenting these results: ",
    "(1) summarise the key findings in plain language; ",
    "(2) explain in one or two jargon-free sentences how the query worked — ",
    "which tables it read and what the filters, joins, or aggregations did; ",
    "(3) mention that the full data is held in the local R session as ",
    "'{name}' (it was not uploaded anywhere) and can be analysed further ",
    "or exported to a file on request. ",
    "Present results as plain text and simple markdown tables in the ",
    "chat — do NOT create charts, artifacts, or interactive ",
    "visualisations unless the user explicitly asks for one.\n",
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
    type = str_flatten(class(col), "/"),
    missing = sum(is.na(col)),
    distinct = n_distinct(col, na.rm = TRUE)
  )

  if (is.numeric(col) && any(!is.na(col))) {
    info <- c(info, list(
      min = min(col, na.rm = TRUE),
      mean = round(mean(col, na.rm = TRUE), 3),
      max = max(col, na.rm = TRUE)
    ))
  } else if (is.character(col)) {
    info <- c(info, list(
      examples = str_flatten(head(unique(col[!is.na(col)]), 3), ", ")
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
    message = glue(
      "Per-column overview of the full stored result (not just the ",
      "preview). When presenting it, explain in plain language what the ",
      "columns contain and point out anything the user should know ",
      "(e.g. missing values), as the user may be new to data analysis."
    )
  ) |> toJSON(auto_unbox = TRUE, pretty = TRUE)
}

check_columns <- function(df, cols, name) {
  missing_cols <- setdiff(cols, names(df))
  if (length(missing_cols) > 0) {
    stop(glue(
      "Columns not in result '{name}': {str_flatten(missing_cols, ', ')}. ",
      "Available columns: {str_flatten(names(df), ', ')}"
    ))
  }
}

orion_result_count <- function(name, by) {
  df <- get_result(name)
  cols <- str_trim(str_split_1(by, ","))
  check_columns(df, cols, name)

  counts <- df |> count(across(all_of(cols)), sort = TRUE)
  total_groups <- nrow(counts)
  rendered <- render_rows(head(counts, 100))

  glue(
    "Counts over the FULL stored result '{name}' ",
    "({total_groups} distinct groups, top {rendered$rows_shown} shown, ",
    "column 'n' = rows per group).\n",
    "Explain to the user in plain language what was counted and what the ",
    "top groups mean. Present as plain text or a simple markdown table — ",
    "no charts or artifacts unless the user explicitly asks.\n",
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
        stop(glue(
          "Column '{filter_column}' is numeric but filter_value ",
          "'{filter_value}' is not a number."
        ))
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
      stop(glue(
        "Unsupported filter_op '{filter_op}'. ",
        "Use ==, !=, >, <, >=, <=, or contains."
      ))
    )
    df <- df[which(keep), , drop = FALSE]
    filter_note <- glue("{filter_column} {filter_op} {filter_value}")
  }

  if (!is.null(columns)) {
    cols <- str_trim(str_split_1(columns, ","))
    check_columns(df, cols, name)
    df <- select(df, all_of(cols))
  }

  total <- nrow(df)
  rendered <- render_rows(head(df, n))

  glue(
    "Slice of stored result '{name}' ({filter_note}): ",
    "{total} rows matched, showing {rendered$rows_shown}.\n",
    "Explain to the user in plain language which subset this is. ",
    "Present as plain text or a simple markdown table — no charts or ",
    "artifacts unless the user explicitly asks.\n",
    "---\n",
    "{rendered$text}"
  )
}

# ---- Export ------------------------------------------------------------------

# Check whether EXPORT_DIR is a bind mount to the host. Returns NA if this
# cannot be determined (e.g. no /proc/mounts).
export_dir_mounted <- function() {
  if (!file.exists("/proc/mounts")) return(NA)
  mounts <- tryCatch(readLines("/proc/mounts"), error = function(e) NULL)
  if (is.null(mounts)) return(NA)
  any(str_detect(mounts, fixed(as.character(glue(" {EXPORT_DIR} ")))))
}

export_mount_note <- function() {
  mounted <- export_dir_mounted()
  if (isFALSE(mounted)) {
    glue(
      "WARNING: {EXPORT_DIR} is NOT mounted to a host folder — this file ",
      "exists only inside the Docker container and will be LOST when the ",
      "container stops. Tell the user to add ",
      "'-v /path/on/their/machine:{EXPORT_DIR}' to the docker run args in ",
      "their MCP config (see README) and re-run the export."
    )
  } else if (isTRUE(mounted)) {
    glue("The file appears in the host folder the user mounted to ",
         "{EXPORT_DIR}.")
  } else {
    glue(
      "Could not verify whether {EXPORT_DIR} is mounted to the host; if ",
      "the user cannot find the file, point them to the volume mount setup ",
      "in the README."
    )
  }
}

write_export <- function(result, filename = NULL) {
  nested <- has_nested(result)
  ext <- if (nested) "json" else "csv"

  if (is.null(filename)) {
    timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
    filename <- glue("orion_export_{timestamp}.{ext}")
  }

  dir.create(EXPORT_DIR, showWarnings = FALSE, recursive = TRUE)
  path <- file.path(EXPORT_DIR, filename)

  if (nested) {
    write(toJSON(result, auto_unbox = TRUE, pretty = TRUE), path)
  } else {
    write_csv(result, path)
  }

  list(path = path, format = ext)
}

orion_export_result <- function(name, filename = NULL) {
  result <- get_result(name)
  export <- write_export(result, filename)

  list(
    path = export$path,
    format = export$format,
    rows = nrow(result),
    columns = ncol(result),
    result_name = name,
    message = glue(
      "Exported stored result '{name}' ({nrow(result)} rows x ",
      "{ncol(result)} columns) to {export$path} (a path inside the ",
      "container) without touching BigQuery — this cost nothing. ",
      "{export_mount_note()} ",
      "When presenting this to the user, say in plain language what was ",
      "exported and where the file appears on their machine."
    )
  ) |> toJSON(auto_unbox = TRUE, pretty = TRUE)
}

orion_export_bq_query <- function(query, filename = NULL) {
  run <- execute_bq_query(query)
  result <- run$result
  name <- store_result(result)
  export <- write_export(result, filename)

  list(
    path = export$path,
    format = export$format,
    rows = nrow(result),
    columns = ncol(result),
    result_name = name,
    message = glue(
      "Exported {nrow(result)} rows x {ncol(result)} columns to ",
      "{export$path} (a path inside the container). {run$billing_note} ",
      "{export_mount_note()} ",
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

# ---- Writing to BigQuery ------------------------------------------------------
# Writes never happen through SQL (assert_read_only_sql blocks DML/DDL).
# They are only possible through these tools, where the destination table
# is an explicit argument the user has seen and confirmed. Whether a write
# is permitted at all is governed by the user's IAM roles on the
# destination project.

parse_bq_table <- function(destination) {
  parts <- str_split_1(destination, fixed("."))
  if (length(parts) != 3 || any(parts == "")) {
    stop(glue(
      "destination must be fully qualified as 'project.dataset.table', ",
      "got '{destination}'."
    ))
  }
  bq_table(parts[1], parts[2], parts[3])
}

orion_save_result_to_bq <- function(name, destination, overwrite = FALSE) {
  result <- get_result(name)
  dest <- parse_bq_table(destination)

  bq_table_upload(
    dest,
    result,
    create_disposition = "CREATE_IF_NEEDED",
    write_disposition = if (isTRUE(overwrite)) "WRITE_TRUNCATE" else "WRITE_EMPTY",
    quiet = TRUE
  )

  list(
    destination = destination,
    rows = nrow(result),
    columns = ncol(result),
    result_name = name,
    message = glue(
      "Saved stored result '{name}' ({nrow(result)} rows x ",
      "{ncol(result)} columns) to the BigQuery table {destination} via a ",
      "load job — load jobs are free. ",
      "When presenting this to the user, confirm in plain language where ",
      "the table now lives and that they can query it like any other ",
      "table; note the write used their own Google account's permissions."
    )
  ) |> toJSON(auto_unbox = TRUE, pretty = TRUE)
}

orion_query_to_table <- function(query, destination, overwrite = FALSE) {
  billing <- validate_query(query)
  dest <- parse_bq_table(destination)

  job <- bq_perform_query(
    query,
    billing = billing,
    destination_table = dest,
    create_disposition = "CREATE_IF_NEEDED",
    write_disposition = if (isTRUE(overwrite)) "WRITE_TRUNCATE" else "WRITE_EMPTY"
  )
  bq_job_wait(job, quiet = TRUE)

  query_stats <- bq_job_meta(job)$statistics$query
  n_rows <- tryCatch(as.numeric(bq_table_nrow(dest)), error = function(e) NA)

  list(
    destination = destination,
    rows = n_rows,
    message = glue(
      "Query results written directly to the BigQuery table {destination} ",
      "({if (is.na(n_rows)) 'row count unavailable' else glue('{n_rows} rows')}) ",
      "— nothing was downloaded. {job_billing_note(query_stats)} ",
      "The write itself is free; only the query scan is billed. ",
      "SQL: {normalize_sql(query)}. ",
      "When presenting this to the user, say in plain language what was ",
      "computed and where the table now lives, and briefly explain what ",
      "the query did — the user may be learning SQL and BigQuery."
    )
  ) |> toJSON(auto_unbox = TRUE, pretty = TRUE)
}

# ---- Authentication ----------------------------------------------------------

# Authenticate with Application Default Credentials, preferring the
# read-only BigQuery scope. gcloud user credentials (type "authorized_user")
# only support a fixed set of scopes that excludes bigquery.readonly, so
# fall back to the full BigQuery scope; actual permissions are still
# limited by the user's IAM roles. Returns the granted scope, or NULL if
# no credentials were found.
bq_adc_auth <- function() {
  scopes <- c(
    "https://www.googleapis.com/auth/bigquery.readonly",
    "https://www.googleapis.com/auth/bigquery"
  )
  for (scope in scopes) {
    token <- tryCatch(
      gargle::credentials_app_default(scopes = scope),
      error = function(e) NULL
    )
    if (!is.null(token)) {
      bq_auth(token = token)
      return(scope)
    }
  }
  NULL
}

# ---- Health check ------------------------------------------------------------

orion_health_check <- function() {
  checks <- list()

  checks$schema_metadata <- if (nrow(schema_data) > 0) {
    n_datasets <- nrow(distinct(schema_data, project, dataset))
    list(
      status = "ok",
      detail = glue(
        "{n_datasets} datasets with {nrow(schema_data)} tables loaded."
      )
    )
  } else {
    list(
      status = "failed",
      detail = "No schema metadata loaded — schema browsing will not work.",
      fix = glue(
        "The container fetches schemas from GitHub at startup. Check its ",
        "network access and the SCHEMA_REPO/SCHEMA_PATH environment ",
        "variables, then restart the container."
      )
    )
  }

  has_token <- tryCatch(bq_has_token(), error = function(e) FALSE)
  checks$google_credentials <- if (has_token) {
    scope <- get0("auth_scope", ifnotfound = NULL)
    detail <- if (is.null(scope)) {
      "Google Cloud credentials loaded (Application Default Credentials)."
    } else {
      glue("Google Cloud credentials loaded (scope: {scope}).")
    }
    list(status = "ok", detail = detail)
  } else {
    list(
      status = "failed",
      detail = "No Google Cloud credentials found — queries will not work.",
      fix = glue(
        "Run 'gcloud auth application-default login' on the host machine ",
        "and mount ~/.config/gcloud into the container (see README). ",
        "Schema browsing still works without credentials."
      )
    )
  }

  billing <- Sys.getenv("BQ_BILLING_PROJECT")
  checks$billing_project <- if (billing != "") {
    list(
      status = "ok",
      detail = glue("BQ_BILLING_PROJECT is set to '{billing}'.")
    )
  } else {
    list(
      status = "failed",
      detail = "BQ_BILLING_PROJECT is not set — queries will not work.",
      fix = glue(
        "Add '-e BQ_BILLING_PROJECT=YOUR_PROJECT_ID' to the docker run ",
        "args in the MCP config (see README)."
      )
    )
  }

  checks$bigquery_connection <- if (has_token && billing != "") {
    tryCatch(
      {
        bq_perform_query_dry_run("SELECT 1", billing = billing)
        list(
          status = "ok",
          detail = glue(
            "Free dry run succeeded — BigQuery is reachable and the ",
            "billing project accepts queries."
          )
        )
      },
      error = function(e) {
        list(
          status = "failed",
          detail = glue("Dry run failed: {conditionMessage(e)}"),
          fix = glue(
            "Check that the billing project ID is correct and that the ",
            "BigQuery API is enabled for it in the Google Cloud Console."
          )
        )
      }
    )
  } else {
    list(
      status = "skipped",
      detail = "Skipped — needs credentials and a billing project (see above)."
    )
  }

  mounted <- export_dir_mounted()
  checks$export_folder <- if (isTRUE(mounted)) {
    list(
      status = "ok",
      detail = glue(
        "{EXPORT_DIR} is mounted to the host — exported files will appear ",
        "on the user's machine."
      )
    )
  } else if (isFALSE(mounted)) {
    list(
      status = "warning",
      detail = glue(
        "{EXPORT_DIR} is not mounted — exported files would be lost when ",
        "the container stops."
      ),
      fix = glue(
        "Add '-v /path/on/their/machine:{EXPORT_DIR}' to the docker run ",
        "args (see README). Only needed for file exports."
      )
    )
  } else {
    list(
      status = "unknown",
      detail = "Could not determine mount status on this platform."
    )
  }

  list(
    checks = checks,
    message = glue(
      "Present this to the user as a friendly checklist: one line per ",
      "check with a clear ok/warning/failed marker and the detail in ",
      "plain language. For anything not ok, walk the user through the fix ",
      "step by step — they may be new to Docker and Google Cloud. End ",
      "with a one-sentence overall verdict (e.g. 'ready to query', ",
      "'schema browsing only', or 'setup incomplete')."
    )
  ) |> toJSON(auto_unbox = TRUE, pretty = TRUE)
}
