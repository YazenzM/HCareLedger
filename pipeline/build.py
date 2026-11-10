"""Build the HCareLedger warehouse: run every SQL file under sql/ in path order against DuckDB.

Usage:
  .venv\\Scripts\\python.exe -I pipeline\\build.py              # full rebuild
  .venv\\Scripts\\python.exe -I pipeline\\build.py 30 40        # only steps whose folder starts with 30 or 40

Each SQL file may contain several statements. `{{raw_dir}}` and `{{out_dir}}` are substituted
with absolute POSIX paths so the SQL stays portable.
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parents[1]
DB_PATH = ROOT / "data" / "hcareledger.duckdb"
SQL_DIR = ROOT / "sql"
SUBS = {
    "{{raw_dir}}": (ROOT / "data" / "raw").as_posix(),
    "{{out_dir}}": (ROOT / "outputs").as_posix(),
}


def render(sql: str) -> str:
    for k, v in SUBS.items():
        sql = sql.replace(k, v)
    return sql


def report_tests(con: duckdb.DuckDBPyConnection) -> int:
    """Print the test summary; return the number of failing error-severity tests."""
    rows = con.execute(
        "select status, severity, model, column_name, rows_failing, pct_failing, description "
        "from audit.test_results where status <> 'pass' order by severity, pct_failing desc"
    ).fetchall()
    total, passed = con.execute("select count(*), count(*) filter (where status = 'pass') from audit.test_results").fetchone()
    print(f"\ntests: {passed}/{total} pass")
    for status, sev, model, col, n, pct, desc in rows:
        print(f"  {status:4s} {model}.{col}: {n:,} rows ({pct}%) - {desc}")
    return sum(1 for r in rows if r[0] == "FAIL")


def main(prefixes: list[str]) -> None:
    for sub in ("powerbi", "reports", "quality"):
        (ROOT / "outputs" / sub).mkdir(parents=True, exist_ok=True)
    files = sorted(SQL_DIR.rglob("*.sql"))
    if prefixes:
        files = [f for f in files if any(f.relative_to(SQL_DIR).parts[0].startswith(p) for p in prefixes)]
    con = duckdb.connect(str(DB_PATH))
    t_all = time.perf_counter()
    for f in files:
        t = time.perf_counter()
        try:
            con.execute(render(f.read_text(encoding="utf-8")))
        except duckdb.Error as e:
            print(f"FAILED  {f.relative_to(ROOT)}\n  {e}")
            sys.exit(1)
        print(f"ok  {time.perf_counter() - t:6.1f}s  {f.relative_to(ROOT)}")
    failures = 0
    if any(f.relative_to(SQL_DIR).parts[0].startswith("50") for f in files):
        failures = report_tests(con)
    con.close()
    print(f"done in {time.perf_counter() - t_all:.1f}s -> {DB_PATH.relative_to(ROOT)}")
    if failures:
        print(f"{failures} error-severity test(s) failed")
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv[1:])
