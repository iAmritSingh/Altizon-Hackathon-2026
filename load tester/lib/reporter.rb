# frozen_string_literal: true

require "json"

module LoadTester
  module Reporter
    module_function

    # Default "what should be expected" SLO targets. p95 default mirrors the
    # PerformanceIQ HIGH-severity threshold (>1000ms). Override via CLI flags.
    EXPECTED_DEFAULTS = { p95_ms: 1000.0, error_rate_pct: 1.0, min_rps: nil }.freeze

    # Possible solutions, as STEPS ONLY, emitted when a metric is over expected.
    # Tuned for MInt's Mongo-aggregation-heavy functions.
    REMEDIATION = {
      p95_ms: [
        "Capture the slow aggregation's explain plan; check for COLLSCAN and docs_examined >> docs_returned.",
        "Add/verify an index on the $match fields, ordered Equality -> Sort -> Range (ESR).",
        "Move $match before $lookup/$unwind so the working set shrinks before the join.",
        "Remove post-$unwind filtering that causes Cartesian expansion (high scan_ratio).",
        "Bound the query window / add date partitioning instead of scanning all history.",
        "$project only the fields needed before $group to cut document size.",
        "Re-run this load test and confirm p95 is back under the target."
      ],
      error_rate_pct: [
        "Inspect the failed responses (status code + body) emitted during the run.",
        "Check the server logs and timeouts for the function over the test window.",
        "Drop concurrency or add an --rps cap to locate the saturation point.",
        "Raise the client read timeout if failures are timeouts (driver read_timeout).",
        "Fix the surfaced error, redeploy, then re-run."
      ],
      min_rps: [
        "Raise concurrency (-c) until throughput plateaus to find the real ceiling.",
        "Confirm the server is not CPU- or connection-pool-bound at that plateau.",
        "Cut per-call latency (see the p95 steps) — throughput ≈ concurrency / latency.",
        "Re-run and confirm the target req/s is met."
      ]
    }.freeze

    # Build structured pass/fail checks of present vs expected.
    def evaluate(summary, expected: EXPECTED_DEFAULTS)
      checks = []
      p95 = summary[:latency_ms][:p95]
      checks << { metric: "p95 latency", key: :p95_ms, unit: "ms", direction: :over,
                  expected: "<= #{expected[:p95_ms]}", present: p95.to_f,
                  breached: p95.to_f > expected[:p95_ms].to_f }

      err = summary[:error_rate]
      checks << { metric: "error rate", key: :error_rate_pct, unit: "%", direction: :over,
                  expected: "<= #{expected[:error_rate_pct]}", present: err.to_f,
                  breached: err.to_f > expected[:error_rate_pct].to_f }

      if expected[:min_rps]
        rps = summary[:throughput_rps]
        checks << { metric: "throughput", key: :min_rps, unit: "req/s", direction: :under,
                    expected: ">= #{expected[:min_rps]}", present: rps.to_f,
                    breached: rps.to_f < expected[:min_rps].to_f }
      end
      checks
    end

    # Human-readable verdict: expected vs present, and remediation steps for any
    # metric that is over the expected target.
    def advisory(summary, expected: EXPECTED_DEFAULTS)
      checks = evaluate(summary, expected: expected)
      lines = []
      lines << "  verdict — expected vs present"
      lines << "  " + ("-" * 56)
      lines << format("  %-14s %-12s %-14s %s", "metric", "expected", "present", "status")
      checks.each do |c|
        status = c[:breached] ? "OVER  ✗" : "OK  ✓"
        lines << format("  %-14s %-12s %-14s %s",
                        c[:metric], c[:expected], format("%.2f %s", c[:present], c[:unit]), status)
      end

      breached = checks.select { |c| c[:breached] }
      if breached.empty?
        lines << ""
        lines << "  ✓ all metrics within expected — no action needed."
      else
        breached.each do |c|
          arrow, word = c[:direction] == :under ? ["↓", "below"] : ["↑", "above"]
          lines << ""
          lines << "  #{arrow} #{c[:metric]} is #{word} expected — possible solutions (steps):"
          REMEDIATION[c[:key]].each_with_index { |s, i| lines << format("    %d. %s", i + 1, s) }
        end
      end
      lines << ""
      lines.join("\n")
    end

    def console(summary, title:)
      l = summary[:latency_ms]
      lines = []
      lines << ""
      lines << "  #{title}"
      lines << "  " + ("=" * [title.length, 56].max)
      lines << format("  mode               %s (%d workers)", summary[:mode], summary[:concurrency])
      lines << format("  duration           %.2f s", summary[:wall_seconds])
      lines << format("  requests           %d  (ok %d / err %d)",
                      summary[:requests], summary[:success], summary[:errors])
      lines << format("  error rate         %.2f %%", summary[:error_rate])
      lines << format("  throughput         %.1f req/s", summary[:throughput_rps])
      lines << ""
      lines << "  latency (ms)"
      lines << format("    min   %9.2f      p90   %9.2f", l[:min], l[:p90])
      lines << format("    mean  %9.2f      p95   %9.2f", l[:mean], l[:p95])
      lines << format("    p50   %9.2f      p99   %9.2f", l[:p50], l[:p99])
      lines << format("    stdev %9.2f      max   %9.2f", l[:stddev], l[:max])
      lines << ""
      lines.join("\n")
    end

    def json(summary)
      JSON.pretty_generate(summary)
    end

    # Load-sweep table: one row per load level (e.g. 10 / 100 / 1000 calls).
    # rows: [{ level:, summary: }]. Adds a p95 status column vs expected.
    def sweep_console(rows, title:, expected: EXPECTED_DEFAULTS)
      lines = []
      lines << ""
      lines << "  #{title} — load sweep"
      lines << "  " + ("=" * [title.length + 13, 70].max)
      lines << format("  %-8s %-8s %-9s %-9s %-9s %-9s %-9s %-7s %s",
                      "level", "reqs", "dur(s)", "rps", "p50", "p95", "p99", "err%", "p95?")
      lines << "  " + ("-" * 78)
      rows.each do |r|
        s = r[:summary]
        l = s[:latency_ms]
        over = l[:p95].to_f > expected[:p95_ms].to_f
        lines << format("  %-8s %-8d %-9.2f %-9.1f %-9.2f %-9.2f %-9.2f %-7.2f %s",
                        r[:level], s[:requests], s[:wall_seconds], s[:throughput_rps],
                        l[:p50], l[:p95], l[:p99], s[:error_rate], over ? "OVER ✗" : "OK ✓")
      end
      lines << ""
      lines.join("\n")
    end

    # Before/after effectiveness: how much a change moved the numbers.
    # before/after are each [{ level:, summary: }]; rows are matched by level.
    def compare_console(before, after, title: "before vs after")
      by_level = ->(rows) { rows.each_with_object({}) { |r, h| h[r[:level].to_s] = r[:summary] } }
      b = by_level.call(before)
      a = by_level.call(after)
      levels = (a.keys & b.keys)
      levels = a.keys if levels.empty? # fall back to after's levels if labels differ

      lines = []
      lines << ""
      lines << "  #{title} — effectiveness"
      lines << "  " + ("=" * [title.length + 16, 72].max)
      lines << format("  %-8s %-11s %-11s %-11s %-16s %s",
                      "level", "p95 before", "p95 after", "Δ p95(ms)", "effect", "rps before→after")
      lines << "  " + ("-" * 78)

      deltas = []
      levels.each do |lvl|
        bs = b[lvl]
        as = a[lvl]
        next unless bs && as

        bp = bs[:latency_ms][:p95].to_f
        ap = as[:latency_ms][:p95].to_f
        d  = ap - bp
        pct = bp.zero? ? 0.0 : (bp - ap) / bp * 100.0 # positive = faster
        deltas << pct
        effect = pct.abs < 0.05 ? "~no change" : format("%.1f%% %s", pct.abs, pct.positive? ? "faster" : "slower")
        lines << format("  %-8s %-11.2f %-11.2f %-+11.2f %-16s %.1f → %.1f",
                        lvl, bp, ap, d, effect, bs[:throughput_rps].to_f, as[:throughput_rps].to_f)
      end

      unless deltas.empty?
        avg = deltas.sum / deltas.length
        verdict = avg.abs < 0.05 ? "no measurable change" : format("%.1f%% %s overall (mean of levels)", avg.abs, avg.positive? ? "faster" : "slower")
        lines << ""
        lines << "  ⇒ #{verdict}"
      end
      lines << ""
      lines.join("\n")
    end

    # Normalize a loaded JSON summary file into compare rows [{level:, summary:}].
    # Accepts either a single-run summary or a sweep file ({ sweep: [...] }).
    def to_compare_rows(parsed)
      if parsed[:sweep]
        parsed[:sweep].map { |r| { level: r[:level], summary: r[:summary] } }
      else
        [{ level: parsed[:requests], summary: parsed }]
      end
    end

    # Compare two summaries (e.g. baseline vs candidate) for a PR gate.
    def regression?(baseline, candidate, pct_threshold:, abs_ms_threshold:)
      base = baseline[:latency_ms][:p95]
      cand = candidate[:latency_ms][:p95]
      delta = cand - base
      pct = base.zero? ? 0.0 : (delta / base * 100)
      regressed = pct > pct_threshold && delta > abs_ms_threshold
      { regressed: regressed, baseline_p95: base, candidate_p95: cand,
        delta_ms: delta.round(3), delta_pct: pct.round(2) }
    end
  end
end
