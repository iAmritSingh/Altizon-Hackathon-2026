# frozen_string_literal: true

# Pure-stdlib latency statistics. All inputs/outputs are in milliseconds.
module LoadTester
  module Stats
    module_function

    # Nearest-rank percentile (the convention used by wrk/k6/hey).
    # samples must be a non-empty Array of Numerics; not required to be sorted.
    def percentile(sorted, pct)
      return 0.0 if sorted.empty?
      rank = (pct / 100.0 * sorted.length).ceil
      rank = 1 if rank < 1
      rank = sorted.length if rank > sorted.length
      sorted[rank - 1].to_f
    end

    def mean(samples)
      return 0.0 if samples.empty?
      samples.sum.to_f / samples.length
    end

    def stddev(samples)
      return 0.0 if samples.length < 2
      m = mean(samples)
      var = samples.sum(0.0) { |x| (x - m)**2 } / (samples.length - 1)
      Math.sqrt(var)
    end

    # Build the full summary block from raw latency samples (ms) and run metadata.
    def summarize(latencies_ms:, errors:, wall_seconds:, concurrency:, mode:)
      sorted = latencies_ms.sort
      total = latencies_ms.length + errors
      {
        mode: mode,
        concurrency: concurrency,
        requests: total,
        success: latencies_ms.length,
        errors: errors,
        error_rate: total.zero? ? 0.0 : (errors.to_f / total * 100),
        wall_seconds: wall_seconds,
        throughput_rps: wall_seconds.zero? ? 0.0 : (latencies_ms.length / wall_seconds),
        latency_ms: {
          min: sorted.first.to_f || 0.0,
          mean: mean(sorted).round(3),
          stddev: stddev(sorted).round(3),
          p50: percentile(sorted, 50).round(3),
          p90: percentile(sorted, 90).round(3),
          p95: percentile(sorted, 95).round(3),
          p99: percentile(sorted, 99).round(3),
          max: sorted.last.to_f || 0.0
        }
      }
    end
  end
end
