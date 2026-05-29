#!/usr/bin/env ruby
# Entry point — run with:  ruby runner.rb
#               Dry run:   DRY_RUN=true ruby runner.rb

$LOAD_PATH.unshift File.join(__dir__, 'lib')

require 'yaml'
require 'elk_client'
require 'rca_engine'
require 'notifier'
require 'auto_pr'
require 'history_store'

class Runner
  CONFIG_PATH = File.join(__dir__, 'config', 'settings.yml')

  def initialize
    @config   = load_config
    @dry_run  = ENV['DRY_RUN'] == 'true'
    @elk      = ELKClient.new(@config['elasticsearch'])
    @rca      = RcaEngine.new(@config['anthropic'], @config['rca'])
    @notifier = Notifier.new(@config['notifications'])
    @auto_pr  = AutoPr.new(@config['github'])
    @history  = HistoryStore.new
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

    # Enrich with cross-run history (survives ELK's 2-day retention window).
    # Adds :appearance_count, :confirmed_slow, :consecutive_runs to each finding.
    findings.each { |f| @history.enrich(f) }
    puts "      History: #{@history.run_count} prior run(s) on record"

    print_findings_table(findings)

    # ── Step 2: RCA ────────────────────────────────────────────────────────────
    step "2/4", "Running root cause analysis"

    rca_limit  = @config.dig('thresholds', 'rca_limit') || 5
    actionable = findings.select { |f| %w[CRITICAL HIGH].include?(f[:severity]) }.first(rca_limit)

    confirmed_count   = actionable.count { |f| f[:confirmed_slow] }
    unconfirmed_count = actionable.size - confirmed_count
    puts "      Analyzing top #{actionable.size} HIGH/CRITICAL findings (rca_limit: #{rca_limit})"
    puts "      #{confirmed_count} confirmed (multi-run), #{unconfirmed_count} unconfirmed (first seen — may be infra blip)"

    actionable.each_with_index do |f, i|
      tag = f[:confirmed_slow] ? 'confirmed' : 'unconfirmed/new'
      print "      [#{i + 1}/#{actionable.size}] #{f[:collection]} (#{f[:query_hash]}) [#{tag}]... "
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

    # Only raise PRs when there is an actual code change (pipeline rewrite in mint-content).
    # Index suggestions surface in the audit email — no PR needed for those.
    fixable = actionable.select { |f| f[:code_patch] }

    # Always print per-finding PR decision so we know why each one did/didn't qualify.
    puts "      AI diagnosis summary:"
    actionable.each do |f|
      conf    = f[:confidence] ? "#{(f[:confidence].to_f * 100).round}%" : 'n/a'
      rewrite = f[:pipeline_rewrite] ? 'yes' : 'null'
      patch   = f[:code_patch]       ? "PR ready (#{f[:code_patch]['function']})" : 'no patch'
      src     = f[:candidate_pipeline] ? "#{f[:candidate_pipeline]['function']} [LLM-confirmed]" : "none (#{f[:candidate_shortlist]&.size || 0} shortlisted)"
      puts "        #{f[:collection]} (#{f[:query_hash]}) conf=#{conf} rewrite=#{rewrite} source=#{src} → #{patch}"
    end

    if @dry_run
      puts "      [DRY RUN] Would raise #{fixable.size} PR(s) (mint-content pipeline fixes only):"
      fixable.each do |f|
        conf = f[:confidence] ? " (#{(f[:confidence].to_f * 100).round}% confidence)" : ''
        puts "        - #{f[:code_patch]['file']}#{conf}"
        puts "          #{f[:pipeline_rewrite]}"
      end
    else
      fixable.each do |f|
        pr_url = @auto_pr.raise_pr(f)
        puts "      PR raised: #{pr_url}"
      end
    end

    # Persist this run's findings for future cross-run correlation.
    # Skipped in dry-run so test runs don't pollute the history.
    unless @dry_run
      @history.record(findings)
      puts "\n  History updated — #{findings.size} query shapes recorded."
    end

    # Show queries that vanished since last run (possible infra blip or fix).
    vanished = @history.vanished_since(findings)
    unless vanished.empty?
      puts "\n  Queries absent from ELK today (resolved or transient):"
      vanished.each do |v|
        puts "    #{v[:collection]} (#{v[:query_hash]}) — seen #{v[:appearance_count]}x, last #{v[:last_seen]}, avg #{v[:avg_ms_history]}ms"
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
      history_tag = if f[:appearance_count].to_i >= 1
                      seen = f[:appearance_count]
                      consecutive = f[:consecutive_runs].to_i
                      tag = "seen #{seen}x"
                      tag += " (#{consecutive} consecutive)" if consecutive >= 2
                      " [#{tag}]"
                    else
                      ' [new]'
                    end
      puts "  #{coll} #{sev} #{avg} #{max} #{ops} #{ratio}#{history_tag}"

      if f[:sample_query]
        snippet = f[:sample_query].gsub(/\s+/, ' ').strip[0, 160]
        snippet += '...' if f[:sample_query].length > 160
        puts "    Query: #{snippet}"
      end
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
      puts "  │ Fix:   #{f[:pipeline_rewrite] || f[:fix_description] || 'n/a'}"
      puts "  │ Note:  #{f[:index_suggestion]} (advisory — not applied)" if f[:index_suggestion]
      puts "  └"
    end
  end
end

Runner.new.run
