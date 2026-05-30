#!/usr/bin/env ruby
# Track 1 — explain() probe (one function, one version)
#
# Boots the app runtime, lets a FaaS function's `main` BUILD its aggregation pipeline, intercepts
# that pipeline instead of running the heavy query, then runs `explain(executionStats)` against
# the configured (staging) Mongo and reports docs/keys examined. This measures SCAN COST — the
# thing that actually regresses — independent of result-set size or wall-clock noise.
#
# Prints one JSON line to stdout:  {"docs_examined":N,"keys_examined":N,"pipelines":N}
#
# Integration points (env):
#   PERF_GATE_BOOTSTRAP  Ruby file that loads the app's models + Mongoid connection
#                        (point this at the same loader mint-content/ci.yml uses).
#   PERF_GATE_MONGO_URL  connection string for the staging/representative DB (read-only creds).
#
# Usage: ruby explain_probe.rb <function_file.rb> <fixture.json>

require 'json'

function_file, fixture_file = ARGV
abort 'usage: explain_probe.rb <function_file> <fixture.json>' unless function_file && fixture_file
fixture = JSON.parse(File.read(fixture_file))

# 1. Boot the application runtime (models + Mongoid). The ONE integration point with factory.
bootstrap = ENV['PERF_GATE_BOOTSTRAP']
require File.expand_path(bootstrap) if bootstrap && File.exist?(bootstrap)

require 'mongo'

# 2. Intercept Collection#aggregate: capture the (collection, pipeline) and return an empty view
#    so main() proceeds cheaply. A guard lets us call the REAL aggregate during explain.
$perf_captured = []
$perf_intercept = true

class PerfDummyView
  include Enumerable
  def each(*); end
  def to_a; []; end
  def first(*); nil; end
  def count(*); 0; end
end

module PerfAggregateInterceptor
  def aggregate(pipeline, options = {})
    if $perf_intercept
      $perf_captured << { collection: self, pipeline: pipeline }
      PerfDummyView.new
    else
      super
    end
  end
end
Mongo::Collection.prepend(PerfAggregateInterceptor)

# 3. Load the function file and find the class IT defined (diff ObjectSpace before/after so we
#    don't pick up unrelated built-ins like Process::Waiter that also respond to .main).
before = ObjectSpace.each_object(Class).to_a
load File.expand_path(function_file)
klass = (ObjectSpace.each_object(Class).to_a - before).find { |c| c.respond_to?(:main) }
klass ||= File.read(function_file)[/^\s*class\s+([A-Z][\w:]*)/, 1]&.then { |n| Object.const_get(n) rescue nil }
abort 'no class with a .main method found in function file' unless klass

# 4. Invoke main with fixture inputs so it builds its pipeline(s). Order matches FaaS convention:
#    main(current_license_key, current_task_id, args, context)
begin
  klass.main(fixture['license_key'], fixture['task_id'], fixture['args'] || {}, fixture['context'] || {})
rescue => e
  warn "probe: main raised after pipeline capture (expected, results were stubbed): #{e.class}: #{e.message}"
end

# 5. explain() each captured pipeline against the live collection (interception off).
$perf_intercept = false
docs = keys = 0
$perf_captured.each do |cap|
  explain = cap[:collection].aggregate(cap[:pipeline]).explain
  docs += deep_max(explain, 'totalDocsExamined')
  keys += deep_max(explain, 'totalKeysExamined')
rescue => e
  warn "probe: explain failed for one pipeline: #{e.message}"
end

puts JSON.generate(docs_examined: docs, keys_examined: keys, pipelines: $perf_captured.size)

BEGIN {
  # Recursively find the largest value for `field` anywhere in an explain document.
  def deep_max(obj, field)
    case obj
    when Hash
      vals = obj.flat_map { |k, v| k == field ? [v.to_i] : [deep_max(v, field)] }
      vals.max || 0
    when Array
      obj.map { |v| deep_max(v, field) }.max || 0
    else
      0
    end
  end
}
