#!/bin/bash
# Run SQLcl with Java 17 and project SQLcl. Usage:
#   ./run_sqlcl.sh
#   ./run_sqlcl.sh creditplus/CreditPlus123@localhost:1521/freepdb1
#   ./run_sqlcl.sh -version

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="/opt/homebrew/opt/openjdk@17/bin:$PATH"
exec "$SCRIPT_DIR/sqlcl/bin/sql" "$@"
