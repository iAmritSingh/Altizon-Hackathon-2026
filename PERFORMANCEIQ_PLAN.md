# PerformanceIQ — Implementation Plan

> Automated Performance Intelligence System for Altizon DFX Platform

---

## The Problem

DFX has no proactive performance detection. Regressions surface only when customers escalate,
forcing engineers into reactive debugging. Today we have no system that tells us:
- Which part of the platform is slowing down and by how much
- Why it is slow — what the underlying cause is
- Which recent change introduced the regression

**Live evidence from ELK (last 24h):**

| Collection | Slow ops | Avg latency | Max latency | Avg docs examined |
|---|---|---|---|---|
| faas_data | 43,533 | 411ms | 101,739ms | 132,544 |
| generic_events | 39,467 | 710ms | 164,829ms | 22,658 |
| generic_objects | 12,878 | 1,209ms | 7,342ms | 763,436 |
| inspection_policy_bookings | — | — | **189,310ms** | 110,463,790 |

---

## The Solution — Four Integrated Layers

```
[Every PR to mint-content]
  → Track 1: Performance Gate
      → benchmark changed functions vs baseline
      → FAIL: block merge + post before/after comment
      → PASS: update baseline on merge

[1am UTC daily]
  → Track 2: Overnight Audit (standalone service)
      → query ELK for top slow queries (last 24h)
      → Track 3: RCA Engine
          → rule-based classification + Claude AI analysis
          → plain-English root cause + fix suggestion
      → email digest + Slack alert
      → Track 4: Auto-PR Bot
          → raise fix PR in factory repo (for each actionable finding)
          → PR includes: issue summary, RCA, index command, before/after metrics
```

---

## Team Split

| Person | Track | Estimated time |
|---|---|---|
| Person A | Track 1 — PR Performance Gate | 2h |
| Person B | Track 2 + 3 — Audit Service + RCA Engine | 4h |
| Person C | Track 4 — Auto-PR Bot | 2h |

---

## Track 1 — PR Performance Gate

**Repo:** `mint-content` | **Owner:** Person A

### How it works

GitHub Actions triggers on every PR to master. Detects changed `.rb` function files, loads each
via the existing factory CI runner, calls `.main()` 5 times with fixture data, and records the
median execution time. Compares against a baseline JSON file committed to the repo.

- **Block merge** if: median time is > 20% slower AND > 50ms absolute increase
- **Update baseline** automatically on merge to master
- **PR comment** shows a before/after timing table

### Files to create

```
mint-content/
├── .github/workflows/performance_gate.yml   # Trigger, discovery, benchmark, comment
├── scripts/benchmark_runner.rb              # Runs .main() N times, returns median + p95
└── .performance/baselines.json             # Committed baseline store per function
```

### Key decisions

- **Baseline storage:** JSON committed to repo — no external deps, git history = audit trail
- **Threshold:** 20% AND 50ms absolute — avoids false positives on sub-millisecond functions
- **Fixture data:** Reuse FactoryBot setup from each function's existing `_spec.rb`
- **Reuse:** diff detection logic from `mint-content/.github/workflows/ci.yml`

---

## Track 2 — Overnight Audit Service

**New service:** `performance_iq/` (standalone Ruby, no Rails/Sidekiq) | **Owner:** Person B

### Service structure

```
performance_iq/
├── Gemfile                          # httparty, octokit, net-http
├── runner.rb                        # Entry point — orchestrates all steps
├── lib/
│   ├── elk_client.rb                # ES queries against dfx-mongodb-logs-*
│   ├── rca_engine.rb                # Root cause classifier + Claude API
│   ├── notifier.rb                  # SendGrid email + Slack webhook
│   └── auto_pr.rb                   # GitHub PR via Octokit
├── config/
│   └── settings.yml.example         # Template for all secrets/thresholds
└── .github/workflows/
    └── performance_audit.yml        # Nightly cron: 0 2 * * * (2am IST)
```

### ELK query (confirmed working)

- **Endpoint:** `https://elasticsearch-dfx.datonis.io`
- **Auth:** ApiKey header
- **Index:** `dfx-mongodb-logs-*` (ES 8.12.0)
- **Available fields:** `@timestamp`, `collection`, `duration_ms`, `docs_examined`,
  `docs_returned`, `scan_ratio`, `plan_summary`, `query_hash`, `needs_index`,
  `license_key`, `query`

**Aggregation — top offenders by query shape:**
```json
{
  "size": 0,
  "query": {
    "bool": { "must": [
      { "range": { "@timestamp": { "gte": "now-24h" } } },
      { "range": { "duration_ms": { "gte": 100 } } }
    ]}
  },
  "aggs": {
    "by_query_hash": {
      "terms": { "field": "query_hash", "size": 20, "order": { "avg_duration": "desc" } },
      "aggs": {
        "avg_duration":   { "avg":         { "field": "duration_ms" } },
        "max_duration":   { "max":         { "field": "duration_ms" } },
        "avg_scan_ratio": { "avg":         { "field": "scan_ratio" } },
        "total_ops":      { "value_count": { "field": "query_hash" } },
        "collection":     { "terms":       { "field": "collection", "size": 1 } },
        "plan_summary":   { "terms":       { "field": "plan_summary", "size": 1 } },
        "needs_index":    { "terms":       { "field": "needs_index", "size": 1 } },
        "sample_query":   { "top_hits":    { "size": 1, "_source": ["query","collection"] } }
      }
    }
  }
}
```

### Severity classification

| Severity | Condition |
|---|---|
| CRITICAL | avg_duration_ms > 10,000 |
| HIGH | avg_duration_ms > 1,000 |
| MEDIUM | avg_duration_ms > 100 |

---

## Track 3 — RCA Engine

**File:** `performance_iq/lib/rca_engine.rb` | **Owner:** Person B

### Step 1 — Rule-based pre-classification (deterministic, instant)

| Condition | Root cause |
|---|---|
| `scan_ratio > 100,000` | Cartesian expansion — likely `$unwind` + post-filter |
| `scan_ratio > 1,000` | Poor index selectivity — index too broad |
| `needs_index == true` | Missing index — full collection scan |
| `plan_summary =~ /COLLSCAN/` | No index used at all |
| `collection == "faas_data" AND avg_ms > 1000` | Aggregation without date partitioning |

### Step 2 — Claude AI analysis (for HIGH + CRITICAL findings)

- **Model:** `claude-sonnet-4-6`
- **Endpoint:** `https://api.anthropic.com/v1/messages`
- **Prompt caching** on system prompt (reused across all findings — saves tokens)
- **Input:** collection name, avg_duration_ms, scan_ratio, plan_summary, sample pipeline stages
- **Output schema:**
  ```json
  {
    "root_cause": "string",
    "fix_description": "string",
    "index_suggestion": "db.collection.create_index(...) or null",
    "pipeline_rewrite": "rewritten pipeline or null"
  }
  ```

### Example output

```json
{
  "query_hash": "484C44D3",
  "collection": "generic_events",
  "avg_duration_ms": 27168,
  "scan_ratio": 8853,
  "root_cause": "Index exists on (license_key, type, generic_object_id, from, to) but the large date range causes high scan volume. The $lookup stage further multiplies examined docs.",
  "fix_description": "Add a more selective index including element_key to narrow the scan before $lookup.",
  "index_suggestion": "db.generic_events.create_index({ license_key: 1, type: 1, element_key: 1, from: -1 })",
  "pipeline_rewrite": null
}
```

### Notifications

**Email** (SendGrid — same API pattern as `FactoryMailer`):
```
Subject: [PerformanceIQ] Daily Audit — 2 critical, 5 high issues — 2026-05-29
Body: HTML table of top 10 findings with collection, avg_ms, root_cause, fix
```

**Slack** (webhook POST — same pattern as `SlackAlertsHelper`):
```
:rotating_light: PerformanceIQ Audit — 2026-05-29
Top offender: generic_events — avg 710ms, 39,467 slow ops in 24h
Root cause: Poor index selectivity on large date ranges
Fix: db.generic_events.create_index({ license_key: 1, type: 1, element_key: 1, from: -1 })
[+4 more findings in email report]
```

---

## Track 4 — Auto-PR Bot

**File:** `performance_iq/lib/auto_pr.rb` | **Owner:** Person C

### How it works

Called by `runner.rb` for every finding where `index_suggestion` is non-null. Uses **Octokit**
(already in `factory/Gemfile`, same gem reused here) to create a branch, commit a fix document,
and open a PR.

- **Branch naming:** `perf-fix/{collection}-index-{YYYYMMDD}`
- **Committed file:** `db/performance_fixes/YYYYMMDD_{collection}_index.md`
- **Reuses:** `factory/lib/utils/github_helper.rb` — `create_branch`, `commit`, `create_pull_request` all already implemented

### PR body template

```markdown
## Performance Issue Detected by PerformanceIQ

**Collection:** generic_events | **Avg query time:** 27,168ms | **Ops in 24h:** 50
**Query hash:** 484C44D3 | **Plan:** IXSCAN { license_key, type, generic_object_id, from, to }

## Root Cause
Poor index selectivity. Large date range causes high scan volume before $lookup multiplies docs.
Avg scan ratio: 8,853 (8,853 docs examined per 1 returned).

## Fix
Run in mongo shell against factory_production:
```
db.generic_events.create_index(
  { license_key: 1, type: 1, element_key: 1, from: -1 },
  { background: true, name: "perf_fix_ge_element_key" }
)
```

## Before / After (estimated)
| Metric          | Before     | After      |
|-----------------|------------|------------|
| Avg query time  | 27,168ms   | ~200ms     |
| Scan ratio      | 8,853      | ~1         |
| Ops/day blocked | 50         | 0          |

🤖 Auto-generated by PerformanceIQ — review before applying to production
```

---

## config/settings.yml.example

```yaml
elasticsearch:
  host: https://elasticsearch-dfx.datonis.io
  api_key: "<ES_API_KEY>"
  index: dfx-mongodb-logs-*

thresholds:
  min_duration_ms: 100
  critical_duration_ms: 10000
  high_duration_ms: 1000
  top_n: 20

anthropic:
  api_key: "<ANTHROPIC_API_KEY>"
  model: claude-sonnet-4-6

notifications:
  sendgrid_api_key: "<SENDGRID_API_KEY>"
  from_email: datonis@altizon.com
  to_emails:
    - app_dev@altizon.com
  slack_webhook_url: "<SLACK_WEBHOOK_URL>"

github:
  access_token: "<GITHUB_PAT>"
  factory_repo: Altizon/factory
```

---

## What We Reuse (Zero New Infrastructure)

| Component | Reused from |
|---|---|
| ELK slow query data | Already shipping from all services |
| Octokit GitHub API | `factory/lib/utils/github_helper.rb` |
| Slack alerts | `factory/lib/utils/slack_alerts_helper.rb` pattern |
| SendGrid email | `factory/app/mailers/factory_mailer.rb` pattern |
| Function CI runner | `mint-content/.github/workflows/ci.yml` diff detection |
| mongo-query-optimizer | `mongo-query-optimizer/mongo_query_optimizer.py` (reuse detection logic) |
| Automated PR review | `mint-content/.github/workflows/claude-review.yml` picks up Auto-PRs |

---

## Expected Business Impact

| Metric | Today | With PerformanceIQ |
|---|---|---|
| Performance regressions reaching production | No gate | Blocked before merge |
| Time to detect an existing issue | Days to weeks | Next morning |
| Time to diagnose root cause | Hours of manual effort | Automated overnight |
| Fix turnaround | Unpredictable | Fix proposal ready by morning |
| Engineering effort per incident | Debug from scratch | Review and approve |
| Customer-reported perf issues | Reactive | Largely preventable |

---

## Build Order (Hackathon Day)

| Step | File | Time | Unblocks |
|---|---|---|---|
| 1 | `elk_client.rb` | 30 min | Everything |
| 2 | `runner.rb` + `notifier.rb` | 1h | Track 2 demo |
| 3 | `rca_engine.rb` (rules + Claude) | 1.5h | Track 3 demo |
| 4 | `auto_pr.rb` | 1h | Track 4 demo |
| 5 | `performance_gate.yml` + `benchmark_runner.rb` | 2h (parallel) | Track 1 demo |

---

## Verification

| Track | How to demo |
|---|---|
| 1 — PR Gate | Open PR in mint-content with `sleep(0.5)` injected into a function → gate fails + posts timing table |
| 2 — Audit | Run `DRY_RUN=true ruby runner.rb` → prints live findings from ELK, no notifications sent |
| 3 — RCA | Run `ruby runner.rb` → Slack + email received with real root causes from live ELK data |
| 4 — Auto-PR | Run `ruby runner.rb` → PR appears in factory repo with index command and before/after table |
