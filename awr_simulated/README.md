# Simulated AWR reports

This folder holds **simulated** AWR (Automatic Workload Repository) style reports for the demo.

- **awr_sample.txt** – Sample diagnostic report with Load Profile, Top Wait Events, Top SQL by elapsed time, and a few parameters. The AI agent (Phase 5) reads this file and uses it as context for root cause analysis.

On a real/production setup you can replace this with:
- Real AWR report output (if your Oracle edition supports it), or
- Data from V$SESSION / V$SQL (top long-running queries, wait events) formatted similarly.
