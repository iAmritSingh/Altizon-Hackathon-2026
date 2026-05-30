## 🔎 PerformanceIQ — Load-test gate

Load: 8 concurrent × 8s per version, master vs PR on the same runner.

✅ **PASS** — no p95 regression under load.

### Latency & throughput (master → PR)

| Function | p50 | p95 | p99 | Throughput | Errors | Verdict |
|----------|-----|-----|-----|------------|-------:|---------|
| `workorder_opn_aggregation_etl_v1` | 26.7ms → **26.74ms** (+0% ) | 34.1ms → **34.11ms** (+0% ) | 41.78ms → **41.58ms** (+0% ) | 295.3/s → **293.5/s** (-1% 🔺) | 0 (0.0%) | ✅ |

<details><summary>Full latency distribution (ms)</summary>

| Function | Version | requests | min | mean | p90 | max | stddev |
|----------|---------|---------:|----:|-----:|----:|----:|-------:|
| `workorder_opn_aggregation_etl_v1` | master | 2362 | 4.42 | 27.11 | 30.87 | 114.15 | 4.76 |
| `workorder_opn_aggregation_etl_v1` | PR | 2348 | 8.09 | 27.25 | 31.05 | 93.41 | 4.69 |
</details>

_Real load against a prod-scale seeded Mongo. Same-runner A/B, so CI hardware noise cancels._