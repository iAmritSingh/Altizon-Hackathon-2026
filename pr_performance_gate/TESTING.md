# Testing the Performance Gate

Three tiers, from zero-setup to full CI.

## 1. Static pipeline-shape gate — works now, no infra
Compares a function's pipeline shape (PR vs base branch); blocks on added `$lookup`/`$unwind`,
dropped `$match`, or removed `license_key`. Run it against any repo with FaaS functions:

```bash
cd /path/to/mint-content
GATE=/path/to/pr_performance_gate/scripts/static_gate.rb

# clean change -> PASS (exit 0)
ruby "$GATE" --functions "iprod/functions/default/cbm_trend.rb" --base HEAD

# simulate a bad PR, then re-run -> FAIL (exit 1)
#   (add a $lookup / delete a "license_key" => ... line in the function, save, then:)
ruby "$GATE" --functions "iprod/functions/default/cbm_trend.rb" --base HEAD
git checkout -- iprod/functions/default/cbm_trend.rb   # restore
```

## 2. Load test locally — needs Docker/mongod (self-contained demo, no factory)
Uses the bundled stub runtime (`test/bootstrap_local.rb`) + demo good/bad functions, so you can
see the load gate catch a regression without the factory stack.

```bash
cd pr_performance_gate

# start a throwaway mongo
mkdir -p /tmp/pgdb && mongod --dbpath /tmp/pgdb --port 27018 --fork --logpath /tmp/pgmongo.log
export PERF_GATE_MONGO_URL="mongodb://127.0.0.1:27018/perf_gate"
export PERF_GATE_BOOTSTRAP="test/bootstrap_local.rb"

# seed prod-scale dummy data + prod indexes
ruby scripts/seed_dummy_data.rb --mongo-url "$PERF_GATE_MONGO_URL" \
  --indexes .performance/indexes.json --spec test/seed_spec.demo.json

# load-test the GOOD vs BAD demo function (8 concurrent x 5s)
ruby scripts/load_probe.rb test/functions_good/demo_report.rb test/fixtures/demo_report.json 8 5
ruby scripts/load_probe.rb test/functions_bad/demo_report.rb  test/fixtures/demo_report.json 8 5

# teardown
kill $(pgrep -f "mongod --dbpath /tmp/pgdb"); rm -rf /tmp/pgdb /tmp/pgmongo.log
```

Observed (local, 50k docs): GOOD ≈ 714 req/s @ p95 14.9ms; BAD (dropped filter) ≈ 124 req/s @
p95 86.4ms — a +480% p95 jump → the gate's `regressed?` (p95 > 20% AND > 50ms) flags it ❌.

## 3. Full CI on a real PR
1. Copy `scripts/`, `.performance/`, and `.github/workflows/performance_gate.yml` into mint-content.
2. Set repo **var** `PERF_GATE_BOOTSTRAP` (factory runtime loader) + **secret** `GH_PAT`.
3. Fill `.performance/seed_spec.json` `fixture_values` + add `.performance/fixtures/<fn>.json`
   for the functions you want load-tested.
4. Open a PR that worsens a function (e.g. widen a date range, drop a filter). The `pipeline-shape`
   job comments + blocks on structural regressions immediately; the `load-test` job (when
   `PERF_GATE_BOOTSTRAP` is set) seeds a CI mongo, load-tests master vs PR, and blocks on p95.
