#!/usr/bin/env ruby
# frozen_string_literal: true

# MInt function load tester — drives a function's .main() under concurrent load
# and reports throughput, latency percentiles, and error rate.
#
# Usage:
#   ruby load_test.rb --driver drivers/example_driver.rb -c 8 -n 2000
#   ruby load_test.rb --driver drivers/example_driver.rb -c 16 -d 10 --mode process
#   ruby load_test.rb --driver drivers/my_fn.rb -c 8 -n 1000 --rps 200 --json out.json
#
# See README.md and drivers/ for how to write a driver for a real MInt function.

require "optparse"

here = __dir__
require File.join(here, "lib", "stats")
require File.join(here, "lib", "engine")
require File.join(here, "lib", "reporter")
require File.join(here, "lib", "target_loader")

opts = {
  concurrency: 8,
  iterations: nil,
  duration: nil,
  warmup: 0,
  rps: nil,
  mode: :thread,
  json: nil,
  title: nil,
  expect_p95: LoadTester::Reporter::EXPECTED_DEFAULTS[:p95_ms],
  expect_error_rate: LoadTester::Reporter::EXPECTED_DEFAULTS[:error_rate_pct],
  expect_rps: LoadTester::Reporter::EXPECTED_DEFAULTS[:min_rps],
  sweep: nil,
  compare: nil
}

parser = OptionParser.new do |o|
  o.banner = "Usage: ruby load_test.rb --driver FILE [options]"
  o.on("--driver FILE", "Driver file defining build_target(worker_id)") { |v| opts[:driver] = v }
  o.on("-c", "--concurrency N", Integer, "Concurrent workers (default 8)") { |v| opts[:concurrency] = v }
  o.on("-n", "--iterations N", Integer, "Total calls to make") { |v| opts[:iterations] = v }
  o.on("-d", "--duration SEC", Float, "Run for SEC seconds instead of fixed N") { |v| opts[:duration] = v }
  o.on("-w", "--warmup N", Integer, "Warmup calls before measuring (default 0)") { |v| opts[:warmup] = v }
  o.on("--rps N", Float, "Cap throughput at ~N req/s (default: unlimited)") { |v| opts[:rps] = v }
  o.on("--mode MODE", %i[thread process], "thread (default, GIL-bound) or process (fork, true parallelism)") { |v| opts[:mode] = v }
  o.on("--json FILE", "Also write the summary as JSON to FILE") { |v| opts[:json] = v }
  o.on("--title TEXT", "Report title") { |v| opts[:title] = v }
  o.on("--expect-p95 MS", Float, "Expected p95 latency ceiling in ms (default 1000)") { |v| opts[:expect_p95] = v }
  o.on("--expect-error-rate PCT", Float, "Expected error-rate ceiling in %% (default 1.0)") { |v| opts[:expect_error_rate] = v }
  o.on("--expect-rps N", Float, "Expected minimum throughput in req/s (default: none)") { |v| opts[:expect_rps] = v }
  o.on("--sweep LIST", Array, "Run at each load level, e.g. 10,100,1000 (each value = total calls)") { |v| opts[:sweep] = v.map { |x| Integer(x) } }
  o.on("--compare FILE", "Compare results against a saved --json baseline and report effectiveness") { |v| opts[:compare] = v }
  o.on("-h", "--help") { puts o; exit }
end
parser.parse!

abort parser.help unless opts[:driver]
abort "set --iterations or --duration (or --sweep)" if opts[:iterations].nil? && opts[:duration].nil? && opts[:sweep].nil?

factory = LoadTester::TargetLoader.load_driver(opts[:driver])
title = opts[:title] || "load test: #{File.basename(opts[:driver])}"
expected = { p95_ms: opts[:expect_p95], error_rate_pct: opts[:expect_error_rate], min_rps: opts[:expect_rps] }

# Run one configuration (fixed-count or time-boxed) and return its summary.
def run_summary(factory, opts, iterations:, duration:)
  plan = iterations ? "#{iterations} calls" : "#{duration}s"
  warn "  #{opts[:concurrency]} #{opts[:mode]} workers · #{plan}" \
       "#{opts[:rps] ? " · ≤#{opts[:rps]} rps" : ''}" \
       "#{opts[:warmup].positive? ? " · #{opts[:warmup]} warmup" : ''}"
  engine = LoadTester::Engine.new(
    target_factory: factory,
    concurrency: opts[:concurrency],
    iterations: iterations,
    duration: duration,
    warmup: opts[:warmup],
    target_rps: opts[:rps],
    mode: opts[:mode],
    on_progress: $stderr.tty? ? ->(c) { warn "  …#{c} done" } : nil
  )
  raw = engine.run
  LoadTester::Stats.summarize(
    latencies_ms: raw[:latencies_ms], errors: raw[:errors], wall_seconds: raw[:wall_seconds],
    concurrency: opts[:concurrency], mode: opts[:mode]
  )
end

warn "▶ #{title}"

if opts[:sweep]
  rows = opts[:sweep].map do |n|
    warn "  level #{n}:"
    { level: n, summary: run_summary(factory, opts, iterations: n, duration: nil) }
  end
  puts LoadTester::Reporter.sweep_console(rows, title: title, expected: expected)
  current_rows = rows
  json_out = { sweep: rows, expected: expected }
  all_failed = rows.all? { |r| r[:summary][:success].zero? && r[:summary][:requests].positive? }
else
  summary = run_summary(factory, opts, iterations: opts[:iterations], duration: opts[:duration])
  puts LoadTester::Reporter.console(summary, title: title)
  puts LoadTester::Reporter.advisory(summary, expected: expected)
  current_rows = LoadTester::Reporter.to_compare_rows(summary)
  json_out = summary.merge(expected: expected, verdict: LoadTester::Reporter.evaluate(summary, expected: expected))
  all_failed = summary[:success].zero? && summary[:requests].positive?
end

# Before/after effectiveness — diff the current run against a saved --json baseline.
if opts[:compare]
  baseline = JSON.parse(File.read(opts[:compare]), symbolize_names: true)
  before_rows = LoadTester::Reporter.to_compare_rows(baseline)
  puts LoadTester::Reporter.compare_console(before_rows, current_rows,
                                            title: "#{File.basename(opts[:compare])} → current")
end

if opts[:json]
  File.write(opts[:json], LoadTester::Reporter.json(json_out))
  warn "  wrote #{opts[:json]}"
end

# Non-zero exit if every call failed — useful in CI.
exit(all_failed ? 1 : 0)
