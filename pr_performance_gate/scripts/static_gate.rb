#!/usr/bin/env ruby
# Track 1 — Static pipeline-shape gate (PRIMARY, data-independent)
#
# Compares each changed function's pipeline shape in the PR against its version on the base branch
# and blocks the merge when the PR makes the pipeline structurally worse. Needs NO database and NO
# fixtures, so it can't be fooled by limited staging data — it measures the regressions that
# matter regardless of row counts:
#   - added $lookup / $unwind / $facet  (fan-out — more work per document)
#   - dropped a $match filter            (fewer filters = wider scan)
#   - removed the license_key filter     (cross-tenant scan on a shared collection)
#
#   ruby static_gate.rb --functions "a.rb b.rb" --base origin/master --out gate_comment.md
#
# Exit: 0 = no structural regression, 1 = regression (block).

require 'optparse'
require 'json'
require 'open3'

opts = { functions: [], base: 'origin/master', out: nil }
OptionParser.new do |o|
  o.on('--functions F') { |v| opts[:functions] = v.split }
  o.on('--base REF')    { |v| opts[:base] = v }
  o.on('--out P')       { |v| opts[:out] = v }
end.parse!

# Structural metrics for one function's source. Pure string analysis — no parsing, no DB.
def metrics(src)
  {
    lookup:       src.scan(/\$lookup\b/).size,
    unwind:       src.scan(/\$unwind\b/).size,
    facet:        src.scan(/\$facet\b/).size,
    match:        src.scan(/\$match\b/).size,
    license_key:  src.scan(/["']license_key["']/).size
  }
end

# Returns a list of regression strings (empty = no regression). A removed/added stage is judged
# only in the worsening direction; improvements (fewer lookups, more filters) never block.
def regressions(old, new)
  r = []
  r << "added #{new[:lookup] - old[:lookup]} \$lookup (fan-out / join)"        if new[:lookup] > old[:lookup]
  r << "added #{new[:unwind] - old[:unwind]} \$unwind (row fan-out)"           if new[:unwind] > old[:unwind]
  r << "added #{new[:facet] - old[:facet]} \$facet (parallel sub-pipelines)"   if new[:facet]  > old[:facet]
  r << "removed #{old[:match] - new[:match]} \$match filter(s)"                if new[:match]  < old[:match]
  r << 'removed a license_key filter (cross-tenant scan)'                       if old[:license_key].positive? && new[:license_key] < old[:license_key]
  r
end

# Base-branch version of a file (empty when the file is new on this branch).
def base_source(base, path)
  out, status = Open3.capture2('git', 'show', "#{base}:#{path}")
  status.success? ? out : ''
end

findings = opts[:functions].map do |path|
  name = File.basename(path, '.rb')
  head = File.exist?(path) ? File.read(path) : ''
  base = base_source(opts[:base], path)
  next nil if base.empty? # new function — nothing to regress against
  o = metrics(base)
  n = metrics(head)
  { name: name, old: o, new: n, regressions: regressions(o, n) }
end.compact

regressed = findings.select { |f| f[:regressions].any? }

# ── PR comment ──────────────────────────────────────────────────────────────────
lines = ['## 🔎 PerformanceIQ — Performance Gate (pipeline shape)', '']
if findings.empty?
  lines << '_No changed functions had a prior version to compare (new files or no pipeline changes)._'
else
  lines << (regressed.any? ? '❌ **FAIL** — a change makes a pipeline structurally heavier.' : '✅ **PASS** — no structural regression.')
  lines << ''
  lines << '| Function | $lookup | $unwind | $facet | $match | Verdict |'
  lines << '|----------|--------:|--------:|-------:|-------:|---------|'
  findings.each do |f|
    cell = ->(k) { f[:old][k] == f[:new][k] ? f[:new][k].to_s : "#{f[:old][k]}→**#{f[:new][k]}**" }
    verdict = f[:regressions].any? ? '❌' : '✅'
    lines << "| `#{f[:name]}` | #{cell[:lookup]} | #{cell[:unwind]} | #{cell[:facet]} | #{cell[:match]} | #{verdict} |"
  end
  if regressed.any?
    lines << '' << '**Regressions:**'
    regressed.each { |f| f[:regressions].each { |msg| lines << "- `#{f[:name]}`: #{msg}" } }
    lines << '' << '_If this is intentional (e.g. a genuinely new join), a maintainer can override. Otherwise, optimise before merging._'
  end
end
lines << '' << '_Compares pipeline shape vs the base branch — data-volume independent (staging data size does not affect it)._'
comment = lines.join("\n")

puts comment
File.write(opts[:out], comment) if opts[:out]
exit(regressed.any? ? 1 : 0)
