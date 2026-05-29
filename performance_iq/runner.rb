#!/usr/bin/env ruby
# Entry point — run with:  ruby runner.rb
#               Dry run:   DRY_RUN=true ruby runner.rb

$LOAD_PATH.unshift File.join(__dir__, 'lib')

require 'yaml'
require 'elk_client'
require 'rca_engine'
require 'notifier'
require 'auto_pr'

class Runner
  CONFIG_PATH = File.join(__dir__, 'config', 'settings.yml')

  def initialize
    @config   = load_config
    @dry_run  = ENV['DRY_RUN'] == 'true'
    @elk      = ELKClient.new(@config['elasticsearch'])
    @rca      = RcaEngine.new(@config['anthropic'])
    @notifier = Notifier.new(@config['notifications'])
    @auto_pr  = AutoPr.new(@config['github'])
  end

  def run
    banner "PerformanceIQ Audit — #{Time.now.strftime('%Y-%m-%d %H:%M UTC')}"
    puts "  Mode: #{@dry_run ? 'DRY RUN (no notifications or PRs)' : 'LIVE'}\n\n"

    # ── Step 1: Fetch from ELK ─────────────────────────────────────────────────
    step "1/4", "Fetching slow queries from ELK"

    hours   = @config.dig('thresholds', 'lookback_hours')   || 24
    min_ms  = @config.dig('thresholds', 'min_duration_ms')  || 100
    limit   = @config.dig('thresholds', 'top_n')            || 20

    findings = @elk.fetch_top_offenders(hours: hours, min_duration_ms: min_ms, limit: limit)
    summary  = @elk.fetch_collection_summary(hours: hours, min_duration_ms: min_ms)

    puts "      Found #{findings.size} distinct query shapes across #{summary.size} collections"
    print_findings_table(findings)

    # ── Step 2: RCA ────────────────────────────────────────────────────────────
    step "2/4", "Running root cause analysis"

    rca_limit  = @config.dig('thresholds', 'rca_limit') || 5
    actionable = findings.select { |f| %w[CRITICAL HIGH].include?(f[:severity]) }.first(rca_limit)
    puts "      Analyzing top #{actionable.size} HIGH/CRITICAL findings (rca_limit: #{rca_limit})"
    actionable.each_with_index do |f, i|
      print "      [#{i + 1}/#{actionable.size}] #{f[:collection]} (#{f[:query_hash]})... "
      @rca.diagnose(f)
      puts f[:root_cause_type] || 'done'
    end

    # ── Step 3: Notifications ──────────────────────────────────────────────────
    step "3/4", "Sending digest"

    if @dry_run
      puts "      [DRY RUN] Skipping email + Slack"
      print_rca_preview(actionable)
    else
      @notifier.send_digest(findings, collection_summary: summary, date: Time.now.strftime('%Y-%m-%d'))
      puts "      Email + Slack sent"
    end

    # ── Step 4: Auto-PR ────────────────────────────────────────────────────────
    step "4/4", "Raising fix PRs"

    fixable = actionable.select { |f| f[:index_suggestion] }
    if @dry_run
      puts "      [DRY RUN] Would raise #{fixable.size} PR(s):"
      fixable.each { |f| puts "        - #{f[:collection]}: #{f[:index_suggestion]}" }
    else
      fixable.each do |f|
        pr_url = @auto_pr.raise_pr(f)
        puts "      PR raised: #{pr_url}"
      end
    end

    banner "Audit complete"

    critical = findings.count { |f| f[:severity] == 'CRITICAL' }
    exit 1 if critical > 0 && !@dry_run
  end

  private

  def load_config
    unless File.exist?(CONFIG_PATH)
      abort "Missing config: #{CONFIG_PATH}\nCopy config/settings.yml.example to config/settings.yml and fill in your credentials."
    end
    YAML.load_file(CONFIG_PATH)
  end

  def step(label, message)
    puts "[#{label}] #{message}..."
  end

  def banner(text)
    puts "\n#{'─' * 60}"
    puts "  #{text}"
    puts "#{'─' * 60}"
  end

  def print_findings_table(findings)
    return puts "      No slow queries found." if findings.empty?

    puts
    puts "  #{'Collection'.ljust(32)} #{'Sev'.ljust(9)} #{'Avg ms'.rjust(8)} #{'Max ms'.rjust(8)} " \
         "#{'Ops'.rjust(6)} #{'Scan ratio'.rjust(11)}"
    puts "  #{'-' * 78}"
    findings.each do |f|
      coll  = (f[:collection] || 'unknown').ljust(32)
      sev   = f[:severity].ljust(9)
      avg   = f[:avg_duration_ms].to_i.to_s.rjust(8)
      max   = f[:max_duration_ms].to_i.to_s.rjust(8)
      ops   = f[:total_ops].to_i.to_s.rjust(6)
      ratio = f[:avg_scan_ratio].to_f.round(0).to_i.to_s.rjust(11)
      puts "  #{coll} #{sev} #{avg} #{max} #{ops} #{ratio}"
    end
    puts
  end

  def print_rca_preview(findings)
    return if findings.empty?
    puts "\n  RCA Preview:"
    findings.each do |f|
      puts "  ┌ #{f[:collection]} (#{f[:query_hash]}) — #{f[:severity]}"
      puts "  │ Cause: #{f[:root_cause_type]}"
      puts "  │ AI:    #{f[:root_cause] || '(not yet analyzed)'}"
      puts "  │ Fix:   #{f[:index_suggestion] || f[:fix_description] || 'n/a'}"
      puts "  └"
    end
  end
end

Runner.new.run
