## 🔎 PerformanceIQ — Performance Gate (pipeline shape)

✅ **PASS** — no structural regression.

| Function | $lookup | $unwind | $facet | $match | Verdict |
|----------|--------:|--------:|-------:|-------:|---------|
| `bqi_index_report` | 3 | 3 | 2 | 6→**8** | ✅ |

_Compares pipeline shape vs the base branch — data-volume independent (staging data size does not affect it)._