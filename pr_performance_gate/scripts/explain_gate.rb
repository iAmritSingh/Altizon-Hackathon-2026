#!/usr/bin/env ruby
# Track 1 — Performance Gate (explain-based)
#
# For each changed FaaS function, measures docs-examined via explain() against the staging DB
# (see explain_probe.rb) and compares to the committed baseline. Blocks the PR when a function's
# scan cost regresses beyond the threshold. Updates baselines on merge to master.
#
#   ruby explain_gate.rb --functions "a.rb b.rb" --baseline .performance/baselines.json \
#       --fixtures-dir .performance/fixtures --threshold-pct 20 --threshold-abs 1000 \
#       --out gate_comment.md [--update-baseline]
#
# Exit: 0 = pass / skipped, 1 = at least one regression.
# Safe by design: if PERF_GATE_MONGO_URL is unset or a function has no fixture, that function is
# SKIPPED (reported, not blocked) — so the gate can be merged before staging access exists.

require 'optparse'
require 'json'
require 'open3'

opts = {
  functions: [], baseline: '.performance/baselines.json', fixtures_dir: '.performance/fixtures',
  threshold_pct: 20, threshold_abs: 1000, out: nil, update: false,
  probe: File.join(__dir__, 'explain_probe.rb')
}
OptionParser.new do |o|
  o.on('--functions F')            { |v| opts[:functions] = v.split }
  o.on('--baseline P')             { |v| opts[:baseline] = v }
  o.on('--fixtures-dir P')         { |v| opts[:fixtures_dir] = v }
  o.on('--threshold-pct N', Integer) { |v| opts[:threshold_pct] = v }
  o.on('--threshold-abs N', Integer) { |v| opts[:threshold_abs] = v }
  o.on('--out P')                  { |v| opts[:out] = v }
  o.on('--update-baseline')        { opts[:update] = true }
  o.on('--probe P')                { |v| opts[:probe] = v }
end.parse!

# Pure decision: a regression needs BOTH a relative AND an absolute jump (avoids noise on
# already-cheap queries). New function (no baseline) is never a regression.
def regressed?(docs, baseline, pct_threshold, abs_threshold)
  return false if baseline.nil?
  delta = docs - baseline
  return false if delta <= abs_threshold
  pct = baseline.zero? ? (docs.positive? ? Float::INFINITY : 0.0) : (delta.to_f / baseline * 100)
  pct > pct_threshold
end

# Shells the probe for one function; returns docs_examined Integer or nil on failure.
def measure(probe, file, fixture)
  out, status = Open3.capture2e('ruby', probe, file, fixture)
  warn out unless status.success?
  line = out.lines.reverse.find { |l| l.strip.start_with?('{') }
  line && JSON.parse(line)['docs_examined']
rescue => e
  warn "gate: measure failed for #{file}: #{e.message}"
  nil
end

mongo_url = ENV['PERF_GATE_MONGO_URL']
baselines = File.exist?(opts[:baseline]) ? JSON.parse(File.read(opts[:baseline])) : {}
results = []
skipped = []

opts[:functions].each do |file|
  name    = File.basename(file, '.rb')
  fixture = File.join(opts[:fixtures_dir], "#{name}.json")
  if mongo_url.to_s.empty?
    skipped << { name: name, reason: 'PERF_GATE_MONGO_URL not set' }
    next
  end
  unless File.exist?(fixture)
    skipped << { name: name, reason: "no fixture at #{fixture}" }
    next
  end
  docs = measure(opts[:probe], file, fixture)
  if docs.nil?
    skipped << { name: name, reason: 'probe failed (see CI log)' }
    next
  end
  results << { name: name, docs: docs, baseline: baselines[name] }
end

results.each do |r|
  r[:regressed] = regressed?(r[:docs], r[:baseline], opts[:threshold_pct], opts[:threshold_abs])
end
regressions = results.select { |r| r[:regressed] }

# ── Build PR comment ────────────────────────────────────────────────────────────
def fmt(n); n.nil? ? '—' : n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse; end

lines = ['## 🔎 PerformanceIQ — Performance Gate', '']
if results.any?
  verdict = regressions.any? ? '❌ **FAIL** — scan cost regressed' : '✅ **PASS** — no scan-cost regression'
  lines << verdict << ''
  lines << '| Function | Docs examined (baseline → PR) | Change | Verdict |'
  lines << '|----------|------------------------------|--------|---------|'
  results.each do |r|
    delta = r[:baseline] ? r[:docs] - r[:baseline] : nil
    change = if r[:baseline].nil? then 'new baseline'
             elsif r[:baseline].zero? then "+#{fmt(r[:docs])}"
             else "#{delta >= 0 ? '+' : ''}#{(delta.to_f / r[:baseline] * 100).round}% (#{delta >= 0 ? '+' : ''}#{fmt(delta)})"
             end
    lines << "| `#{r[:name]}` | #{fmt(r[:baseline])} → #{fmt(r[:docs])} | #{change} | #{r[:regressed] ? '❌ regressed' : '✅ ok'} |"
  end
  lines << ''
  lines << "Threshold: > #{opts[:threshold_pct]}% **and** > #{fmt(opts[:threshold_abs])} more docs examined." if regressions.any?
end
unless skipped.empty?
  lines << '' << '<details><summary>Skipped (not blocked)</summary>' << ''
  skipped.each { |s| lines << "- `#{s[:name]}` — #{s[:reason]}" }
  lines << '</details>'
end
lines << '' << '_Measured via `explain(executionStats)` against staging — docs examined, not wall-clock._'
comment = lines.join("\n")

puts comment
File.write(opts[:out], comment) if opts[:out]

# ── Update baselines on merge ─────────────────────────────────────────────────────
if opts[:update] && results.any?
  results.each { |r| baselines[r[:name]] = r[:docs] }
  File.write(opts[:baseline], JSON.pretty_generate(baselines))
  warn "gate: updated #{results.size} baseline(s)"
end

exit(regressions.any? ? 1 : 0)
