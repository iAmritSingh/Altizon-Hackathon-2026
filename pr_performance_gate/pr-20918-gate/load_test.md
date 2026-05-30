## 🔎 PerformanceIQ — Load-test gate

Load: 8 concurrent × 15s per version, master vs PR on the same runner.

✅ **PASS** — no p95 regression under load.

### Latency & throughput (master → PR)

| Function | p50 | p95 | p99 | Throughput | Errors | Verdict |
|----------|-----|-----|-----|------------|-------:|---------|
| `workorder_opn_aggregation_etl_v1` | 23.47ms → **23.44ms** (+0% ) | 27.28ms → **30.64ms** (+12% 🔺) | 35.56ms → **36.61ms** (+3% 🔺) | 334.6/s → **341.3/s** (+2% 🔻) | 0 (0.0%) | ✅ |

<details><summary>Full latency distribution (ms)</summary>

| Function | Version | requests | min | mean | p90 | max | stddev |
|----------|---------|---------:|----:|-----:|----:|----:|-------:|
| `workorder_opn_aggregation_etl_v1` | master | 5019 | 10.42 | 23.91 | 25.59 | 140.13 | 3.38 |
| `workorder_opn_aggregation_etl_v1` | PR | 5120 | 3.87 | 23.44 | 25.79 | 76.68 | 4.07 |
</details>

_Real load against a prod-scale seeded Mongo. Same-runner A/B, so CI hardware noise cancels._