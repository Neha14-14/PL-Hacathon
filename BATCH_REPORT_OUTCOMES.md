# Batch & Report Outcomes (Expected = avg + 10%)

Monitor flags a job as **long-running** when elapsed > expected (avg + 10%).  
Monitor flags a job as **failed** when status = FAILED.

---

## Batches

| Batch                    | Avg (s) | Expected (avg+10%) | Actual run (s) | Outcome          | RCA? |
|--------------------------|---------|---------------------|-----------------|------------------|------|
| RECONCILIATION_BATCH     | 60      | 66                  | ~90             | **Long-running** | Yes  |
| FRAUD_CHECK_BATCH        | 40      | 44                  | ~60             | **Long-running** | Yes  |
| DAILY_SETTLEMENT         | 3       | 4                   | ~3              | Completes        | No   |
| EOD_BALANCE_BATCH        | 3       | 4                   | ~3              | Completes        | No   |

## Reports

| Report                | Avg (s) | Expected (avg+10%) | Actual run (s)     | Outcome          | RCA? |
|-----------------------|---------|---------------------|--------------------|------------------|------|
| REGULATORY_EXPORT     | 15      | 17                  | Fails before 17s   | **Failed**       | Yes  |
| MERCHANT_REPORT       | 30      | 33                  | ~45                | **Long-running** | Yes  |
| TXN_SYNC              | 3       | 4                   | ~3                 | Completes        | No   |
| DAILY_SUMMARY         | 3       | 4                   | ~3                 | Completes        | No   |

## Manual Fail (operator)

If you click **Fail** on a running job:
- Job is marked FAILED with cancel_requested = 1.
- **No** alert and **no** RCA is triggered.
