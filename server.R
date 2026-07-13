suppressPackageStartupMessages({
  library(ellmer)
  library(mcptools)
  library(tidyverse)
  library(glue)
  library(jsonlite)
  library(bigrquery)
})

# Progress output would corrupt the JSON-RPC stream on stdio transport.
options(bigrquery.quiet = TRUE)

source(if (file.exists("R/functions.R")) "R/functions.R" else "/app/R/functions.R")

# Authenticate with application default credentials (gcloud ADC mounted in
# Docker). Failure is not fatal: schema browsing works without credentials,
# and orion_health_check reports what is missing.
auth_scope <- bq_adc_auth()
if (is.null(auth_scope)) {
  message("BigQuery auth skipped: no application default credentials found.")
} else {
  message(glue("BigQuery authenticated with scope {auth_scope}"))
}

schema_data <- load_schema_data()

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
      orion_health_check,
      glue(
        "SETUP CHECK: Verify the orion-mcp installation end to end — ",
        "schema metadata, Google credentials, billing project, BigQuery ",
        "connectivity (via a free dry run), and the export folder mount. ",
        "Completely free and safe to run at any time. Use when the user ",
        "asks whether the tool is working, after installation, or when a ",
        "query fails in a way that suggests a setup problem (missing ",
        "credentials, billing project, network). Walk the user through ",
        "each failed check's fix step by step."
      )
    ),
    tool(
      orion_list_datasets,
      glue(
        "STEP 1 OF QUERY WORKFLOW: List all ORION-DBs datasets available ",
        "on BigQuery from various providers of open research information. ",
        "Does NOT return schemas — call orion_list_tables next to explore ",
        "a specific dataset. Use this as the entry point whenever the user ",
        "asks about available data or wants to run a query. ",
        "IMPORTANT: Use the dataset descriptions as-is — do NOT infer ",
        "recency from dates embedded in dataset names. 'instant' means the ",
        "most recent snapshot. For more info see <https://orion-dbs.community/>"
      )
    ),
    tool(
      orion_list_tables,
      glue(
        "STEP 2 OF QUERY WORKFLOW: List all tables in a specific ",
        "project/dataset with descriptions. Call this after ",
        "orion_list_datasets to identify which table to query. Use the ",
        "table descriptions to pick the right table before fetching its ",
        "full schema."
      ),
      arguments = list(
        project = type_string("The GCP project ID"),
        dataset = type_string("The BigQuery dataset name")
      )
    ),
    tool(
      orion_get_db_schema,
      glue(
        "STEP 3 OF QUERY WORKFLOW: Get the full BigQuery schema for a ",
        "specific table. Call this after orion_list_tables to understand ",
        "column names and types before writing SQL. Also useful when ",
        "comparing table structures across datasets. ",
        "Schema reading rules: ",
        "- REPEATED fields must be flattened with UNNEST() in queries. ",
        "- RECORD fields are accessed via dot notation ",
        "(e.g. open_access.oa_status). ",
        "- Identify the primary identifier column (e.g. doi, id) — you ",
        "will need it for COUNT DISTINCT and joins."
      ),
      arguments = list(
        project = type_string("The GCP project ID"),
        dataset = type_string("The BigQuery dataset name"),
        table = type_string("The BigQuery table name")
      )
    ),
    tool(
      orion_estimate_query_cost,
      glue(
        "STEP 4 OF QUERY WORKFLOW: Perform a BigQuery dry run to validate ",
        "SQL syntax and estimate scan cost. This does NOT execute the ",
        "query — it only returns estimated bytes processed. Dry runs are ",
        "completely free and must ALWAYS be called before ",
        "orion_run_bq_query. Takes exactly one argument — query — which ",
        "must be the complete, fully-qualified SQL string. ",
        "Cost calculation: $6.25 per TB scanned (1 TB = 1,000 GB; the ",
        "approximate BigQuery on-demand rate). ",
        "After receiving the estimate, STOP and present it following the ",
        "returned message exactly: show the full SQL in a fenced code ",
        "block, explain in plain language what it does, state the GB ",
        "scanned and cost, then ask 'Shall I run this query?'. ",
        "Do NOT call orion_run_bq_query until the user explicitly confirms ",
        "they want to proceed. ",
        "CRITICAL: the SQL passed to orion_run_bq_query MUST be ",
        "byte-for-byte identical to the SQL passed here. Do NOT reformat, ",
        "rewrite, or improve the SQL after the dry run. If the user asks ",
        "to change the query in any way, call orion_estimate_query_cost ",
        "again with the new SQL before presenting a cost estimate or ",
        "running it. Never reuse a previous cost estimate for modified ",
        "SQL. If the estimate exceeds 100 GB, highlight this prominently ",
        "and strongly recommend the user confirm."
      ),
      arguments = list(
        query = type_string(glue(
          "The fully-qualified BigQuery SQL query to dry-run ",
          "(include project.dataset.table in the query itself)"
        ))
      )
    ),
    tool(
      orion_run_bq_query,
      glue(
        "STEP 5 OF QUERY WORKFLOW: Execute a BigQuery SQL query, return ",
        "results, and summarise them in plain language. ",
        "PREREQUISITE: orion_estimate_query_cost MUST have been called for ",
        "this exact SQL AND the user must have explicitly confirmed they ",
        "want to proceed after seeing the cost. Never skip the cost ",
        "confirmation step, even for small queries. Takes exactly one ",
        "argument — query — which must be the complete, fully-qualified ",
        "SQL string. ",
        "Every result is stored in the R session under a stable name ",
        "(q1, q2, ...) and only a size-capped preview is returned inline. ",
        "If the response says the preview was TRUNCATED, do not reason ",
        "from the partial rows — use orion_result_summary, ",
        "orion_result_count, or orion_result_slice on the stored result, ",
        "or orion_export_result to save it to a file. All of these are ",
        "free: they use the data already in the R session and never ",
        "re-query BigQuery. ",
        "SQL rules: ",
        "- Never use SELECT * — name only the columns needed to minimise ",
        "bytes scanned. ",
        "- Never use COUNT(*) — always count distinct over a unique ",
        "identifier (e.g. COUNT(DISTINCT doi)). ",
        "- Always lowercase identifiers before joining across collections: ",
        "LOWER(doi), LOWER(orcid), LOWER(issn). ",
        "- DOI fields may be stored as bare DOIs ('10.1234/foo') or as ",
        "URLs ('https://doi.org/10.1234/foo') depending on the dataset. ",
        "- Always normalise DOIs before joining using REGEXP_REPLACE (not ",
        "REGEXP_EXTRACT) to avoid introducing NULLs: ",
        "LOWER(REGEXP_REPLACE(doi, r'^https?://doi\\.org/', '')) — this ",
        "safely strips the prefix if present and leaves bare DOIs ",
        "unchanged. ",
        "- Use ROR IDs when searching for an institution first"
      ),
      arguments = list(
        query = type_string(glue(
          "The fully-qualified BigQuery SQL query to execute ",
          "(include project.dataset.table in the query itself)"
        ))
      )
    ),
    tool(
      orion_result_summary,
      glue(
        "ANALYSIS TOOL (after STEP 5): Per-column summary of a stored ",
        "query result (type, missing values, distinct count, min/mean/max ",
        "or example values). Operates on the FULL result held in the R ",
        "session, not the truncated preview. Use this first when a query ",
        "result was truncated, to understand the data before slicing or ",
        "counting. Costs nothing — no BigQuery access involved."
      ),
      arguments = list(
        name = type_string(glue(
          "Name of the stored result (e.g. 'q1'), as reported by ",
          "orion_run_bq_query"
        ))
      )
    ),
    tool(
      orion_result_count,
      glue(
        "ANALYSIS TOOL (after STEP 5): Frequency counts over one or more ",
        "columns of a stored query result, sorted by count (top 100 ",
        "groups). Operates on the FULL result held in the R session, not ",
        "the truncated preview. Use for questions like 'how does this ",
        "break down by year / institution / type?' without re-querying ",
        "BigQuery. Costs nothing — no BigQuery access involved."
      ),
      arguments = list(
        name = type_string("Name of the stored result (e.g. 'q1')"),
        by = type_string(glue(
          "Comma-separated column names to group by ",
          "(e.g. 'year' or 'institution,year')"
        ))
      )
    ),
    tool(
      orion_result_slice,
      glue(
        "ANALYSIS TOOL (after STEP 5): Return selected rows and columns ",
        "from a stored query result, with an optional single filter. ",
        "Operates on the FULL result held in the R session, not the ",
        "truncated preview. Use to inspect specific subsets of a large ",
        "result (e.g. one institution, one year) without re-querying ",
        "BigQuery. Costs nothing."
      ),
      arguments = list(
        name = type_string("Name of the stored result (e.g. 'q1')"),
        columns = type_string(
          glue(
            "Optional comma-separated column names to return ",
            "(all columns if omitted)"
          ),
          required = FALSE
        ),
        filter_column = type_string(
          "Optional column to filter on",
          required = FALSE
        ),
        filter_op = type_string(
          glue(
            "Filter operator: ==, !=, >, <, >=, <=, or contains ",
            "(case-insensitive substring)"
          ),
          required = FALSE
        ),
        filter_value = type_string(
          glue(
            "Value to compare against (numbers as plain strings, ",
            "e.g. '2023')"
          ),
          required = FALSE
        ),
        n = type_integer(
          "Maximum rows to return (default 50)",
          required = FALSE
        )
      )
    ),
    tool(
      orion_export_result,
      glue(
        "EXPORT (preferred): Write a stored query result (q1, q2, ...) to ",
        "a file. This is completely free and instant — the data is already ",
        "in the R session, so BigQuery is never contacted. ALWAYS use this ",
        "instead of orion_export_bq_query when the user wants to save a ",
        "result that has already been run with orion_run_bq_query. Flat ",
        "results are exported as CSV; nested results as JSON. The response ",
        "says whether the export folder is mounted to the host; if it is ",
        "not, relay the warning to the user so they can add the volume ",
        "mount before the file is lost when the container stops."
      ),
      arguments = list(
        name = type_string("Name of the stored result (e.g. 'q1')"),
        filename = type_string(
          glue(
            "Optional filename for the export (e.g. 'results.csv'). ",
            "Auto-generated with timestamp if omitted."
          ),
          required = FALSE
        )
      )
    ),
    tool(
      orion_save_result_to_bq,
      glue(
        "WRITE TOOL: Save a stored query result (q1, q2, ...) as a table ",
        "in BigQuery via a load job — load jobs are FREE. Use when the ",
        "user wants to persist results in BigQuery (e.g. in their own ",
        "project) instead of, or in addition to, a local file. ",
        "The user's own IAM permissions decide whether the write is ",
        "allowed; typically the destination is a dataset in their billing ",
        "project. ",
        "NEVER invent the destination: ask the user for it, or confirm ",
        "your suggestion explicitly before calling this tool. ",
        "By default this fails if the destination table already exists; ",
        "set overwrite only when the user explicitly asked to replace it."
      ),
      arguments = list(
        name = type_string("Name of the stored result (e.g. 'q1')"),
        destination = type_string(
          "Fully qualified destination table as 'project.dataset.table'"
        ),
        overwrite = type_boolean(
          "Replace the table if it already exists (default FALSE)",
          required = FALSE
        )
      )
    ),
    tool(
      orion_query_to_table,
      glue(
        "WRITE TOOL / ALTERNATIVE TO STEP 5: Execute a SELECT query and ",
        "write the results DIRECTLY to a destination BigQuery table, ",
        "without downloading anything. Use for large derived tables that ",
        "should live in BigQuery rather than pass through the R session. ",
        "Only the query scan is billed; the write itself is free. ",
        "PREREQUISITES: orion_estimate_query_cost MUST have been called ",
        "for this exact SQL, the user must have confirmed the cost, AND ",
        "the user must have named or explicitly confirmed the destination ",
        "table — never invent it. Only single SELECT statements are ",
        "accepted; DML/DDL is blocked. ",
        "By default this fails if the destination table already exists; ",
        "set overwrite only when the user explicitly asked to replace it."
      ),
      arguments = list(
        query = type_string(glue(
          "The fully-qualified BigQuery SQL query to execute ",
          "(include project.dataset.table in the query itself)"
        )),
        destination = type_string(
          "Fully qualified destination table as 'project.dataset.table'"
        ),
        overwrite = type_boolean(
          "Replace the table if it already exists (default FALSE)",
          required = FALSE
        )
      )
    ),
    tool(
      orion_export_bq_query,
      glue(
        "ALTERNATIVE TO STEP 5: Execute a BigQuery SQL query and export ",
        "full results straight to a file. Use this ONLY when the query has ",
        "not been run in this session yet and the user wants the data as a ",
        "file (e.g. an expected-large result that should never be shown ",
        "inline). If the result already exists as a stored result (q1, ",
        "q2, ...), use orion_export_result instead — it is free and does ",
        "not contact BigQuery. Flat results are exported as CSV; nested ",
        "results as JSON. ",
        "PREREQUISITE: orion_estimate_query_cost MUST have been called for ",
        "this exact SQL AND the user must have explicitly confirmed they ",
        "want to proceed. Returns the file path, format, and row/column ",
        "count — not the data itself. The response says whether the export ",
        "folder is mounted to the host; if it is not, relay the warning to ",
        "the user so they can add the volume mount before the file is lost ",
        "when the container stops."
      ),
      arguments = list(
        query = type_string(glue(
          "The fully-qualified BigQuery SQL query to execute ",
          "(include project.dataset.table in the query itself)"
        )),
        filename = type_string(
          glue(
            "Optional filename for the export (e.g. 'results.csv'). ",
            "Auto-generated with timestamp if omitted."
          ),
          required = FALSE
        )
      )
    )
  )
)
