# Production Architecture — Resilient Credit+ Guardian

Production context: **Oracle database on EC2**; **GitHub Copilot** integrated in the production codebase for developer assistance. This doc gives a **balanced production diagram**, **cost-justified AWS usage**, and **Q&A** for production and for mapping dev to production.

---

## 1. Production architecture (balanced)

### Design choices (cost-focused)

- **Oracle on EC2** — Already in place. No change; no extra AWS managed-DB cost.
- **Application on EC2** — One EC2 (or second EC2) runs the same Python app (FastAPI + monitor loop). **Why not Lambda for the monitor?** Lambda in VPC to Oracle means cold starts, connection overhead per invocation, and 15‑min max. A single small EC2 running the monitor loop is predictable and often cheaper than frequent Lambda + API Gateway for a 24/7 dashboard. **Justification:** One t3.small (or t3.medium if shared with other apps) for app + monitor avoids per-request API Gateway + Lambda cost and keeps ops simple.
- **EventBridge Scheduler (optional)** — If we move the monitor to “triggered” runs (e.g. every 5 min) instead of a loop, EventBridge can invoke a Lambda that does one poll + RCA + alert. **Use only if** we want to turn off the app EC2 when not needed; otherwise the loop on EC2 is simpler and justified.
- **AWS Bedrock** — Already used for RCA. **Justification:** Pay-per-use (per token); no model hosting; same as dev. No extra service.
- **AWS SNS** — Already used for two-stage alerts. **Justification:** Pay per message (very low cost); no need for a separate queue unless we add retry/backlog. Keep as-is.
- **No API Gateway, no ECS, no Step Functions** unless we have a clear scaling or integration need. For single-region, single-tenant or low-volume, EC2 + Bedrock + SNS is cost-effective and justified.

### Production components (6–7 boxes)

| Component | Production role | AWS / infra | Cost justification |
|-----------|------------------|-------------|--------------------|
| **Oracle Database** | Job logs (BatchLog, ReportLog), PL/SQL batches & reports, live SQL diagnostics. | **EC2** (existing). | Already on EC2; no additional AWS DB service. |
| **Application server (Python + FastAPI + monitor)** | Runs FastAPI (dashboard API + static pages), monitor loop (polls Oracle, detects anomalies, fetches diagnostics + code, calls Bedrock, sends SNS), in-memory state for UI. | **EC2** (one instance, or second instance if DB is on first). | Single always-on instance is cheaper than 24/7 API Gateway + Lambda for dashboard + polling; simpler ops. |
| **Web dashboard** | Same as dev: Batch/Report logs, alerts and RCA by job, start/stop monitoring, run jobs, mark as fail. Served by FastAPI; can sit behind ALB if we need HTTPS/domain. | **Browser → EC2 (or ALB → EC2)**. | No S3/CloudFront unless we need CDN or static-only; FastAPI serves HTML. |
| **AWS Bedrock (Claude)** | Same as dev: receives anomaly + live diagnostic + PL/SQL code; returns ROOT_CAUSE, RECOMMENDATIONS, CODE_FIX. | **Bedrock** (invoke-model). | Pay per token; only used when an anomaly is detected; no idle cost. |
| **AWS SNS** | Same as dev: two alerts per incident (immediate + RCA). | **SNS Topic** (email, optional SMS). | Pay per message; minimal cost; no queue needed for this volume. |
| **Config / secrets** | paths.json, SNS topic ARN, AWS credentials. | **EC2 config files or SSM Parameter Store (optional)**. | SSM is low cost if we want to avoid storing secrets in files; otherwise env/file on EC2 is free. |
| **GitHub Copilot** | Used in the **production codebase** (IDE/code assist). | **Not in runtime diagram.** | Developer productivity; does not run in production. Shown as “Dev/Ops” if needed. |

### Production flow (same logic as dev)

- **Dashboard ↔ App (EC2):** Start/stop monitoring, run batch/report, mark fail, refresh; app returns job lists, status, alerts, RCA.
- **App (EC2) → Oracle (EC2):** Read BatchLog/ReportLog; run batches/reports via PL/SQL; get live diagnostics (V$SQL, etc.) and PL/SQL source (ALL_SOURCE) for anomaly window.
- **App (EC2) → Bedrock:** Send anomaly + diagnostic + code → receive RCA text.
- **App (EC2) → SNS:** Publish immediate alert; after RCA, publish second alert.
- **App (EC2):** In-memory state for dashboard (same as dev).

Optional: **CloudWatch Logs** — Ship app logs from EC2 to CloudWatch for observability (low cost, justified for ops).

---

## 2. Prompt for production diagram (copy-paste to diagram AI)

```
Draw a production architecture diagram. Balanced: clear picture with necessary detail.

Context: Oracle database runs on EC2. The monitoring and RCA application runs on AWS with minimal, cost-justified services.

Components (label with short description):
1. Oracle Database (on EC2) — Job logs (BatchLog, ReportLog), PL/SQL batches & reports, live SQL diagnostics for anomaly time window.
2. Application server (on EC2) — Python + FastAPI + monitor loop: serves dashboard API, polls Oracle every 5s, detects long-running/failed jobs, fetches live diagnostics and PL/SQL code, calls Bedrock for RCA, sends two-stage alerts via SNS; in-memory state for UI.
3. Web dashboard — Browser; same as dev: logs, alerts, RCA by job, start/stop monitoring, run jobs, mark as fail. Served by FastAPI on EC2.
4. AWS Bedrock (Claude) — Pay-per-use RCA: input anomaly + diagnostic + code; output root cause, recommendations, code fix.
5. AWS SNS — Two emails per incident: immediate alert, then RCA alert. Pay per message.
6. (Optional) Config / secrets — EC2 config or SSM Parameter Store for SNS ARN, credentials.

Connections:
- Dashboard ↔ App on EC2 (control, job lists, alerts, RCA)
- App on EC2 → Oracle on EC2 (read logs, run jobs, get diagnostics and code)
- App on EC2 → Bedrock (get RCA)
- App on EC2 → SNS (immediate alert, RCA alert)

Note: GitHub Copilot is used in the codebase for development; it is not a runtime component. You can add a small “Dev/Ops: GitHub Copilot” box outside the main flow if needed.

Keep 6 main boxes, 4–5 arrows. Show “EC2” for Oracle and App so production placement is clear. Label why each AWS service is used (Bedrock = pay-per-use RCA; SNS = low-cost alerts).
```

---

## 3. AWS services — why we use them (for judges)

| Service | Why we use it | Cost note |
|---------|----------------|-----------|
| **EC2** | Host Oracle (given) and the app (FastAPI + monitor). Single small instance for app avoids per-request cost of API Gateway + Lambda for 24/7 dashboard and polling. | Pay for instance hours; no per-request charge for the app. |
| **Bedrock** | RCA by Claude. No model hosting; invoke when an anomaly is detected. | Pay per token; only when RCA runs. |
| **SNS** | Two-stage alerts (immediate + RCA) to email. Reliable, minimal setup. | Pay per message; very low at our volume. |
| **Optional: EventBridge** | Only if we switch monitor to “scheduled Lambda” (e.g. every 5 min) instead of loop; then we’d use EventBridge to trigger Lambda. | Not in current design; add only if we remove app EC2. |
| **Optional: SSM Parameter Store** | Store SNS topic ARN and secrets instead of config files. | Low cost; improves security. |
| **Optional: CloudWatch Logs** | Central logs from app EC2. | Low cost; useful for production ops. |

We do **not** use API Gateway, ECS, Step Functions, SQS, or X-Ray in the base design — no need for the current scale; they would add cost without a clear requirement.

---

## 4. Q&A — Production architecture

**Q1: Why is the database on EC2 and not RDS?**  
**A:** Production is already set up with Oracle on EC2. Moving to RDS would require migration and possibly different licensing. We keep Oracle on EC2 and only add minimal AWS services (Bedrock, SNS) that add clear value (RCA, alerts) at low cost.

**Q2: Why run the application on EC2 instead of Lambda?**  
**A:** The app does two things: (1) serve a 24/7 dashboard and API, (2) run a monitor loop that polls Oracle every 5 seconds. Lambda has a 15‑minute max, cold starts in VPC, and would need API Gateway for the dashboard (per-request cost). One small EC2 runs both the dashboard and the monitor with a stable connection to Oracle and no per-request charge. For our volume, this is simpler and more cost-effective.

**Q3: Why Bedrock and not self-hosted or another AI service?**  
**A:** Bedrock is pay-per-use (per token); we only call it when an anomaly is detected. We don’t pay for idle time. Self-hosting would require a GPU instance (high cost). Bedrock gives us Claude for RCA without hosting or idle cost.

**Q4: Why SNS and not SQS or another queue?**  
**A:** We need to deliver two alerts (immediate and RCA) to operators. SNS is a simple pub/sub: one publish per alert, low cost per message. We don’t need a queue for retries or backlog at current scale; SNS is enough and cost-justified.

**Q5: How do we keep costs under control?**  
**A:** (1) EC2: one small instance for the app; (2) Bedrock: only when RCA runs; (3) SNS: pay per message; (4) no API Gateway, ECS, or Step Functions unless we have a clear scaling need. We add only services that directly support monitoring and RCA.

**Q6: Where does GitHub Copilot fit?**  
**A:** GitHub Copilot is used in the **development** of the production codebase (code completion, suggestions). It does not run in production. The production diagram shows runtime components only; Copilot can be shown as a “Dev/Ops” tool if we want to mention it.

**Q7: How is the production diagram different from the dev diagram?**  
**A:** Logic is the same (poll Oracle → detect anomaly → get diagnostics + code → Bedrock RCA → two SNS alerts). In production we explicitly show Oracle and the app on EC2, and we justify each AWS service (Bedrock, SNS) for cost and relevance.

---

## 5. Q&A — Mapping dev/local features to production

**Q1: Our local app uses a single machine with Oracle in Docker and Python. How does that map to production?**  
**A:** In production, Oracle runs on an EC2 instance (no Docker required for DB). The same Python codebase (FastAPI + monitor + diagnostics + Bedrock + SNS) runs on another EC2 instance (or the same one if resources allow). Same code, same flow; only the deployment target and config (DB host, SNS ARN) change.

**Q2: We poll Oracle every 5 seconds locally. Do we do the same in production?**  
**A:** Yes. The monitor loop (same `agent.monitor` code) runs on the app EC2 and polls Oracle every 5 seconds. If we later want to reduce cost, we could switch to EventBridge + Lambda (e.g. every 5 minutes) and reuse the same “run_once” logic, but the current production design keeps the 5‑second loop on EC2 for consistency with dev.

**Q3: Locally we use BatchLog and ReportLog and V$SQL for diagnostics. Does production use the same?**  
**A:** Yes. Production Oracle has the same schema (BatchLog, ReportLog) and the same grants (e.g. V$SQL, V$SQLTEXT, V$SQL_PLAN, V$SESSION_EVENT). The same `diagnostics.py` and `code_crawl.py` run on the app EC2 and connect to Oracle on EC2; no change to the feature set.

**Q4: We have a “Run batch/report” and “Mark as fail” in the dashboard. How does that work in production?**  
**A:** Same as dev. The dashboard is served by FastAPI on the app EC2. “Run batch/report” and “Mark as fail” call the same APIs, which call the same `job_runner` code and Oracle PL/SQL (PKG_JOB_RUNNER). Only the DB host in config changes (e.g. from localhost to the production Oracle EC2 host).

**Q5: Alerts are sent via SNS locally. In production?**  
**A:** Same. We use the same SNS topic (or a production topic ARN in config). `alerting.py` is unchanged; only the topic ARN and AWS credentials (e.g. from SSM or env on EC2) may differ.

**Q6: Our RCA uses live V$SQL diagnostics and ALL_SOURCE for code. Is that true in production too?**  
**A:** Yes. Production Oracle is configured with the same grants. The same `fetch_diagnostic_report()` and `get_code_snippets_for_rca()` run on the app EC2; they connect to Oracle on EC2 and get live diagnostics and PL/SQL source. No feature difference; only network is EC2 → EC2 instead of local.

**Q7: We store alerts and RCA in in-memory state for the dashboard. What about production?**  
**A:** Same. State is in-memory in the app process. If the app EC2 restarts, state resets (same as dev). We don’t add a database or Redis for this unless we need persistence across restarts; for hackathon and low volume, in-memory is acceptable and cost-free.

**Q8: How do we deploy the local codebase to production?**  
**A:** Same repo; deploy to app EC2 (e.g. git pull or CI/CD). Install Python, dependencies (oracledb, boto3, FastAPI, etc.), set config (DB host, SNS ARN, AWS credentials), run FastAPI (e.g. with gunicorn/uvicorn). GitHub Copilot is used when developing in that repo; it doesn’t affect deployment.

**Q9: What exactly is “the same” and what changes between dev and production?**  
**A:** **Same:** Application code (monitor, diagnostics, code_crawl, Bedrock, alerting, job_runner, FastAPI, dashboard), schema and PL/SQL, flow (poll → detect → diagnose → Bedrock → SNS). **Changes:** Oracle and app run on EC2 in production; config (DB host, SNS ARN, credentials) points to production resources; optional use of SSM, CloudWatch, ALB for HTTPS/domain.

---

## 6. Summary

- **Production diagram:** Oracle on EC2, App (Python + FastAPI + monitor) on EC2, Bedrock for RCA, SNS for two-stage alerts. Same logical flow as dev; placement and cost justification made explicit.
- **Cost:** Only EC2 (app instance), Bedrock (per use), SNS (per message); no extra services without a clear need.
- **Dev → production:** Same code and features; only deployment target (EC2) and config (DB host, SNS ARN, credentials) change. Use the production diagram prompt in section 2 for your slide; use sections 4 and 5 for likely questions and answers.
