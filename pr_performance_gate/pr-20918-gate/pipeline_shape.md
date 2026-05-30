## 🔎 PerformanceIQ — Performance Gate (pipeline shape)

✅ **PASS** — no structural regression.

| Function | $lookup | $unwind | $facet | $match | Verdict |
|----------|--------:|--------:|-------:|-------:|---------|
| `workorder_opn_aggregation_etl_v1` | 0 | 11 | 0 | 12→**13** | ✅ |

_Compares pipeline shape vs the base branch — data-volume independent (staging data size does not affect it)._