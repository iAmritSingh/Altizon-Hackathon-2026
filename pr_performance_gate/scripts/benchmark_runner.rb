#!/usr/bin/env ruby
# Track 1 — Benchmark Runner
# Loads each changed mint-content function, runs .main() N times, compares to baseline.
#
# Usage:
#   ruby benchmark_runner.rb \
#     --functions "iprod/functions/default/my_function.rb" \
#     --baseline  .performance/baselines.json \
#     --threshold-pct 20 \
#     --threshold-ms  50
#
# Exit codes:
#   0 — all functions within threshold (or no baseline yet — stored as new baseline)
#   1 — one or more functions regressed beyond threshold

require 'optparse'
require 'json'
require 'benchmark'

RUNS = 5  # number of benchmark runs per function (takes median)

options = {
  functions:      [],
  baseline_path:  '.performance/baselines.json',
  threshold_pct:  20,
  threshold_ms:   50
}

OptionParser.new do |o|
  o.on('--functions FILES', 'Space-separated list of changed function files') { |v| options[:functions] = v.split }
  o.on('--baseline PATH',   'Path to baselines JSON')  { |v| options[:baseline_path] = v }
  o.on('--threshold-pct N', Integer, 'Regression % threshold') { |v| options[:threshold_pct] = v }
  o.on('--threshold-ms N',  Integer, 'Absolute ms threshold')  { |v| options[:threshold_ms]  = v }
end.parse!

baselines = File.exist?(options[:baseline_path]) ? JSON.parse(File.read(options[:baseline_path])) : {}
regressions = []
new_baselines = baselines.dup

options[:functions].each do |fn_path|
  fn_name = File.basename(fn_path, '.rb')
  puts "\nBenchmarking: #{fn_name}"

  # TODO: load function via factory CI runner (same as mint-content/ci.yml)
  # Pseudocode:
  #   require factory CI runner
  #   fn_class = load_function(fn_path)
  #   times = RUNS.times.map { Benchmark.realtime { fn_class.main(context, license_key, args) } * 1000 }
  #   median_ms = times.sort[times.length / 2].round(1)
  times = Array.new(RUNS) { rand(50..200).to_f }  # STUB — replace with real execution
  median_ms = times.sort[times.length / 2].round(1)

  baseline_ms = baselines[fn_name]
  new_baselines[fn_name] = median_ms

  if baseline_ms.nil?
    puts "  No baseline — storing #{median_ms}ms as first baseline"
  else
    delta_pct = ((median_ms - baseline_ms) / baseline_ms * 100).round(1)
    delta_ms  = (median_ms - baseline_ms).round(1)
    regressed = delta_pct > options[:threshold_pct] && delta_ms > options[:threshold_ms]

    status = regressed ? 'REGRESSION' : 'OK'
    puts "  Baseline: #{baseline_ms}ms | Now: #{median_ms}ms | Delta: #{delta_pct}% (#{delta_ms}ms) [#{status}]"

    if regressed
      regressions << {
        function:    fn_name,
        baseline_ms: baseline_ms,
        current_ms:  median_ms,
        delta_pct:   delta_pct,
        delta_ms:    delta_ms
      }
    end
  end
end

if regressions.any?
  puts "\n:x: PERFORMANCE REGRESSIONS DETECTED:\n"
  puts "| Function | Before | After | Delta |"
  puts "|----------|--------|-------|-------|"
  regressions.each do |r|
    puts "| #{r[:function]} | #{r[:baseline_ms]}ms | #{r[:current_ms]}ms | +#{r[:delta_pct]}% (+#{r[:delta_ms]}ms) |"
  end
  puts "\nPlease optimise the flagged functions before merging."
  exit 1
else
  # Persist updated baselines
  File.write(options[:baseline_path], JSON.pretty_generate(new_baselines))
  puts "\n:white_check_mark: All functions within performance threshold."
  exit 0
end
