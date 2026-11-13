# orion-mcp 0.1.0 (2026-11-13)

First tagged release. The image is published as `ghcr.io/subugoe/orion-mcp:0.1.0` as well as `latest`. This list covers the changes from the code review of November 2026.

## Safety and cost

- The read-only check reads the SQL with a scanner that handles all GoogleSQL literals and comments, and the dry run must report a single `SELECT` statement.
- Each paid query is sent with a byte limit (the estimate plus BigQuery's minimum per table), so BigQuery stops a query that would bill more than the estimate.
- `MAX_GB_PER_QUERY` (default 500) refuses larger scans at the estimate. `MAX_DOWNLOAD_ROWS` (default 1,000,000) stops larger downloads.
- `SELECT *` is refused at the estimate, before the user is asked to confirm. This also covers `SELECT DISTINCT *`, `SELECT AS STRUCT *`, `SELECT a, *`, `table.*`, `` `t`.* `` and `t . *`. Wildcard table names such as `` `p.d.events_*` `` are allowed.
- The cost estimate is priced per TiB. Before, it was about 9 % too high.
- A query matches its estimate regardless of line breaks and spacing outside string literals, so the model can show the SQL laid out for reading.

## Results and exports

- The server keeps the 20 most recent results (`MAX_STORED_RESULTS`) and says when a result was dropped. Names it never gave, such as `q0`, get a plain "not found".
- Messages say that results are stored in the orion-mcp server, and that the user has to export a result to work with it in R or another tool.
- Exports stay in the export folder and never overwrite a file; a number is added instead.
- Export file names keep their dots (`top10.2024.csv`); only a data extension such as `.csv` is replaced.
- Each export of a query result comes with a `.sql` file: the SQL, the run date, the rows returned, the dry-run estimate and the GB billed. A run served from BigQuery's 24-hour cache is marked as such.
- Previews of large results are built faster.

## Set-up and image

- The image carries a snapshot of the table schemas and is rebuilt every day. A failed schema download at start-up no longer stops the server; `SCHEMA_REFRESH=0` skips it.
- Smaller image, based on `rocker/r-ver:4.5.3` with packages from a dated snapshot (ellmer 0.5.1, mcptools 1.0.3, bigrquery 1.6.2).
- Only the Google login file is mounted, read-only, instead of the whole `~/.config/gcloud` folder. The `rstudio` service in `docker-compose.yml` is removed.
- Every tool has a title and read-only or destructive hints.
- `prompts/list` and `resources/list` get empty lists instead of "Method not found". mcptools' tools for switching to another R session are turned off.
