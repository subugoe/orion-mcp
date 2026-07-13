# Unit tests for R/functions.R. Run from the repo root:
#
#   Rscript tests/test-functions.R
#
# Covers everything that does not need BigQuery access. The BigQuery
# round-trip (execute_bq_query, orion_estimate_query_cost) is verified at
# install time by the orion_health_check tool instead.

suppressPackageStartupMessages({
  library(testthat)
  library(tidyverse)
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
  dry_run_cache <<- c(dry_run_cache,
                      normalize_sql("DROP TABLE `p.d.t`"))
  expect_error(
    orion_query_to_table("DROP TABLE `p.d.t`", "p.d.out"),
    "read-only SELECT"
  )
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
