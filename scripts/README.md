# Scripts

- **phase2_setup.sql** – Phase 2 one-shot setup: creates `BatchLog` and `ReportLog`, inserts dummy data (normal + long-running + failed).  
  Run once when the Oracle container is ready:
  ```bash
  cd /Users/neha/Desktop/hacathon
  ./run_sqlcl.sh -S creditplus/CreditPlus123@localhost:1521/freepdb1 @scripts/phase2_setup.sql
  ```
  If you run it again, it will fail at `CREATE TABLE` (tables already exist). To re-run from scratch, drop the tables first in SQLcl or recreate the container.
