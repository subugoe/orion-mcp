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

test_that("only the most recent results are kept", {
  first <- result_counter + 1L
  names <- map_chr(1:5, \(i) store_result(tibble(i = i), max_results = 3))
  expect_equal(names, paste0("q", first:(first + 4)))
  expect_equal(tail(stored_result_names(), 3), names[3:5])
  expect_length(stored_result_names(), 3)
  expect_equal(get_result(names[5])$i, 5)

  err <- expect_error(get_result(names[1]))
  expect_match(conditionMessage(err), "no longer stored")
  expect_match(conditionMessage(err), "MAX_STORED_RESULTS")
  expect_match(conditionMessage(err), str_flatten(names[3:5], ", "), fixed = TRUE)
  # A name that never existed gets the plain message
  expect_error(get_result("q99999"), "No stored result named 'q99999'")
  expect_error(get_result("results"), "No stored result named 'results'")
})

test_that("MAX_STORED_RESULTS is read from the environment, with a safe fallback", {
  withr::with_envvar(c(MAX_STORED_RESULTS = "2"), {
    expect_equal(stored_results_limit(), 2)
    store_result(tibble(x = 1))
    store_result(tibble(x = 2))
    store_result(tibble(x = 3))
    expect_length(stored_result_names(), 2)
  })
  withr::with_envvar(c(MAX_STORED_RESULTS = NA), {
    expect_equal(stored_results_limit(), 20)
  })
  withr::with_envvar(c(MAX_STORED_RESULTS = "many"), {
    expect_message(limit <- stored_results_limit(), "Keeping the default of 20")
    expect_equal(limit, 20)
  })
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

test_that("render_rows serialises only rows that can fit the budget", {
  # toJSON() cannot serialise an environment, so rendering would fail if
  # the last row were serialised at all.
  nested <- tibble(id = 1:1000, x = c(as.list(1:999), list(new.env())))
  rendered <- render_rows(nested, budget = 300)
  expect_true(rendered$truncated)
  expect_gt(rendered$rows_shown, 0)
  expect_lte(nchar(rendered$text), 300)

  # truncated is judged against the full row count, not the serialised part
  flat <- tibble(a = rep("x", 100))
  rendered <- render_rows(flat, budget = 50)
  expect_true(rendered$truncated)
  expect_lte(nchar(rendered$text), 50)
  expect_false(render_rows(flat, budget = 1000)$truncated)

  # Empty strings are one character per row; the cap must not cut them early
  empty <- tibble(a = rep("", 10))
  rendered <- render_rows(empty, budget = 12)
  expect_equal(rendered$rows_shown, 10)
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

test_that("export filenames stay in the export folder", {
  dir <- withr::local_tempdir()
  expect_equal(export_path("../x.csv", "csv", dir), file.path(dir, "x.csv"))
  expect_equal(export_path("/etc/x.csv", "csv", dir), file.path(dir, "x.csv"))
  expect_equal(export_path("a/b/../../x.csv", "csv", dir), file.path(dir, "x.csv"))
  expect_match(basename(export_path("..", "csv", dir)), "^orion_export_\\d{8}_\\d{6}\\.csv$")
  expect_match(basename(export_path(NULL, "json", dir)), "^orion_export_.*\\.json$")

  name <- store_result(tibble(x = 1:2))
  out <- fromJSON(orion_export_result(name, "../outside.csv"), simplifyVector = FALSE)
  expect_equal(dirname(out$path), EXPORT_DIR)
  expect_false(file.exists(file.path(dirname(EXPORT_DIR), "outside.csv")))
  expect_match(out$message, "was saved as 'outside.csv'")
})

test_that("export filenames get the extension of the format written", {
  dir <- withr::local_tempdir()
  expect_equal(basename(export_path("results.json", "csv", dir)), "results.csv")
  expect_equal(basename(export_path("results", "csv", dir)), "results.csv")
  expect_equal(basename(export_path("results.CSV", "json", dir)), "results.json")

  nested <- store_result(tibble(doi = "10.1/a", authors = list(list("A"))))
  out <- fromJSON(orion_export_result(nested, "nested.csv"), simplifyVector = FALSE)
  expect_equal(basename(out$path), "nested.json")
  expect_equal(out$format, "json")
})

test_that("exports never overwrite an existing file", {
  dir <- withr::local_tempdir()
  writeLines("old", file.path(dir, "r.csv"))
  writeLines("old", file.path(dir, "r_1.csv"))
  expect_equal(basename(export_path("r.csv", "csv", dir)), "r_2.csv")

  name <- store_result(tibble(x = 1:2))
  first <- fromJSON(orion_export_result(name, "twice.csv"), simplifyVector = FALSE)
  second <- fromJSON(orion_export_result(name, "twice.csv"), simplifyVector = FALSE)
  expect_equal(basename(first$path), "twice.csv")
  expect_equal(basename(second$path), "twice_1.csv")
  expect_false(str_detect(first$message, "was saved as"))
  expect_match(second$message, "was saved as 'twice_1.csv'")
})

test_that("exports of query results carry a .sql file with the query", {
  sql <- "SELECT doi,\n  year -- keep comments\nFROM `p.d.t`\nWHERE note = 'a;b'"
  run_at <- as.POSIXct("2026-11-12 10:30:00", tz = "UTC")
  name <- store_result(
    tibble(doi = c("10.1/a", "10.1/b"), year = 2024:2025),
    sql = sql, run_at = run_at, gb_billed = 1.234
  )
  out <- fromJSON(orion_export_result(name, "../cited.json"), simplifyVector = FALSE)
  expect_equal(out$path, file.path(EXPORT_DIR, "cited.csv"))
  expect_equal(out$sql_path, file.path(EXPORT_DIR, "cited.sql"))
  expect_true(file.exists(out$sql_path))
  expect_match(out$message, "cited.sql", fixed = TRUE)

  text <- read_file(out$sql_path)
  expect_true(str_detect(text, fixed(sql)))
  expect_match(text, "-- Run at: 2026-11-12 10:30:00 UTC", fixed = TRUE)
  expect_match(text, "-- Rows returned: 2", fixed = TRUE)
  expect_match(text, "-- GB billed: 1.234", fixed = TRUE)
  expect_match(text, "-- Data file: cited.csv", fixed = TRUE)

  # The same name again: both files get the counter, nothing is overwritten
  again <- fromJSON(orion_export_result(name, "cited.csv"), simplifyVector = FALSE)
  expect_equal(basename(again$path), "cited_1.csv")
  expect_equal(basename(again$sql_path), "cited_1.sql")
  expect_match(read_file(again$sql_path), "-- Data file: cited_1.csv", fixed = TRUE)

  # A leftover .sql file alone also takes the name, so pairs stay matched
  writeLines("old", file.path(EXPORT_DIR, "pair.sql"))
  pair <- fromJSON(orion_export_result(name, "pair.csv"), simplifyVector = FALSE)
  expect_equal(basename(pair$path), "pair_1.csv")
  expect_equal(basename(pair$sql_path), "pair_1.sql")
  expect_equal(readLines(file.path(EXPORT_DIR, "pair.sql")), "old")

  nested <- store_result(
    tibble(doi = "10.1/a", authors = list(list("A"))),
    sql = "SELECT doi, authors FROM `p.d.t`", run_at = run_at, gb_billed = 0
  )
  out_nested <- fromJSON(orion_export_result(nested, "nested_q"), simplifyVector = FALSE)
  expect_equal(basename(out_nested$path), "nested_q.json")
  expect_equal(basename(out_nested$sql_path), "nested_q.sql")
  expect_match(read_file(out_nested$sql_path), "-- GB billed: 0\n", fixed = TRUE)

  # Results stored without a query get no .sql file
  plain <- fromJSON(orion_export_result(store_result(tibble(x = 1)), "plain.csv"),
                    simplifyVector = FALSE)
  expect_null(plain$sql_path)
  expect_false(file.exists(file.path(EXPORT_DIR, "plain.sql")))
})

test_that("stored results keep their SQL and run details until dropped", {
  run_at <- Sys.time()
  first <- store_result(tibble(x = 1), sql = "SELECT 1 AS x", run_at = run_at,
                        gb_billed = 0.5, max_results = 2)
  expect_equal(get_result_meta(first),
               list(sql = "SELECT 1 AS x", run_at = run_at, gb_billed = 0.5))
  store_result(tibble(x = 2), sql = "SELECT 2 AS x", max_results = 2)
  store_result(tibble(x = 3), sql = "SELECT 3 AS x", max_results = 2)
  expect_null(get_result_meta(first))

  expect_equal(job_gb_billed(list(totalBytesBilled = "1500000000")), 1.5)
  expect_equal(job_gb_billed(list(cacheHit = TRUE)), 0)
  expect_equal(job_gb_billed(NULL), 0)
})

test_that("SELECT * guard blocks wildcards but not regex literals or COUNT(*)", {
  guard <- function(sql) assert_read_only_sql(sql) |> assert_no_select_star()

  blocked <- c(
    "SELECT t.* FROM t",
    "select * from works",
    "SELECT a, w.* FROM works w",
    "SELECT DISTINCT * FROM t",
    "SELECT ALL * FROM t",
    "SELECT AS STRUCT * FROM t",
    "SELECT AS VALUE * FROM t",
    "select distinct as struct * from t",
    "WITH x AS (SELECT * FROM t) SELECT a FROM x"
  )
  for (sql in blocked) {
    expect_error(guard(sql), "SELECT \\* and table.\\* are not allowed", label = sql)
  }

  allowed <- c(
    "SELECT doi FROM t WHERE REGEXP_CONTAINS(v, r'v2\\..*')",
    "SELECT COUNT(*) FROM t",
    "SELECT DISTINCT COUNT(*) AS n FROM t",
    "SELECT year, COUNT(*) AS n FROM t GROUP BY year",
    "SELECT doi FROM t -- not SELECT * here"
  )
  for (sql in allowed) {
    expect_no_error(guard(sql))
  }
})

test_that("cost estimate refuses SELECT * before contacting BigQuery", {
  withr::with_envvar(c(BQ_BILLING_PROJECT = "bill"), {
    # Fails before bq_dry_run_stats(), so no request is made
    expect_error(orion_estimate_query_cost("SELECT DISTINCT * FROM `p.d.t`"),
                 "SELECT \\* and table.\\* are not allowed")
  })
  expect_false("SELECT DISTINCT * FROM `p.d.t`" %in% names(dry_run_cache))
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

test_that("cost estimate uses the per-TiB on-demand rate", {
  expect_equal(estimate_cost_usd(2^40), 6.25)
  expect_equal(estimate_cost_usd(0), 0)
  # 10^12 bytes is less than a TiB, so it costs less than $6.25
  expect_equal(estimate_cost_usd(1e12), round(1e12 / 2^40 * 6.25, 4))
  expect_lt(estimate_cost_usd(1e12), 5.7)
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

# ---- server.R over stdio (no credentials, no schemas, no network) ----------

has_server_pkgs <- requireNamespace("ellmer", quietly = TRUE) &&
  requireNamespace("mcptools", quietly = TRUE)

# Starts server.R, sends JSON-RPC lines on stdin and returns the parsed
# replies. GOOGLE_APPLICATION_CREDENTIALS points at a missing file, so gargle
# finds no credentials and makes no request; SCHEMA_DIR is an empty folder.
run_server <- function(requests) {
  dir <- withr::local_tempdir()
  input <- file.path(dir, "requests.jsonl")
  output <- file.path(dir, "replies.jsonl")
  initialize <- paste0(
    '{"jsonrpc":"2.0","id":0,"method":"initialize","params":',
    '{"protocolVersion":"2025-06-18","capabilities":{},',
    '"clientInfo":{"name":"test","version":"0"}}}'
  )
  # mcptools stops reading at end of input and drops lines it has not
  # handled yet, so stdin stays open until the reply to a final sentinel
  # request (id 999, an unknown method) has been written, or 30 s pass.
  writeLines(
    c(initialize, requests, '{"jsonrpc":"2.0","id":999,"method":"orion/sentinel"}'),
    input
  )
  script <- glue(
    "{{ cat {shQuote(input)}; i=0; ",
    "while [ $i -lt 300 ] && ! grep -q '\"id\":999' {shQuote(output)} 2>/dev/null; ",
    "do sleep 0.1; i=$((i+1)); done; }} | ",
    "GOOGLE_APPLICATION_CREDENTIALS={shQuote(file.path(dir, 'no-adc.json'))} ",
    "SCHEMA_DIR={shQuote(dir)} ",
    "{shQuote(file.path(R.home('bin'), 'Rscript'))} server.R ",
    "> {shQuote(output)} 2>/dev/null"
  )
  system2("sh", c("-c", shQuote(script)))
  replies <- map(readLines(output), \(line) fromJSON(line, simplifyVector = FALSE))
  set_names(replies, map_chr(replies, \(r) as.character(r$id)))
}

test_that("tools/list carries titles and read-only/destructive hints", {
  skip_if_not(has_server_pkgs, "ellmer and mcptools are needed")
  replies <- run_server('{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
  tools <- replies[["1"]]$result$tools
  expect_length(tools, 13)
  ann <- set_names(map(tools, "annotations"), map_chr(tools, "name"))

  expect_true(all(map_lgl(ann, \(a) is.character(a$title) && nzchar(a$title))))

  read_only <- c(
    "orion_health_check", "orion_list_datasets", "orion_list_tables",
    "orion_get_db_schema", "orion_estimate_query_cost",
    "orion_result_summary", "orion_result_count", "orion_result_slice"
  )
  for (nm in read_only) expect_true(ann[[nm]]$readOnlyHint, label = nm)

  writing <- setdiff(names(ann), read_only)
  for (nm in writing) {
    expect_false(ann[[nm]]$readOnlyHint, label = nm)
    expect_identical(
      ann[[nm]]$destructiveHint,
      nm %in% c("orion_save_result_to_bq", "orion_query_to_table"),
      label = nm
    )
  }
})

test_that("prompts/list and resources/list get empty lists, not an error", {
  skip_if_not(has_server_pkgs, "ellmer and mcptools are needed")
  replies <- run_server(c(
    '{"jsonrpc":"2.0","id":1,"method":"prompts/list"}',
    '{"jsonrpc":"2.0","id":2,"method":"resources/list"}',
    '{"jsonrpc":"2.0","id":3,"method":"tools/list"}'
  ))
  expect_identical(replies[["1"]]$result, list(prompts = list()))
  expect_identical(replies[["2"]]$result, list(resources = list()))
  # Other requests still reach mcptools' own handler
  expect_length(replies[["3"]]$result$tools, 13)
  expect_equal(replies[["999"]]$error$code, -32601)
})

test_that("a changed mcptools internal skips the patch with a warning", {
  expect_message(
    ok <- patch_mcptools_list_methods(handler = "no_such_internal_function"),
    "Warning: mcptools patch .* not applied"
  )
  expect_false(ok)
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
