# Agent (monitor + Bedrock RCA + alerting)

- **db.py** – Oracle connection and fetch functions for BatchLog/ReportLog (long-running and failed).
- **monitor.py** – Polls DB every 30 seconds, prints anomalies to console. Run with `python -m agent.monitor` from project root (after `source venv/bin/activate` and `pip install -r requirements.txt`).
- **Phase 5** will add: aws_env.py, bedrock_agent.py, processed.py and wire RCA into the monitor.
- **Phase 6** will add: alerting.py and SNS/local alerts.

Ensure Oracle container `oracledb` is running and `config/paths.json` exists before running the monitor.
