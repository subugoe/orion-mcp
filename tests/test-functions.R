# Unit tests for R/functions.R. Run from the repo root:
#
#   Rscript tests/test-functions.R
#
# Covers everything that does not need BigQuery access. The BigQuery
# round-trip (execute_bq_query, orion_estimate_query_cost) is verified at
# install time by the orion_health_check tool instead.

suppressPackageStartupMessages({
  library(testthat)
  library(dplyr)
  library(purrr)
  library(stringr)
  library(readr)
  library(tibble)
  library(glue)
  library(jsonlite)
  # Optional: only needed by the destination-table tests, which skip
  # without it. No BigQuery access happens either way.
  if (requireNamespace("bigrquery", quietly = TRUE)) library(bigrquery)
})

Sys.setenv(EXPORT_DIR = file.path(tempdir(), "orion-exports"))
Sys.unsetenv("BQ_BILLING_PROJECT")

source("R/functions.R")

# Fixture standing in for the schema metadata loaded at server startup
schema_data <- tibble(
  project = c("p1", "p1", "p2"),
  dataset = c("d1", "d1", "d2"),
  dataset_description = c("Dataset one", "Dataset one", "Dataset two"),
  table = c("t1", "t2", "t3"),
  description = c("Table 1", "Table 2", "Table 3"),
  schema = list(
    tibble(name = c("doi", "year"), type = c("STRING", "INTEGER")),
    tibble(name = "x", type = "STRING"),
    tibble(name = "y", type = "RECORD")
  )
)

test_that("schema browsing tools work against schema metadata", {
  datasets <- fromJSON(orion_list_datasets())
  expect_equal(nrow(datasets), 2)
  expect_equal(datasets$tables[datasets$dataset == "d1"], 2)

  tables <- fromJSON(orion_list_tables("p1", "d1"))
  expect_equal(tables$table, c("t1", "t2"))

  schema <- fromJSON(orion_get_db_schema("p1", "d1", "t1"))
  expect_equal(schema$name, c("doi", "year"))

  expect_error(orion_get_db_schema("p1", "d1", "nope"), "Not found")
})

test_that("schema tools return a clear message when no schema is loaded", {
  full <- schema_data
  assign("schema_data", full[0, ], envir = globalenv())
  withr::defer(assign("schema_data", full, envir = globalenv()))

  msgs <- c(
    orion_list_datasets(),
    orion_list_tables("p1", "d1"),
    orion_get_db_schema("p1", "d1", "t1")
  )
  expect_length(msgs, 3)
  for (m in msgs) {
    expect_match(m, "No schema metadata is loaded")
    expect_match(m, "orion_health_check")
  }

  # An empty tibble with no columns at all (empty SCHEMA_DIR) behaves the same
  assign("schema_data", tibble(), envir = globalenv())
  expect_match(orion_list_datasets(), "orion_health_check")
})

test_that("load_schema_data skips unreadable files instead of failing", {
  dir <- withr::local_tempdir()
  expect_equal(nrow(load_schema_data(dir)), 0)

  writeLines(
    '{"project":"p","dataset":"d","dataset_description":"x","table":"t","description":"y"}',
    file.path(dir, "collection_info_ok.jsonl")
  )
  writeLines("{ this is not json", file.path(dir, "collection_info_bad.jsonl"))
  expect_message(loaded <- load_schema_data(dir), "Skipping unreadable")
  expect_equal(loaded$table, "t")
})

# ---- refresh-schemas.sh (no network: the "API" is a local directory) -------

refresh_script <- normalizePath("refresh-schemas.sh")
good_line <- paste0(
  '{"project":"p","dataset":"d","dataset_description":"x",',
  '"table":"t","description":"y"}'
)

# Lay out a fake GitHub contents API under `root`. `files` maps file name to
# content; a NULL content lists the file but does not create it (a failed
# download). Returns the value for SCHEMA_API_URL.
fake_schema_repo <- function(root, files) {
  api_dir <- file.path(root, "api", "repos", "o", "r", "contents")
  dir.create(api_dir, recursive = TRUE)
  src <- file.path(root, "src")
  dir.create(src)
  listing <- map(names(files), \(n) {
    list(name = n, download_url = paste0("file://", file.path(src, n)))
  })
  writeLines(toJSON(listing, auto_unbox = TRUE), file.path(api_dir, "data"))
  iwalk(files, \(content, n) {
    if (!is.null(content)) writeLines(content, file.path(src, n))
  })
  paste0("file://", file.path(root, "api"))
}

run_refresh <- function(api_url, data_dir, args = character(), env = character()) {
  out <- suppressWarnings(system2(
    "sh", c(refresh_script, args),
    stdout = TRUE, stderr = TRUE,
    env = c(
      paste0("SCHEMA_API_URL=", api_url),
      "SCHEMA_REPO=o/r", "SCHEMA_PATH=data",
      paste0("SCHEMA_DIR=", data_dir), env
    )
  ))
  list(status = attr(out, "status") %||% 0L, output = out)
}

has_refresh_tools <- nzchar(Sys.which("curl")) && nzchar(Sys.which("jq"))

test_that("refresh replaces the snapshot only when every file is valid", {
  skip_if_not(has_refresh_tools, "curl and jq are needed")
  root <- withr::local_tempdir()
  data_dir <- file.path(root, "data")
  dir.create(data_dir)
  writeLines("old", file.path(data_dir, "collection_info_old.jsonl"))
  writeLines("kept", file.path(data_dir, "collection_info_a.jsonl"))

  api <- fake_schema_repo(file.path(root, "ok"), list(
    collection_info_a.jsonl = good_line,
    collection_info_b.jsonl = good_line
  ))
  res <- run_refresh(api, data_dir)
  expect_equal(res$status, 0)
  expect_setequal(
    list.files(data_dir, all.files = TRUE, no.. = TRUE),
    c("collection_info_a.jsonl", "collection_info_b.jsonl")
  )
  expect_equal(readLines(file.path(data_dir, "collection_info_a.jsonl")), good_line)
})

test_that("refresh keeps the snapshot and exits 0 when the source is unreachable", {
  skip_if_not(has_refresh_tools, "curl and jq are needed")
  data_dir <- withr::local_tempdir()
  writeLines("snapshot", file.path(data_dir, "collection_info_a.jsonl"))

  # Nothing listens on port 9
  res <- run_refresh("http://127.0.0.1:9", data_dir, "--best-effort")
  expect_equal(res$status, 0)
  expect_equal(sum(grepl("Schema refresh failed", res$output)), 1)
  expect_equal(readLines(file.path(data_dir, "collection_info_a.jsonl")), "snapshot")
  expect_equal(list.files(data_dir, all.files = TRUE, no.. = TRUE), "collection_info_a.jsonl")

  # The strict mode (image build) reports the same failure as an error
  res <- run_refresh("http://127.0.0.1:9", data_dir)
  expect_equal(res$status, 1)
})

test_that("refresh leaves the snapshot alone after a partial or invalid download", {
  skip_if_not(has_refresh_tools, "curl and jq are needed")
  root <- withr::local_tempdir()
  data_dir <- file.path(root, "data")
  dir.create(data_dir)
  writeLines("snapshot", file.path(data_dir, "collection_info_a.jsonl"))

  cases <- list(
    missing_file = list(collection_info_a.jsonl = good_line, collection_info_b.jsonl = NULL),
    empty_file = list(collection_info_a.jsonl = good_line, collection_info_b.jsonl = ""),
    invalid_json = list(collection_info_a.jsonl = good_line, collection_info_b.jsonl = "{ nope"),
    not_objects = list(collection_info_a.jsonl = good_line, collection_info_b.jsonl = "[1,2]"),
    no_files = list(README.md = "x")
  )
  for (case in names(cases)) {
    api <- fake_schema_repo(file.path(root, case), cases[[case]])
    res <- run_refresh(api, data_dir, "--best-effort")
    expect_equal(res$status, 0, label = case)
    expect_match(paste(res$output, collapse = "\n"), "Schema refresh failed", label = case)
    expect_equal(
      list.files(data_dir, all.files = TRUE, no.. = TRUE),
      "collection_info_a.jsonl",
      label = case
    )
    expect_equal(readLines(file.path(data_dir, "collection_info_a.jsonl")), "snapshot", label = case)
  }
})

test_that("SCHEMA_REFRESH=0 skips the network step", {
  skip_if_not(has_refresh_tools, "curl and jq are needed")
  data_dir <- withr::local_tempdir()
  # Would fail loudly if the script tried to use it
  res <- run_refresh("http://127.0.0.1:9", data_dir, "--best-effort", "SCHEMA_REFRESH=0")
  expect_equal(res$status, 0)
  expect_false(any(grepl("failed|Fetching", res$output)))
  expect_match(res$output, "SCHEMA_REFRESH=0")
})

test_that("results are stored under stable names and retrievable", {
  df <- tibble(x = 1:3)
  name <- store_result(df)
  expect_match(name, "^q[0-9]+$")
  expect_identical(get_result(name), df)

  expect_error(get_result("q999"), "No stored result named 'q999'")
})

make_flat_result <- function() {
  tibble(
    institution = rep(paste("University", sprintf("%03d", 1:100)), each = 5),
    ror = rep(sprintf("https://ror.org/%08x", 1:100), each = 5),
    year = rep(2021:2025, times = 100),
    pubs = rpois(500, 200)
  )
}

test_that("render_rows returns complete flat results as CSV within budget", {
  rendered <- render_rows(make_flat_result())
  expect_equal(rendered$format, "csv")
  expect_false(rendered$truncated)
  expect_equal(rendered$rows_shown, 500)
})

test_that("render_rows truncates at complete rows under a tight budget", {
  rendered <- render_rows(make_flat_result(), budget = 2000)
  expect_true(rendered$truncated)
  expect_gt(rendered$rows_shown, 0)
  expect_lte(nchar(rendered$text), 2000)
})

test_that("render_rows uses JSON lines for nested results", {
  nested <- tibble(
    doi = c("10.1/a", "10.1/b"),
    authors = list(list("A", "B"), list("C"))
  )
  rendered <- render_rows(nested)
  expect_equal(rendered$format, "json")
  expect_false(rendered$truncated)
})

test_that("render_rows keeps rows intact despite embedded newlines", {
  messy <- tibble(id = 1:2, title = c("line1\nline2", "ok"))
  rendered <- render_rows(messy)
  expect_length(str_split_1(rendered$text, "\n"), 3)  # header + 2 rows
})

test_that("render_rows handles zero-row results", {
  rendered <- render_rows(tibble(doi = character(0)))
  expect_equal(rendered$rows_shown, 0)
  expect_false(rendered$truncated)
})

test_that("result summary reports types, missing and distinct correctly", {
  df <- tibble(
    ror = c(sprintf("r%03d", 1:100), rep(NA, 40)),
    pubs = c(rpois(139, 10), NA),
    nested = as.list(1:140)
  )
  name <- store_result(df)
  s <- fromJSON(orion_result_summary(name), simplifyVector = FALSE)

  expect_equal(s$rows, 140)
  ror_col <- s$column_summary[[1]]
  expect_equal(ror_col$distinct, 100)  # NA must not count as a value
  expect_equal(ror_col$missing, 40)
  expect_match(s$column_summary[[3]]$type, "nested")
})

test_that("result counts aggregate over the full result", {
  name <- store_result(make_flat_result())
  expect_match(orion_result_count(name, "year"), "5 distinct groups")
  expect_match(
    orion_result_count(name, "institution, year"),
    "500 distinct groups"
  )
  expect_error(orion_result_count(name, "nope"), "Columns not in result")
})

test_that("result slice filters, selects and reports true match counts", {
  name <- store_result(make_flat_result())

  sliced <- orion_result_slice(
    name,
    columns = "institution,pubs",
    filter_column = "year", filter_op = "==", filter_value = "2023",
    n = 200
  )
  expect_match(sliced, "100 rows matched")

  contains <- orion_result_slice(
    name,
    filter_column = "institution", filter_op = "contains",
    filter_value = "007"
  )
  expect_match(contains, "5 rows matched")

  expect_error(
    orion_result_slice(name, filter_column = "year", filter_op = "~",
                       filter_value = "1"),
    "Unsupported filter_op"
  )
  expect_error(
    orion_result_slice(name, filter_column = "pubs", filter_op = ">",
                       filter_value = "abc"),
    "is not a number"
  )
})

test_that("stored results export to file without touching BigQuery", {
  name <- store_result(make_flat_result())
  out <- fromJSON(orion_export_result(name, "test_export.csv"),
                  simplifyVector = FALSE)

  expect_true(file.exists(out$path))
  expect_equal(out$format, "csv")
  expect_equal(out$rows, 500)
  expect_match(out$message, "without touching BigQuery")

  reread <- read_csv(out$path, show_col_types = FALSE)
  expect_equal(dim(reread), c(500, 4))

  nested <- tibble(doi = "10.1/a", authors = list(list("A")))
  out_nested <- fromJSON(orion_export_result(store_result(nested)),
                         simplifyVector = FALSE)
  expect_true(file.exists(out_nested$path))
  expect_equal(out_nested$format, "json")
})

test_that("SELECT * guard blocks wildcards but not regex literals", {
  strip <- function(sql) {
    sql |>
      str_replace_all("'[^']*'", "''") |>
      str_replace_all('"[^"]*"', '""')
  }
  guard <- function(sql) {
    str_detect(
      strip(sql),
      regex("SELECT\\s+\\*|\\w+\\.\\*", ignore_case = TRUE)
    )
  }

  expect_false(guard("SELECT doi FROM t WHERE REGEXP_CONTAINS(v, r'v2\\..*')"))
  expect_true(guard("SELECT t.* FROM t"))
  expect_true(guard("select * from works"))
  expect_true(guard("SELECT a, w.* FROM works w"))
})

test_that("normalize_sql collapses whitespace only", {
  expect_equal(normalize_sql("  SELECT a,\n   b\tFROM t  "),
               "SELECT a, b FROM t")
})

test_that("unrun queries are rejected before reaching BigQuery", {
  expect_error(execute_bq_query("SELECT doi FROM t"),
               "Cost estimate required")
})

test_that("read-only gate blocks DML, DDL and scripts", {
  blocked <- c(
    "INSERT INTO `p.d.t` (x) VALUES (1)",
    "DELETE FROM `p.d.t` WHERE TRUE",
    "UPDATE `p.d.t` SET x = 1 WHERE TRUE",
    "DROP TABLE `p.d.t`",
    "CREATE TABLE `p.d.t` (x INT64)",
    "MERGE `p.d.t` USING `p.d.s` ON FALSE WHEN MATCHED THEN DELETE",
    "TRUNCATE TABLE `p.d.t`",
    "EXECUTE IMMEDIATE 'SELECT 1'"
  )
  for (sql in blocked) {
    expect_error(assert_read_only_sql(sql), "read-only SELECT")
  }

  expect_error(
    assert_read_only_sql("SELECT 1; DROP TABLE `p.d.t`"),
    "Multi-statement"
  )
})

test_that("read-only gate allows legitimate SELECT variants", {
  allowed <- c(
    "SELECT doi FROM `p.d.t`",
    "WITH x AS (SELECT doi FROM `p.d.t`) SELECT doi FROM x",
    "select doi from `p.d.t`",
    "SELECT doi FROM `p.d.t`;",
    "SELECT doi FROM `p.d.t` WHERE note = 'a;b'",
    "-- leading comment\nSELECT doi FROM `p.d.t`",
    "/* block comment */ SELECT doi FROM `p.d.t`"
  )
  for (sql in allowed) {
    expect_no_error(assert_read_only_sql(sql))
  }
})

test_that("quotes inside comments cannot hide a second statement", {
  expect_error(
    assert_read_only_sql("SELECT 1 -- '\n; DROP TABLE a.b.c -- '"),
    "Multi-statement"
  )
  expect_error(
    assert_read_only_sql("SELECT 1 # '\n; DROP TABLE a.b.c # '"),
    "Multi-statement"
  )
  expect_error(
    assert_read_only_sql("SELECT 1 /* ' */ ; DROP TABLE a.b.c -- '"),
    "Multi-statement"
  )
})

test_that("scanner reads GoogleSQL literals and comments correctly", {
  allowed <- c(
    "SELECT 'it\\'s; fine' AS x",
    'SELECT "a \\" ; b" AS x',
    "SELECT '''multi\nline ' ; ''' AS x",
    'SELECT """a "" ; b""" AS x',
    "SELECT r'\\d+;' AS x",
    "SELECT RB'\\x;' AS x",
    "SELECT b'a;b' AS x",
    "-- don't worry\nSELECT doi FROM `p.d.t`",
    "# a hash comment with ; and '\nSELECT doi FROM `p.d.t`",
    "SELECT doi FROM `p.d.t` WHERE note = 'a;b'"
  )
  for (sql in allowed) {
    expect_no_error(assert_read_only_sql(sql))
  }

  # Raw strings: the backslash does not escape, so the quote ends the literal
  expect_error(assert_read_only_sql("SELECT r'\\'; DROP TABLE t"),
               "Multi-statement|Unterminated")
  expect_error(assert_read_only_sql("SELECT 'open"), "Unterminated")
  expect_error(assert_read_only_sql("SELECT 1 /* open"), "Unterminated")
  expect_error(assert_read_only_sql("SELECT '''open"), "Unterminated")

  expect_equal(blank_sql_literals("SELECT 'a' -- c\n, 1"), "SELECT ''  \n, 1")
})

test_that("only BigQuery's SELECT statement type passes", {
  expect_no_error(assert_select_statement("SELECT"))
  expect_error(assert_select_statement("SCRIPT"), "'SCRIPT'")
  expect_error(assert_select_statement("INSERT"), "'INSERT'")
  expect_error(assert_select_statement(NULL), "'unknown'")
})

test_that("destination tables must be fully qualified", {
  skip_if_not_installed("bigrquery")
  dest <- parse_bq_table("my-project.my_dataset.my_table")
  expect_equal(dest$project, "my-project")
  expect_equal(dest$dataset, "my_dataset")
  expect_equal(dest$table, "my_table")

  expect_error(parse_bq_table("my_dataset.my_table"), "fully qualified")
  expect_error(parse_bq_table("just_a_table"), "fully qualified")
  expect_error(parse_bq_table("a..b"), "fully qualified")
})

test_that("query-to-table enforces the same gates as run", {
  expect_error(
    orion_query_to_table("SELECT doi FROM `p.d.t`", "p.d.out"),
    "Cost estimate required"
  )
  cache_dry_run("DROP TABLE `p.d.t`", 0)
  expect_error(
    orion_query_to_table("DROP TABLE `p.d.t`", "p.d.out"),
    "read-only SELECT"
  )
})

test_that("dry-run cache stores estimated bytes per normalised SQL", {
  cache_dry_run("SELECT  doi\nFROM `p.d.t`", 5e9, n_tables = 2)
  key <- "SELECT doi FROM `p.d.t`"
  expect_equal(dry_run_cache[[key]], 5e9)
  expect_equal(dry_run_tables[[key]], 2L)

  # validate_query passes the cap on; it needs a billing project
  withr::with_envvar(c(BQ_BILLING_PROJECT = "bill"), {
    gate <- validate_query("SELECT doi FROM `p.d.t`")
    expect_equal(gate$billing, "bill")
    expect_equal(gate$max_bytes, max_bytes_billed(5e9, 2))
  })
})

test_that("maximumBytesBilled cap covers the estimate and BigQuery's minimum", {
  mib <- 2^20
  expect_null(max_bytes_billed(0))
  expect_equal(max_bytes_billed(1), 11 * mib)  # 10 MB floor, whole MB
  expect_equal(max_bytes_billed(1, n_tables = 3), 31 * mib)
  expect_gte(max_bytes_billed(5e9), 5e9)

  expect_equal(job_limit_args(NULL), list())
  args <- job_limit_args(12 * 1e9)
  expect_identical(args$configuration$query$maximumBytesBilled, "12000000000")

  # Merges into the request without dropping the query fields
  skip_if_not_installed("bigrquery")
  body <- list(configuration = list(query = list(query = "SELECT 1")))
  merged <- do.call(bigrquery:::bq_body, c(list(body), args))
  expect_equal(merged$configuration$query$query, "SELECT 1")
  expect_equal(merged$configuration$query$maximumBytesBilled, "12000000000")
})

test_that("per-query size limit is enforced and configurable", {
  expect_no_error(assert_query_size(499e9, max_gb = 500))
  expect_no_error(assert_query_size(500e9, max_gb = 500))
  expect_error(assert_query_size(501e9, max_gb = 500), "MAX_GB_PER_QUERY")

  withr::with_envvar(c(MAX_GB_PER_QUERY = "lots"), {
    expect_error(assert_query_size(1), "MAX_GB_PER_QUERY must be a positive")
  })
  withr::with_envvar(c(MAX_GB_PER_QUERY = "1"), {
    expect_error(assert_query_size(2e9), "above the server limit of 1 GB")
  })
  withr::with_envvar(c(MAX_GB_PER_QUERY = NA), {
    expect_no_error(assert_query_size(400e9))
    expect_error(assert_query_size(600e9), "500 GB")
  })
})

test_that("large results are not downloaded", {
  note <- "BigQuery billed 1.5 GB for this run."
  expect_no_error(assert_download_size(1e6, note, max_rows = 1e6))
  err <- expect_error(assert_download_size(2e6, note, max_rows = 1e6))
  expect_match(conditionMessage(err), "2,000,000 rows")
  expect_match(conditionMessage(err), "billed 1.5 GB", fixed = TRUE)
  expect_match(conditionMessage(err), "orion_query_to_table")
  expect_no_error(assert_download_size(NA, note, max_rows = 1))

  withr::with_envvar(c(MAX_DOWNLOAD_ROWS = "abc"), {
    expect_error(assert_download_size(10, note), "MAX_DOWNLOAD_ROWS must be")
  })
})

test_that("health check reports per-layer status without credentials", {
  health <- fromJSON(orion_health_check(), simplifyVector = FALSE)

  expect_named(
    health$checks,
    c("schema_metadata", "google_credentials", "billing_project",
      "bigquery_connection", "export_folder")
  )
  expect_equal(health$checks$schema_metadata$status, "ok")
  expect_match(health$checks$schema_metadata$detail, "2 datasets")
  expect_equal(health$checks$billing_project$status, "failed")
  expect_match(health$checks$billing_project$fix, "BQ_BILLING_PROJECT")
  expect_equal(health$checks$bigquery_connection$status, "skipped")
  expect_true(
    health$checks$export_folder$status %in% c("ok", "warning", "unknown")
  )
})

cat("\nAll tests passed.\n")
