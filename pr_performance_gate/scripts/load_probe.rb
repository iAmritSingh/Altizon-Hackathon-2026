#!/usr/bin/env ruby
# Track 1 — Load probe (one function version)
#
# Fires a FaaS function's main() under concurrency against the (seeded) Mongo for a fixed duration
# and reports latency percentiles + throughput. Unlike the explain probe, this RUNS the real query
# repeatedly — actual load. Prints one JSON line:
#   {"requests":N,"errors":N,"throughput_rps":R,"p50_ms":..,"p95_ms":..,"p99_ms":..}
#
# Usage: ruby load_probe.rb <function_file> <fixture.json> <concurrency> <duration_seconds>
# Env:   PERF_GATE_BOOTSTRAP (runtime loader), PERF_GATE_MONGO_URL (seeded Mongo, via Mongoid)

require 'json'

file, fixture_file, conc, dur = ARGV
conc = (conc || 8).to_i
dur  = (dur  || 15).to_f
abort 'usage: load_probe.rb <file> <fixture.json> <concurrency> <duration_s>' unless file && fixture_file
fx = JSON.parse(File.read(fixture_file))

require File.expand_path(ENV['PERF_GATE_BOOTSTRAP']) if ENV['PERF_GATE_BOOTSTRAP'] && File.exist?(ENV['PERF_GATE_BOOTSTRAP'])
# Find the class the file defines via ObjectSpace diff (avoids built-ins like Process::Waiter).
before = ObjectSpace.each_object(Class).to_a
load File.expand_path(file)
klass = (ObjectSpace.each_object(Class).to_a - before).find { |c| c.respond_to?(:main) }
klass ||= File.read(file)[/^\s*class\s+([A-Z][\w:]*)/, 1]&.then { |n| Object.const_get(n) rescue nil }
abort 'no class with a .main method found' unless klass

lk  = fx['license_key']
tid = fx['task_id']
args = fx['args'] || {}
ctx  = fx['context'] || {}

def mono; Process.clock_gettime(Process::CLOCK_MONOTONIC); end

# Warm up — prime the connection pool + query plan cache so it isn't counted as latency.
3.times { klass.main(lk, tid, args, ctx) rescue nil }

samples = []
errors  = 0
lock    = Mutex.new
stop_at = mono + dur

threads = Array.new(conc) do
  Thread.new do
    while mono < stop_at
      t0 = mono
      begin
        klass.main(lk, tid, args, ctx)
        ms = (mono - t0) * 1000
        lock.synchronize { samples << ms }
      rescue => e
        lock.synchronize { errors += 1 }
        $stderr.puts "load_probe: call error: #{e.class}: #{e.message}" if errors <= 3
      end
    end
  end
end
threads.each(&:join)

sorted = samples.sort
pct = lambda do |p|
  return 0.0 if sorted.empty?
  idx = [(p / 100.0 * sorted.size).ceil - 1, 0].max
  sorted[idx].round(2)
end

puts JSON.generate(
  requests:       samples.size,
  errors:         errors,
  throughput_rps: (samples.size / dur).round(1),
  p50_ms:         pct.call(50),
  p95_ms:         pct.call(95),
  p99_ms:         pct.call(99)
)
