# SQLcl Setup (Done)

SQLcl **25.4.2** is installed inside this project.

## Location
- **Directory:** `hacathon/sqlcl/`
- **Executable:** `hacathon/sqlcl/bin/sql`

## Requirements
- **Java 17** must be in your PATH. If you get "Unable to locate a Java Runtime", run:
  ```bash
  source ~/.zshrc
  ```
  (You added OpenJDK 17 to PATH earlier.)

## How to run SQLcl

**Option 1 – Wrapper script (easiest):**
```bash
cd /Users/neha/Desktop/hacathon
chmod +x run_sqlcl.sh
./run_sqlcl.sh -version
```

**Option 2 – Full path:**
```bash
export PATH="/opt/homebrew/opt/openjdk@17/bin:$PATH"
/Users/neha/Desktop/hacathon/sqlcl/bin/sql -version
```

**Connect to Oracle (after Phase 2 – when DB is running):**
```bash
./run_sqlcl.sh creditplus/CreditPlus123@localhost:1521/freepdb1
```

Then save the connection for reuse:
```sql
conn -save creditplus_local -savepwd creditplus/CreditPlus123@localhost:1521/freepdb1
```

## MCP server (Phase 7 – optional)
To start the Oracle MCP server:
```bash
./run_sqlcl.sh -mcp
```
