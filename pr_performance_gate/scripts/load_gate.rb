#!/usr/bin/env ruby
# Track 1 — Load-test gate
#
# For each changed FaaS function, load-tests the BASE (master) version and the PR (HEAD) version
# back-to-back on the same runner against the seeded Mongo, then blocks the merge if the PR's p95
# latency regresses beyond the threshold. Running both versions on the same machine cancels CI
# hardware noise (wall-clock baselines can't be committed reliably — same-runner A/B is the fix).
#
#   ruby load_gate.rb --functions "a.rb b.rb" --base origin/master \
#       --fixtures-dir .performance/fixtures --concurrency 8 --duration 15 \
#       --threshold-pct 20 --threshold-ms 50 --out gate_comment.md
#
# Exit: 0 = pass / skipped, 1 = p95 regression. Skips (never blocks) when Mongo or a fixture is
# missing, so it's safe before the runtime + seed are wired.

require 'optparse'
require 'json'
require 'open3'
require 'tempfile'

opts = {
  functions: [], base: 'origin/master', fixtures_dir: '.performance/fixtures',
  concurrency: 8, duration: 15, threshold_pct: 20, threshold_ms: 50, out: nil,
  probe: File.join(__dir__, 'load_probe.rb')
}
OptionParser.new do |o|
  o.on('--functions F')             { |v| opts[:functions] = v.split }
  o.on('--base REF')                { |v| opts[:base] = v }
  o.on('--fixtures-dir P')          { |v| opts[:fixtures_dir] = v }
  o.on('--concurrency N', Integer)  { |v| opts[:concurrency] = v }
  o.on('--duration N', Integer)     { |v| opts[:duration] = v }
  o.on('--threshold-pct N', Integer){ |v| opts[:threshold_pct] = v }
  o.on('--threshold-ms N', Integer) { |v| opts[:threshold_ms] = v }
  o.on('--out P')                   { |v| opts[:out] = v }
  o.on('--probe P')                 { |v| opts[:probe] = v }
end.parse!

# p95 regression needs BOTH a relative and an absolute jump (kills noise on fast functions).
def regressed?(head_p95, base_p95, pct_threshold, ms_threshold)
  return false if base_p95.nil? || base_p95.zero?
  delta = head_p95.to_f - base_p95.to_f
  return false if delta <= ms_threshold
  (delta / base_p95.to_f * 100) > pct_threshold
end

def run_probe(probe, file, fixture, conc, dur)
  out, status = Open3.capture2e('ruby', probe, file, fixture, conc.to_s, dur.to_s)
  warn out unless status.success?
  line = out.lines.reverse.find { |l| l.strip.start_with?('{') }
  line && JSON.parse(line)
rescue => e
  warn "load_gate: probe failed for #{file}: #{e.message}"
  nil
end

def base_file(base_ref, path)
  out, status = Open3.capture2('git', 'show', "#{base_ref}:#{path}")
  return nil unless status.success? && !out.empty?
  tf = Tempfile.new(['base_', '.rb'])
  tf.write(out)
  tf.close
  tf.path
end

mongo_url = ENV['PERF_GATE_MONGO_URL']
results = []
skipped = []

opts[:functions].each do |path|
  name    = File.basename(path, '.rb')
  fixture = File.join(opts[:fixtures_dir], "#{name}.json")
  if mongo_url.to_s.empty?
    skipped << { name: name, reason: 'PERF_GATE_MONGO_URL not set' }; next
  end
  unless File.exist?(fixture)
    skipped << { name: name, reason: "no fixture at #{fixture}" }; next
  end

  head_m = run_probe(opts[:probe], path, fixture, opts[:concurrency], opts[:duration])
  if head_m.nil?
    skipped << { name: name, reason: 'PR load probe failed (see log)' }; next
  end

  base_path = base_file(opts[:base], path)
  base_m    = base_path ? run_probe(opts[:probe], base_path, fixture, opts[:concurrency], opts[:duration]) : nil
  results << { name: name, head: head_m, base: base_m }
end

results.each do |r|
  bp = r[:base] && r[:base]['p95_ms']
  r[:regressed] = regressed?(r[:head]['p95_ms'], bp, opts[:threshold_pct], opts[:threshold_ms])
end
regressions = results.select { |r| r[:regressed] }

# ── PR comment ──────────────────────────────────────────────────────────────────
lines = ['## 🔎 PerformanceIQ — Load-test gate', '']
lines << "Load: #{opts[:concurrency]} concurrent × #{opts[:duration]}s per version, master vs PR on the same runner."
lines << ''
if results.any?
  lines << (regressions.any? ? '❌ **FAIL** — p95 latency regressed under load.' : '✅ **PASS** — no p95 regression under load.')
  lines << ''
  lines << '| Function | p95 (master → PR) | p99 | Throughput (master → PR) | Errors | Verdict |'
  lines << '|----------|-------------------|-----|--------------------------|-------:|---------|'
  results.each do |r|
    h = r[:head]; b = r[:base]
    bp95 = b ? "#{b['p95_ms']}ms" : '— (new)'
    chg  = b && b['p95_ms'].to_f.positive? ? " (#{((h['p95_ms'] - b['p95_ms']) / b['p95_ms'] * 100).round}%)" : ''
    btp  = b ? "#{b['throughput_rps']}" : '—'
    lines << "| `#{r[:name]}` | #{bp95} → **#{h['p95_ms']}ms**#{chg} | #{h['p99_ms']}ms | #{btp} → #{h['throughput_rps']}/s | #{h['errors']} | #{r[:regressed] ? '❌' : '✅'} |"
  end
  lines << '' << "Threshold: p95 > #{opts[:threshold_pct]}% **and** > #{opts[:threshold_ms]}ms slower than master." if regressions.any?
end
unless skipped.empty?
  lines << '' << '<details><summary>Skipped (not blocked)</summary>' << ''
  skipped.each { |s| lines << "- `#{s[:name]}` — #{s[:reason]}" }
  lines << '</details>'
end
lines << '' << '_Real load against a prod-scale seeded Mongo. Same-runner A/B, so CI hardware noise cancels._'
comment = lines.join("\n")

puts comment
File.write(opts[:out], comment) if opts[:out]
exit(regressions.any? ? 1 : 0)
