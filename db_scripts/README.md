# Code repository (sample)

This folder acts as the **“code repo”** for the demo: sample SQL/PL-SQL that the AI agent can use when analyzing an anomaly.

- **batch_reconciliation.sql** – Simulated long-running batch (full table scan, no index on `created_at`). Matches the dummy anomaly `RECONCILIATION_BATCH` in BatchLog.
- **report_regulatory_export.sql** – Simulated report that uses a global temporary table; large result set can cause ORA-01652 (temp segment). Matches the dummy anomaly `REGULATORY_EXPORT` in ReportLog.

The agent (Phase 5) loads these files by name or by scanning the folder and includes their contents in the prompt to Bedrock for root cause and recommendations.

On office/dev you can point `config/paths.json` → `code_repo_dir` to the real package or script folder, or use batch_name/report_name to look up the matching file (e.g. `RECONCILIATION_BATCH` → `batch_reconciliation.sql` or the actual package source).
