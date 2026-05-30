#!/usr/bin/env bash
# One-shot local demo of the load-test gate: starts a throwaway mongod, seeds prod-scale dummy
# data + prod indexes, then load-tests the GOOD vs BAD demo function and prints the comparison.
# No factory/Mongoid needed — uses the bundled stub runtime (test/bootstrap_local.rb).
#
#   bash test/local_demo.sh            # default 8 concurrent x 5s
#   CONC=16 DUR=8 bash test/local_demo.sh
set -euo pipefail
cd "$(dirname "$0")/.."

PORT=27018
DBPATH=/tmp/pgdb_demo
LOG=/tmp/pgmongo_demo.log
export PERF_GATE_MONGO_URL="mongodb://127.0.0.1:${PORT}/perf_gate"
export PERF_GATE_BOOTSTRAP="test/bootstrap_local.rb"
CONC="${CONC:-8}"; DUR="${DUR:-5}"

cleanup() {
  kill "$(pgrep -f "mongod --dbpath ${DBPATH}")" 2>/dev/null || true
  sleep 1; rm -rf "$DBPATH" "$LOG"
}
trap cleanup EXIT

echo "==> starting mongod on :${PORT}"
mkdir -p "$DBPATH"
mongod --dbpath "$DBPATH" --port "$PORT" --bind_ip 127.0.0.1 --fork --logpath "$LOG" >/dev/null
for _ in $(seq 1 20); do
  ruby -e 'require "mongo"; Mongo::Logger.logger.level=Logger::FATAL; Mongo::Client.new(ENV["PERF_GATE_MONGO_URL"]).database.command(ping:1)' 2>/dev/null && break
  sleep 0.5
done

echo "==> seeding dummy data + prod indexes"
ruby scripts/seed_dummy_data.rb --mongo-url "$PERF_GATE_MONGO_URL" \
  --indexes .performance/indexes.json --spec test/seed_spec.demo.json

echo "==> load-testing (${CONC} concurrent x ${DUR}s each)"
echo -n "GOOD (selective filter):  "; ruby scripts/load_probe.rb test/functions_good/demo_report.rb test/fixtures/demo_report.json "$CONC" "$DUR" 2>/dev/null
echo -n "BAD  (dropped filter):    "; ruby scripts/load_probe.rb test/functions_bad/demo_report.rb  test/fixtures/demo_report.json "$CONC" "$DUR" 2>/dev/null
echo "==> done (a higher p95 / lower throughput on BAD = the gate would FAIL the PR)"
