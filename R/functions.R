# Core logic for the orion-mcp server. Sourced by server.R (which handles
# auth and starts the MCP server) and by tests/test-functions.R (which
# exercises everything that doesn't need BigQuery).
#
# Expects dplyr, purrr, stringr, readr, tibble, glue, jsonlite and bigrquery
# to be attached.

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

# A file that cannot be read is skipped with a warning on stderr: one bad
# file must not stop the server or hide the other collections.
load_schema_data <- function(dir = SCHEMA_DIR) {
  list.files(dir, full.names = TRUE, pattern = "\\.jsonl$") |>
    map(\(path) {
      tryCatch(
        read_jsonl(path),
        error = function(e) {
          message(glue("Skipping unreadable schema file {path}: {conditionMessage(e)}"))
          NULL
        }
      )
    }) |>
    compact() |>
    list_rbind()
}

# Returned by the schema tools when no schema files could be loaded, so the
# model can tell the user what is wrong instead of failing on a missing column.
no_schema_message <- function() {
  glue(
    "No schema metadata is loaded, so datasets and tables cannot be listed. ",
    "This is a setup problem, not a missing dataset. Call orion_health_check ",
    "for the cause and its fix (usually: the image has no schema files and ",
    "the start-up download failed; check the container's network access or ",
    "SCHEMA_REPO and restart it)."
  )
}

# ---- Schema browsing ---------------------------------------------------------

orion_list_datasets <- function() {
  if (nrow(schema_data) == 0) return(no_schema_message())
  schema_data |>
    summarise(
      dataset_description = first(dataset_description),
      tables = n(),
      .by = c(project, dataset)
    ) |>
    toJSON(auto_unbox = TRUE, pretty = TRUE)
}

orion_list_tables <- function(project, dataset) {
  if (nrow(schema_data) == 0) return(no_schema_message())
  schema_data |>
    filter(.data$project == .env$project, .data$dataset == .env$dataset) |>
    select(table, description) |>
    toJSON(auto_unbox = TRUE, pretty = TRUE)
}

orion_get_db_schema <- function(project, dataset, table) {
  if (nrow(schema_data) == 0) return(no_schema_message())
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

# Normalised SQL -> estimated bytes from the dry run. A query can only run
# if it is in here, and its job is capped at what the estimate allows.
dry_run_cache <- numeric(0)
# Normalised SQL -> number of tables the query reads (for the billing floor)
dry_run_tables <- integer(0)

# Key under which a query's estimate is stored: comments removed and
# whitespace collapsed outside string literals, literals kept as written.
# The model can therefore lay the SQL out over several lines for the user
# and still match its estimate. Comments are removed, not kept, because
# joining the lines of SQL that contains a `--` comment changes what the
# query does, and such a variant must not match the estimate.
normalize_sql <- function(sql) {
  blank_sql_literals(sql, keep_literals = TRUE, squish = TRUE)
}

cache_dry_run <- function(sql, bytes, n_tables = 1L) {
  key <- normalize_sql(sql)
  dry_run_cache[key] <<- bytes
  dry_run_tables[key] <<- as.integer(n_tables)
  invisible(key)
}

# Labels let users filter spending by tool in the Cloud billing export.
JOB_LABELS <- list(tool = "orion-mcp")

# Ceiling for maximumBytesBilled. BigQuery bills at least 10 MB per table
# read and rounds up to whole MB, so a cap equal to the bare estimate would
# fail small queries. Returns NULL (no cap) for a 0-byte estimate.
max_bytes_billed <- function(bytes, n_tables = 1L) {
  if (is.na(bytes) || bytes <= 0) return(NULL)
  mib <- 2^20
  ceiling((bytes + 10 * mib * max(1L, n_tables)) / mib) * mib
}

# Extra arguments for bq_perform_query(); bq_body() merges them into the
# request. BigQuery expects int64 values as strings.
job_limit_args <- function(max_bytes) {
  if (is.null(max_bytes)) return(list())
  list(configuration = list(query = list(
    maximumBytesBilled = format(max_bytes, scientific = FALSE)
  )))
}

read_limit_env <- function(var, default) {
  raw <- Sys.getenv(var, default)
  value <- suppressWarnings(as.numeric(raw))
  if (is.na(value) || value <= 0) {
    stop(glue("{var} must be a positive number, got '{raw}'."))
  }
  value
}

# Approximate BigQuery on-demand rate, per TiB (2^40 bytes, not 10^12).
USD_PER_TIB <- 6.25

estimate_cost_usd <- function(bytes) round(bytes / 2^40 * USD_PER_TIB, 4)

# Refuse very large scans before the user is asked to confirm them.
assert_query_size <- function(bytes, max_gb = read_limit_env("MAX_GB_PER_QUERY", "500")) {
  gb <- bytes / 1e9
  if (gb > max_gb) {
    stop(glue(
      "This query would scan {round(gb, 1)} GB, above the server limit of ",
      "{max_gb} GB per query. Narrow the query (fewer columns, partition ",
      "filters, smaller tables), or raise the limit with the ",
      "MAX_GB_PER_QUERY environment variable."
    ))
  }
  invisible(TRUE)
}

# Downloading a huge result blocks the server and can exhaust its memory.
assert_download_size <- function(n_rows, billing_note,
                                 max_rows = read_limit_env("MAX_DOWNLOAD_ROWS", "1000000")) {
  if (!is.na(n_rows) && n_rows > max_rows) {
    stop(glue(
      "The query returned {format(n_rows, big.mark = ',', scientific = FALSE)} ",
      "rows, above the download limit of ",
      "{format(max_rows, big.mark = ',', scientific = FALSE)} rows ",
      "(MAX_DOWNLOAD_ROWS), so nothing was downloaded. {billing_note} ",
      "Options: aggregate or filter the query so it returns fewer rows, or ",
      "use orion_query_to_table to keep the result in BigQuery."
    ))
  }
  invisible(TRUE)
}

# TRUE if the quote at position i carries a raw prefix (r, rb, br; any
# case). Inside raw literals a backslash does not escape.
is_raw_prefix <- function(chars, i) {
  k <- i - 1L
  prefix <- character(0)
  while (k >= 1L && str_detect(chars[k], "[A-Za-z0-9_]")) {
    prefix <- c(chars[k], prefix)
    k <- k - 1L
  }
  str_to_lower(str_flatten(prefix)) %in% c("r", "rb", "br")
}

# Single left-to-right pass over GoogleSQL. String and bytes literals become
# '' and comments a space; backtick identifiers are kept but not scanned for
# quotes or comments. A regex cannot do this, because a quote inside a
# comment (or a comment marker inside a string) changes how the rest of the
# text must be read. Unterminated literals and comments are errors.
# With keep_literals, literals are copied as written (comments still go).
# With squish, runs of whitespace outside literals become one space.
blank_sql_literals <- function(sql, keep_literals = FALSE, squish = FALSE) {
  chars <- str_split_1(sql, "")
  n <- length(chars)
  out <- character(0)
  i <- 1L

  add_space <- function(out) {
    if (squish && identical(tail(out, 1), " ")) out else c(out, " ")
  }

  while (i <= n) {
    ch <- chars[i]
    nxt <- if (i < n) chars[i + 1L] else ""

    if ((ch == "-" && nxt == "-") || ch == "#") {
      while (i <= n && chars[i] != "\n") i <- i + 1L
      out <- add_space(out)
      next
    }

    if (ch == "/" && nxt == "*") {
      j <- i + 2L
      while (j < n && !(chars[j] == "*" && chars[j + 1L] == "/")) j <- j + 1L
      if (j >= n) stop("Unterminated /* block comment in SQL.")
      out <- add_space(out)
      i <- j + 2L
      next
    }

    if (squish && str_detect(ch, "\\s")) {
      out <- add_space(out)
      i <- i + 1L
      next
    }

    if (ch == "`") {
      j <- i + 1L
      while (j <= n && chars[j] != "`") {
        if (chars[j] == "\\") j <- j + 1L
        j <- j + 1L
      }
      if (j > n) stop("Unterminated backtick identifier in SQL.")
      out <- c(out, chars[i:j])
      i <- j + 1L
      next
    }

    if (ch %in% c("'", '"')) {
      raw <- is_raw_prefix(chars, i)
      triple <- i + 2L <= n && chars[i + 1L] == ch && chars[i + 2L] == ch
      j <- if (triple) i + 3L else i + 1L
      closed <- FALSE
      while (j <= n) {
        if (!raw && chars[j] == "\\") {
          j <- j + 2L
          next
        }
        if (triple) {
          if (j + 2L <= n && chars[j] == ch && chars[j + 1L] == ch &&
              chars[j + 2L] == ch) {
            j <- j + 2L
            closed <- TRUE
            break
          }
        } else {
          if (chars[j] == ch) {
            closed <- TRUE
            break
          }
          # Single-quoted literals cannot span lines in GoogleSQL
          if (chars[j] == "\n") break
        }
        j <- j + 1L
      }
      if (!closed) stop("Unterminated string literal in SQL.")
      out <- c(out, if (keep_literals) chars[i:j] else "''")
      i <- j + 1L
      next
    }

    out <- c(out, ch)
    i <- i + 1L
  }

  res <- str_flatten(out)
  if (squish) str_trim(res) else res
}

# BigQuery's own classification of the SQL decides: the local scanner can
# miss syntax it does not know, the dry run cannot.
assert_select_statement <- function(statement_type) {
  if (!identical(statement_type, "SELECT")) {
    label <- if (is.character(statement_type) && length(statement_type) == 1) {
      statement_type
    } else {
      "unknown"
    }
    stop(glue(
      "BigQuery classified this SQL as '{label}', not a single SELECT ",
      "statement. Only read-only SELECT queries are allowed."
    ))
  }
  invisible(TRUE)
}

# Same request as bigrquery::bq_perform_query_dry_run(), which keeps only
# the byte count. We also need statistics.query.statementType. Uses
# bigrquery internals, so the version is pinned in the Dockerfile.
bq_dry_run_stats <- function(query, billing) {
  body <- list(configuration = list(
    query = list(
      query = jsonlite::unbox(query),
      useLegacySql = jsonlite::unbox(FALSE)
    ),
    dryRun = jsonlite::unbox(TRUE)
  ))
  res <- bigrquery:::bq_post(
    bigrquery:::bq_path(billing, jobs = ""),
    body = body,
    query = list(fields = "statistics")
  )
  list(
    bytes = as.numeric(res$statistics$query$totalBytesProcessed),
    statement_type = res$statistics$query$statementType,
    n_tables = length(res$statistics$query$referencedTables)
  )
}

# The OAuth token may carry a write-capable scope (gcloud user credentials
# do not support bigquery.readonly), so read-only access is enforced here
# instead: exactly one statement, and it must be a SELECT (optionally
# starting with WITH). Blocks DML/DDL and multi-statement scripts
# regardless of what the credentials would allow. Returns the SQL with
# string literals and comments blanked, for further pattern checks.
assert_read_only_sql <- function(sql) {
  clean <- sql |>
    blank_sql_literals() |>
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

# Expects SQL with literals and comments blanked (the output of
# assert_read_only_sql), so '.*' inside a regex literal does not count.
# Covers SELECT [ALL|DISTINCT] [AS STRUCT|AS VALUE] * and table.*;
# COUNT(*) is not a column wildcard and stays allowed.
assert_no_select_star <- function(sql_no_strings) {
  pattern <- regex(
    "SELECT\\s+(ALL\\s+|DISTINCT\\s+)?(AS\\s+(STRUCT|VALUE)\\s+)?\\*|\\w+\\.\\*",
    ignore_case = TRUE
  )
  if (str_detect(sql_no_strings, pattern)) {
    stop(glue(
      "SELECT * and table.* are not allowed — specify only the columns ",
      "needed to avoid scanning unnecessary data."
    ))
  }
  invisible(TRUE)
}

orion_estimate_query_cost <- function(query) {
  billing <- Sys.getenv("BQ_BILLING_PROJECT")
  if (billing == "") stop("BQ_BILLING_PROJECT environment variable not set")

  # Checked here too, so the model learns about it before the user is asked
  # to confirm a cost.
  assert_read_only_sql(query) |> assert_no_select_star()

  stats <- bq_dry_run_stats(query, billing)
  # Rejected SQL never enters the dry-run cache, so it cannot be run.
  assert_select_statement(stats$statement_type)
  bytes <- stats$bytes
  assert_query_size(bytes)
  gb <- round(bytes / 1e9, 3)
  cost <- estimate_cost_usd(bytes)
  # Avoid scientific notation ("1e-04") in the user-facing message
  cost_display <- format(cost, scientific = FALSE)

  cache_dry_run(query, bytes, stats$n_tables)

  list(
    bytes_processed = bytes,
    gb_processed = gb,
    cost_usd_estimate = cost,
    sql = str_trim(query),
    message = glue(
      "This query will scan {gb} GB (estimated cost: ${cost_display}). ",
      "Present this to the user in exactly this order: ",
      "(1) the full SQL in a fenced ```sql code block, laid out for ",
      "reading: SELECT, FROM, each JOIN, WHERE, GROUP BY, ORDER BY and ",
      "LIMIT start a new line, each selected column and each AND/OR ",
      "condition is on its own indented line, subqueries and CTEs are ",
      "indented, and no line is longer than about 80 characters. Never ",
      "show it as one long line, and never paraphrase or summarise the ",
      "query instead of showing it; ",
      "(2) a one-sentence plain-English explanation of what the query does ",
      "(which tables it reads and what it filters, joins, or aggregates), ",
      "since the user may still be learning SQL and BigQuery; ",
      "(3) the GB scanned and estimated cost, then ask: ",
      "'Shall I run this query?'. ",
      "Monthly free tier usage is unknown — do not assume the query is ",
      "free. Wait for explicit confirmation before proceeding. ",
      "If confirmed, pass this same SQL to orion_run_bq_query or ",
      "orion_export_bq_query. Line breaks and spacing do not affect the ",
      "match with this estimate; any other change, however small, needs a ",
      "new estimate. Do NOT rewrite or re-derive the SQL."
    )
  ) |> toJSON(auto_unbox = TRUE, pretty = TRUE)
}

# Gate every execution path: cost estimate done, read-only single SELECT,
# no SELECT *, billing project set. Returns the billing project and the
# maximumBytesBilled cap derived from the cached estimate.
validate_query <- function(sql) {
  key <- normalize_sql(sql)
  if (!key %in% names(dry_run_cache)) {
    stop(glue(
      "Cost estimate required. Call orion_estimate_query_cost with this ",
      "exact SQL first, show the user the SQL and the estimated cost, and ",
      "wait for their confirmation before running the query."
    ))
  }

  # Checked again at run time: this gate must not rely on how SQL got into
  # the dry-run cache.
  assert_read_only_sql(sql) |> assert_no_select_star()

  billing <- Sys.getenv("BQ_BILLING_PROJECT")
  if (billing == "") stop("BQ_BILLING_PROJECT environment variable not set")

  list(
    billing = billing,
    max_bytes = max_bytes_billed(
      dry_run_cache[[key]],
      if (key %in% names(dry_run_tables)) dry_run_tables[[key]] else 1L
    )
  )
}

# Run a paid query job with the byte cap and label. If BigQuery stops it at
# the cap, say why: the data may have grown since the estimate.
run_capped_job <- function(sql, gate, ...) {
  job <- do.call(
    bq_perform_query,
    c(list(sql, billing = gate$billing, labels = JOB_LABELS, ...),
      job_limit_args(gate$max_bytes))
  )
  tryCatch(
    bq_job_wait(job, quiet = TRUE),
    error = function(e) {
      if (str_detect(conditionMessage(e), regex("bytes billed", ignore_case = TRUE))) {
        stop(glue(
          "BigQuery stopped the query because it would bill more than the ",
          "dry-run estimate allowed; nothing was charged. The data may have ",
          "changed since the estimate. Call orion_estimate_query_cost again ",
          "and show the user the new cost. ({conditionMessage(e)})"
        ), call. = FALSE)
      }
      stop(e)
    }
  )
  job
}

job_gb_billed <- function(query_stats) {
  round(as.numeric(query_stats$totalBytesBilled %||% 0) / 1e9, 3)
}

job_billing_note <- function(query_stats) {
  cache_hit <- isTRUE(query_stats$cacheHit)
  gb_billed <- job_gb_billed(query_stats)

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
  gate <- validate_query(sql)
  job <- run_capped_job(sql, gate)

  meta <- bq_job_meta(job)
  run_at <- Sys.time()
  query_stats <- meta$statistics$query
  billing_note <- job_billing_note(query_stats)

  dest <- meta$configuration$query$destinationTable
  dest_table <- bq_table(dest$projectId, dest$datasetId, dest$tableId)
  assert_download_size(bq_table_nrow(dest_table), billing_note)
  result <- bq_table_download(dest_table, quiet = TRUE)

  list(
    result = result,
    cache_hit = isTRUE(query_stats$cacheHit),
    billing_note = billing_note,
    run_at = run_at,
    gb_billed = job_gb_billed(query_stats)
  )
}

# Store a query result together with the SQL and run details.
store_run <- function(run, query) {
  store_result(run$result, sql = query, run_at = run$run_at,
               gb_billed = run$gb_billed)
}

# ---- Stored results ---------------------------------------------------------
# Every executed query keeps its full result in the R session under a stable
# name (q1, q2, ...). Only a size-capped preview travels to the LLM; the
# analysis tools below operate on the complete data by reference.

results_env <- new.env(parent = emptyenv())
result_counter <- 0L

# Results stay in memory until the server stops, so only the most recent
# ones are kept. Read at store time, after the query has been paid for, so
# a bad value falls back to the default instead of losing the result.
stored_results_limit <- function() {
  tryCatch(
    floor(read_limit_env("MAX_STORED_RESULTS", "20")),
    error = function(e) {
      message(glue("{conditionMessage(e)} Keeping the default of 20 results."))
      20
    }
  )
}

result_number <- function(name) {
  if (!str_detect(name, "^q[0-9]+$")) return(NA_integer_)
  as.integer(str_remove(name, "^q"))
}

stored_result_names <- function() {
  stored <- ls(results_env)
  stored[order(map_int(stored, result_number))]
}

# Name -> list(sql, run_at, gb_billed) for each stored result, written next
# to exports so a file records the query that produced it.
results_meta <- new.env(parent = emptyenv())

store_result <- function(df, sql = NULL, run_at = Sys.time(), gb_billed = NULL,
                         max_results = stored_results_limit()) {
  result_counter <<- result_counter + 1L
  name <- as.character(glue("q{result_counter}"))
  assign(name, df, envir = results_env)
  if (!is.null(sql)) {
    assign(name, list(sql = sql, run_at = run_at, gb_billed = gb_billed),
           envir = results_meta)
  }

  stored <- stored_result_names()
  old <- stored[map_int(stored, result_number) <= result_counter - max(1, max_results)]
  rm(list = old, envir = results_env)
  rm(list = intersect(old, ls(results_meta)), envir = results_meta)
  name
}

# NULL for results stored without a query (only in tests).
get_result_meta <- function(name) get0(name, envir = results_meta, inherits = FALSE)

get_result <- function(name) {
  if (!exists(name, envir = results_env, inherits = FALSE)) {
    stored <- stored_result_names()
    available <- if (length(stored) > 0) {
      glue("Available results: {str_flatten(stored, ', ')}.")
    } else {
      "No query results are stored in this session yet — run a query first."
    }
    number <- result_number(name)
    if (!is.na(number) && number <= result_counter) {
      stop(glue(
        "Result '{name}' is no longer stored: the server keeps only the ",
        "{stored_results_limit()} most recent results (MAX_STORED_RESULTS) ",
        "and has dropped older ones. {available} To get the data back, run ",
        "its SQL again (the result gets a new name); tell the user first ",
        "that this is billed again unless BigQuery serves it from its ",
        "24-hour cache."
      ))
    }
    stop(glue("No stored result named '{name}'. {available}"))
  }
  get(name, envir = results_env, inherits = FALSE)
}

has_nested <- function(df) any(map_lgl(df, is.list))

# Serialize a result for the LLM: CSV for flat data (far more
# token-efficient than JSON), JSON lines for nested data. Output is capped
# at `budget` characters, cutting only at complete rows.
render_rows <- function(df, budget = MAX_RESULT_CHARS) {
  nested <- has_nested(df)
  total_rows <- nrow(df)
  # Serialise only the rows that could possibly fit, so a large result is
  # cheap to preview. A JSON line takes at least three characters ("{}" and
  # a newline); a CSV line at least one, because readr writes a lone empty
  # string as an empty line.
  max_rows <- if (nested) budget %/% 3 else budget
  df <- head(df, min(total_rows, max_rows))

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
    truncated = keep < total_rows,
    format = if (nested) "json" else "csv"
  )
}

orion_run_bq_query <- function(query) {
  run <- execute_bq_query(query)
  result <- run$result
  name <- store_run(run, query)
  rendered <- render_rows(result)

  size_note <- if (rendered$truncated) {
    glue(
      "Showing only the first {rendered$rows_shown} of {nrow(result)} rows — ",
      "the full output exceeds the response budget. The COMPLETE result is ",
      "stored in the orion-mcp server as '{name}'. Do NOT draw conclusions ",
      "from the truncated rows alone: use orion_result_summary, ",
      "orion_result_count, or orion_result_slice on '{name}' to analyse ",
      "the full data, or orion_export_result to save it to a file (free — ",
      "the data is already stored in the orion-mcp server)."
    )
  } else {
    glue(
      "Complete result shown below; also stored in the orion-mcp server ",
      "as '{name}'."
    )
  }

  glue(
    "Result '{name}': {nrow(result)} rows x {ncol(result)} columns ",
    "({rendered$format} below). {size_note} {run$billing_note}\n",
    "SQL:\n{str_trim(query)}\n",
    "PRESENTATION INSTRUCTIONS: The user may be new to SQL and BigQuery — ",
    "support their learning. When presenting these results: ",
    "(1) summarise the key findings in plain language; ",
    "(2) explain in one or two jargon-free sentences how the query worked — ",
    "which tables it read and what the filters, joins, or aggregations did; ",
    "(3) mention that the full result is stored in the orion-mcp server ",
    "as '{name}' (only a preview was sent to you) and can be analysed ",
    "further or exported to a file on request. The user cannot open ",
    "'{name}' in their own R session; to work with it in R or another ",
    "tool, export it first. ",
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

# The filename comes from the model, so it is reduced to a bare name inside
# `dir` (no "../" or absolute paths), given the extension of the format that
# is actually written, and never overwrites an earlier export: a counter is
# appended instead (results.csv, results_1.csv, ...). `also` lists the
# extensions of companion files (the .sql sidecar) that must be free too,
# so the data file and its sidecar always share a name.
export_path <- function(filename, ext, dir = EXPORT_DIR, also = character()) {
  stem <- if (is.null(filename)) "" else {
    filename |>
      basename() |>
      tools::file_path_sans_ext()
  }
  if (stem %in% c("", ".", "..")) {
    stem <- glue("orion_export_{format(Sys.time(), '%Y%m%d_%H%M%S')}")
  }

  taken <- function(candidate) {
    any(file.exists(file.path(dir, glue("{candidate}.{c(ext, also)}"))))
  }
  candidate <- stem
  i <- 0L
  while (taken(candidate)) {
    i <- i + 1L
    candidate <- glue("{stem}_{i}")
  }
  file.path(dir, glue("{candidate}.{ext}"))
}

# The SQL that produced an export, with a header comment on when it ran,
# what it returned and what it cost, so the file can be cited and rerun.
sql_sidecar_text <- function(meta, n_rows, data_file) {
  run_at <- format(meta$run_at, "%Y-%m-%d %H:%M:%S UTC", tz = "UTC")
  gb <- if (is.null(meta$gb_billed)) "unknown" else format(meta$gb_billed, scientific = FALSE)
  c(
    "-- Query run on Google BigQuery through orion-mcp.",
    glue("-- Run at: {run_at}"),
    glue("-- Rows returned: {n_rows}"),
    glue("-- GB billed: {gb}"),
    glue("-- Data file: {data_file}"),
    "",
    meta$sql
  )
}

write_export <- function(result, filename = NULL, meta = NULL) {
  nested <- has_nested(result)
  ext <- if (nested) "json" else "csv"
  with_sql <- !is.null(meta$sql)

  dir.create(EXPORT_DIR, showWarnings = FALSE, recursive = TRUE)
  path <- export_path(filename, ext, also = if (with_sql) "sql" else character())

  if (nested) {
    write(toJSON(result, auto_unbox = TRUE, pretty = TRUE), path)
  } else {
    write_csv(result, path)
  }

  sql_path <- NULL
  if (with_sql) {
    sql_path <- str_replace(path, "\\.[a-z]+$", ".sql")
    writeLines(sql_sidecar_text(meta, nrow(result), basename(path)), sql_path)
  }

  renamed <- !is.null(filename) && basename(path) != filename
  list(path = path, format = ext, renamed = renamed, sql_path = sql_path)
}

# Mentions the .sql file in the export message, if one was written.
export_sql_note <- function(export) {
  if (is.null(export$sql_path)) return("")
  glue(
    "The SQL, with the run date, rows returned and GB billed, was saved ",
    "next to it as {export$sql_path}, for citing in a methods section or ",
    "rerunning later. "
  )
}

# Tells the model when the file name differs from the one it asked for.
export_rename_note <- function(export, filename) {
  if (!isTRUE(export$renamed)) return("")
  glue(
    "The requested filename '{filename}' was saved as '{basename(export$path)}' ",
    "(exports stay in the export folder, the extension matches the format, ",
    "and existing files are not overwritten). "
  )
}

orion_export_result <- function(name, filename = NULL) {
  result <- get_result(name)
  export <- write_export(result, filename, get_result_meta(name))

  list(
    path = export$path,
    sql_path = export$sql_path,
    format = export$format,
    rows = nrow(result),
    columns = ncol(result),
    result_name = name,
    message = glue(
      "Exported stored result '{name}' ({nrow(result)} rows x ",
      "{ncol(result)} columns) to {export$path} (a path inside the ",
      "container) without touching BigQuery — this cost nothing. ",
      "{export_rename_note(export, filename)}",
      "{export_sql_note(export)}",
      "{export_mount_note()} ",
      "When presenting this to the user, say in plain language what was ",
      "exported and where the files appear on their machine."
    )
  ) |>
    compact() |>  # drops sql_path when no .sql file was written
    toJSON(auto_unbox = TRUE, pretty = TRUE)
}

orion_export_bq_query <- function(query, filename = NULL) {
  run <- execute_bq_query(query)
  result <- run$result
  name <- store_run(run, query)
  export <- write_export(result, filename, get_result_meta(name))

  list(
    path = export$path,
    sql_path = export$sql_path,
    format = export$format,
    rows = nrow(result),
    columns = ncol(result),
    result_name = name,
    message = glue(
      "Exported {nrow(result)} rows x {ncol(result)} columns to ",
      "{export$path} (a path inside the container). {run$billing_note} ",
      "{export_rename_note(export, filename)}",
      "{export_sql_note(export)}",
      "{export_mount_note()} ",
      "The result is also stored in the orion-mcp server as '{name}' for ",
      "the analysis tools. ",
      "SQL:\n{str_trim(query)}\n",
      "When presenting this to the user, say in plain language what was ",
      "exported, where the files appear on their machine, and briefly ",
      "explain what the query did — the user may be learning SQL and ",
      "BigQuery."
    )
  ) |>
    compact() |>
    toJSON(auto_unbox = TRUE, pretty = TRUE)
}

# ---- Writing to BigQuery ------------------------------------------------------
# Writes never happen through SQL (assert_read_only_sql blocks DML/DDL).
# They are only possible through these tools, where the destination table
# is an explicit argument the user has seen and confirmed. Whether a write
# is allowed at all depends on the user's IAM roles on the destination
# project.

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
  gate <- validate_query(query)
  dest <- parse_bq_table(destination)

  job <- run_capped_job(
    query,
    gate,
    destination_table = dest,
    create_disposition = "CREATE_IF_NEEDED",
    write_disposition = if (isTRUE(overwrite)) "WRITE_TRUNCATE" else "WRITE_EMPTY"
  )

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
      "SQL:\n{str_trim(query)}\n",
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

# ---- mcptools patch -----------------------------------------------------------

# mcptools declares the prompts and resources capabilities but answers
# prompts/list and resources/list with "Method not found", which some
# clients show as an error. This answers both with empty lists. Still needed
# with mcptools 1.0.3; remove once
# https://github.com/posit-dev/mcptools/issues/59 is fixed. It replaces an
# internal function, so if mcptools renames it the patch is skipped with a
# warning on stderr instead of stopping the server. Called by server.R.
patch_mcptools_list_methods <- function(handler = "handle_message_from_client") {
  tryCatch(
    {
      ns <- asNamespace("mcptools")
      orig <- get(handler, envir = ns, inherits = FALSE)
      cat_json <- get("cat_json", envir = ns, inherits = FALSE)
      stopifnot(is.function(orig), is.function(cat_json))
      assignInNamespace(
        handler,
        function(line) {
          msg <- tryCatch(jsonlite::parse_json(line), error = function(e) NULL)
          result <- if (is.list(msg) && is.character(msg$method)) {
            switch(msg$method,
              "prompts/list"   = list(prompts = list()),
              "resources/list" = list(resources = list()),
              NULL
            )
          }
          if (!is.null(result)) {
            cat_json(list(jsonrpc = "2.0", id = msg$id, result = result))
            return(invisible(NULL))
          }
          orig(line)
        },
        ns = "mcptools"
      )
      invisible(TRUE)
    },
    error = function(e) {
      message(glue(
        "Warning: mcptools patch for prompts/list and resources/list not ",
        "applied ({conditionMessage(e)}); clients may report 'Method not ",
        "found' for these two requests. Other requests are not affected."
      ))
      invisible(FALSE)
    }
  )
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
        "The image carries a schema snapshot from build time and refreshes ",
        "it from GitHub at start-up (unless SCHEMA_REFRESH=0). Pull the ",
        "newest image, or check the container's network access and the ",
        "SCHEMA_REPO/SCHEMA_PATH environment variables, then restart it."
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
        "and mount application_default_credentials.json into the container ",
        "(see README). ",
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
