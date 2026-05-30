# MInt Function Load Tester

A dependency-free (Ruby stdlib only) load tester for MInt function `.main()`
invocations. Drives a function under concurrent load and reports **throughput**,
**latency percentiles** (p50/p90/p95/p99), and **error rate**.

## Why a driver?

MInt function files end with a self-invoking line and depend on platform globals
and models (`current_license_key`, `logger`, `context`, `GenericObject`,
`GenericObjectsCache`, `context.eval_function`, MongoDB). You can't just point
the tester at the `.rb` — it would execute against dependencies that don't exist
locally. Instead you write a tiny **driver** that stubs what the function touches
and hands the tester a clean callable.

## Quick start

```bash
cd load_tester
# Runs out-of-the-box against a synthetic function — no platform needed:
ruby load_test.rb --driver drivers/example_driver.rb -c 8 -n 3000
```

## Usage

```
ruby load_test.rb --driver FILE [options]

  --driver FILE        Driver defining build_target(worker_id)   (required)
  -c, --concurrency N  Concurrent workers                        (default 8)
  -n, --iterations N   Total calls to make
  -d, --duration SEC   Run for SEC seconds instead of fixed N
  -w, --warmup N       Warmup calls before measuring             (default 0)
      --rps N          Cap throughput at ~N req/s                (default: unlimited)
      --mode MODE      thread (default) | process                (see below)
      --json FILE      Also write the summary as JSON
      --title TEXT     Report title
      --expect-p95 MS          Expected p95 latency ceiling   (default 1000)
      --expect-error-rate PCT  Expected error-rate ceiling    (default 1.0)
      --expect-rps N           Expected min throughput        (default: none)
      --sweep LIST             Run at each load level, e.g. 10,100,1000
      --compare FILE           Diff current run vs a saved --json baseline
```

Set **either** `-n` (fixed call count) **or** `-d` (time-boxed) **or** `--sweep`.

## Load sweep — scaling profile (10 / 100 / 1000 …)

`--sweep` runs the target at several load levels in one shot and tabulates how
time/latency/throughput scale:

```
ruby load_test.rb --driver drivers/http_function_driver.rb -c 8 \
  --sweep 10,100,1000 --warmup 5 --json before.json

  bqi_index_report — load sweep
  level    reqs     dur(s)    rps       p50       p95       p99       err%    p95?
  ------------------------------------------------------------------------------
  10       10       0.26      38.3      132.50    138.87    138.87    0.00    OK ✓
  100      100      1.65      60.5      128.01    139.94    140.47    0.00    OK ✓
  1000     1000     15.86     63.1      126.54    139.71    140.88    0.00    OK ✓
```

Each `LIST` value is a total call count. With `--json`, the file holds a
`{ "sweep": [ { "level":…, "summary":… } … ] }` structure.

## Before vs after — how effective was the change?

Save a baseline with `--json`, make your change, then re-run with `--compare`:

```
# baseline (before the fix)
ruby load_test.rb --driver drivers/http_function_driver.rb -c 8 --sweep 10,100,1000 --json before.json
# after the fix
ruby load_test.rb --driver drivers/http_function_driver.rb -c 8 --sweep 10,100,1000 --compare before.json

  before.json → current — effectiveness
  level    p95 before  p95 after   Δ p95(ms)   effect           rps before→after
  ------------------------------------------------------------------------------
  10       138.87      17.95       -120.92     87.1% faster     38.3 → 241.5
  100      139.94      20.56       -119.38     85.3% faster     60.5 → 430.7
  1000     139.71      20.63       -119.08     85.2% faster     63.1 → 465.2

  ⇒ 85.9% faster overall (mean of levels)
```

`--compare` matches rows by level and reports the p95 delta, the percentage
effect (positive = faster), and the throughput change. It works with both
sweep baselines and single-run baselines.

## Verdict — expected vs present (+ remediation steps)

After every run the report prints a **verdict** table comparing each metric
against its expected target, then — for any metric that's out of bounds — prints
**possible solutions as steps only**:

```
  verdict — expected vs present
  --------------------------------------------------------
  metric         expected     present        status
  p95 latency    <= 1000.0    30.17 ms       OVER  ✗
  error rate     <= 1.0       0.00 %         OK  ✓
  throughput     >= 200.0     361.55 req/s   OK  ✓

  ↑ p95 latency is above expected — possible solutions (steps):
    1. Capture the slow aggregation's explain plan; check for COLLSCAN ...
    2. Add/verify an index on the $match fields, ordered Equality -> Sort -> Range (ESR).
    ...
```

Targets default to the PerformanceIQ thresholds (p95 ≤ 1000 ms, errors ≤ 1%,
throughput unchecked) and are overridable per run with the `--expect-*` flags.
When `--json` is set, the file also gains `expected` and `verdict` blocks for
programmatic gating. The remediation steps are tuned for MInt's Mongo-heavy
aggregation functions.

## thread vs process mode — read this

Ruby has a GIL: **threads only give true parallelism for I/O-bound work**
(MongoDB / HTTP). MInt functions that do pure-Ruby aggregation math are
CPU-bound, so under `--mode thread` the GIL serialises them and the tail latency
balloons (GC + lock contention). For honest CPU-bound load use `--mode process`,
which `fork`s real worker processes.

Observed on the bundled example (`-c 8 -n 2000`):

| mode    | throughput  | p99     | max     |
|---------|-------------|---------|---------|
| thread  | ~1,100 rps  | ~1.5 ms | ~700 ms |
| process | ~7,500 rps  | ~1.3 ms | ~2.4 ms |

Rule of thumb: **I/O-bound function → thread; CPU-bound function → process.**

## Writing a driver for a real function

1. Copy `drivers/mint_function_driver.rb.example` to `drivers/<fn>_driver.rb`.
2. Stub the platform surface your function calls (see `stubs/mint_platform.rb`
   for the ActiveSupport-ish shims — `present?`, `blank?`, `try`, `.utc`,
   `beginning_of_day` — already provided).
3. Strip the function file's self-invoke tail and `eval` the class definition.
4. Implement `build_target(worker_id)` to return `-> { Klass.new(...).main(args) }`.

`build_target` is called **once per worker**, so do per-worker setup (fixtures,
connections) there; the returned lambda is what gets timed each iteration.

## Files

```
load_tester/
├── load_test.rb              # CLI entry point
├── lib/
│   ├── engine.rb             # thread pool + fork pool, pacing, warmup
│   ├── stats.rb              # percentiles, throughput, error rate
│   ├── reporter.rb           # console table, JSON, regression compare
│   └── target_loader.rb      # loads a driver's build_target
├── stubs/
│   └── mint_platform.rb      # ActiveSupport shims + logger/context stubs
└── drivers/
    ├── example_driver.rb              # runnable synthetic function
    └── mint_function_driver.rb.example # template for a real function
```

## CI / PR-gate use

`Reporter.regression?(baseline, candidate, pct_threshold:, abs_ms_threshold:)`
compares two summaries on p95 and flags a regression when p95 is both >X% **and**
>Y ms slower — matching the PerformanceIQ Track 1 gate policy. The CLI exits
non-zero if every call errored, so a broken function fails the build.
```
