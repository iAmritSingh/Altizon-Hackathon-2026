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
require 'logger'

file, fixture_file, conc, dur = ARGV
conc = (conc || 8).to_i
dur  = (dur  || 15).to_f
abort 'usage: load_probe.rb <file> <fixture.json> <concurrency> <duration_s>' unless file && fixture_file
fx = JSON.parse(File.read(fixture_file))

require File.expand_path(ENV['PERF_GATE_BOOTSTRAP']) if ENV['PERF_GATE_BOOTSTRAP'] && File.exist?(ENV['PERF_GATE_BOOTSTRAP'])

# Permissive stub for runtime collaborators we don't model (logger, datonis, context, ...): any
# call returns self, so chains like `context.logger.info(...)` don't blow up the probe.
class PerfNull
  def method_missing(*) ; self; end
  def respond_to_missing?(*); true; end
  def to_s; ''; end
  def to_ary; []; end
  def each; end
end
$perf_null = PerfNull.new

# The factory runtime evaluates a function FILE with these locals already bound, then the file's
# trailing line invokes the work (e.g. `Mod::main(context, current_license_key, ...)` or
# `Klass.new(...).execute`). We reproduce that binding so the real file runs unchanged. Values
# come from the fixture by name; everything else is a permissive stub.
def perf_invoke(src, abs, fx)
  context             = fx['context'] || $perf_null
  ctx                 = context
  license_key         = fx['license_key']
  current_license_key = fx['license_key']
  task_id             = fx['task_id']
  current_task_id     = fx['task_id']
  args                = fx['args'] || {}
  params              = args
  logger              = $perf_null
  current_user        = $perf_null
  datonis             = $perf_null
  function_errors     = []
  eval(src, binding, abs)   # rubocop:disable Security/Eval — load-testing the real function body
end

abs = File.expand_path(file)
src = File.read(abs)

# Define the function (and run its top-level invocation once) inside the injected-locals binding.
before = ObjectSpace.each_object(Module).to_a
perf_invoke(src, abs, fx) rescue nil
defined = ObjectSpace.each_object(Module).to_a - before
klass = defined.find { |c| c.respond_to?(:main) }
klass ||= src.scan(/^\s*(?:module|class)\s+([A-Z][\w:]*)/).flatten
             .map { |n| Object.const_get(n) rescue nil }.compact.find { |c| c.respond_to?(:main) }

# Two invocation styles in mint-content:
#   (a) defines a module/class with `.main`  -> call it directly, repeatedly (cheap, no re-parse)
#   (b) pure top-level body (e.g. `Klass.new(...).execute`) -> re-eval the file body each iteration
if klass
  by_name = {
    'license_key' => fx['license_key'], 'current_license_key' => fx['license_key'],
    'task_id' => fx['task_id'], 'current_task_id' => fx['task_id'],
    'args' => fx['args'] || {}, 'params' => fx['args'] || {},
    'context' => fx['context'] || $perf_null, 'ctx' => fx['context'] || $perf_null,
    'logger' => $perf_null, 'datonis' => $perf_null, 'current_user' => $perf_null, 'function_errors' => []
  }
  call_args = klass.method(:main).parameters
                   .reject { |type, _| %i[block rest keyrest key keyreq].include?(type) }
                   .map { |_, name| fx.key?(name.to_s) ? fx[name.to_s] : by_name.fetch(name.to_s, nil) }
  invoke = -> { klass.main(*call_args) }
else
  invoke = -> { perf_invoke(src, abs, fx) }
end

def mono; Process.clock_gettime(Process::CLOCK_MONOTONIC); end

# Warm up — prime the connection pool + query plan cache so it isn't counted as latency.
3.times { invoke.call rescue nil }

samples = []
errors  = 0
lock    = Mutex.new
stop_at = mono + dur

threads = Array.new(conc) do
  Thread.new do
    while mono < stop_at
      t0 = mono
      begin
        invoke.call
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
n      = sorted.size
mean   = n.zero? ? 0.0 : sorted.sum / n
stddev = n.zero? ? 0.0 : Math.sqrt(sorted.sum { |x| (x - mean)**2 } / n)
total  = samples.size + errors

puts JSON.generate(
  requests:       samples.size,
  errors:         errors,
  error_rate_pct: total.zero? ? 0.0 : (errors.to_f / total * 100).round(2),
  throughput_rps: (samples.size / dur).round(1),
  min_ms:         (sorted.first || 0).round(2),
  mean_ms:        mean.round(2),
  p50_ms:         pct.call(50),
  p90_ms:         pct.call(90),
  p95_ms:         pct.call(95),
  p99_ms:         pct.call(99),
  max_ms:         (sorted.last || 0).round(2),
  stddev_ms:      stddev.round(2)
)
