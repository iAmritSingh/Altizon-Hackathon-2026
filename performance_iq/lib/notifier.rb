require 'httparty'
require 'json'

# Track 2 (output) — Sends the audit digest via Slack webhook and SendGrid email.
# Pattern mirrors factory/lib/utils/slack_alerts_helper.rb + factory/app/mailers/factory_mailer.rb
class Notifier
  SENDGRID_URL = 'https://api.sendgrid.com/v3/mail/send'

  def initialize(config)
    @sendgrid_key  = config&.fetch('sendgrid_api_key', nil)
    @from_email    = config&.fetch('from_email', 'datonis@altizon.com')
    @to_emails     = Array(config&.fetch('to_emails', []))
    @slack_webhook = config&.fetch('slack_webhook_url', nil)
  end

  def send_digest(findings, collection_summary: [], vm_health: [], error_summary: [], stuck_semaphores: [], dashboards: {}, date: Time.now.strftime('%Y-%m-%d'))
    send_slack(findings, vm_health: vm_health, error_summary: error_summary, stuck_semaphores: stuck_semaphores, dashboards: dashboards, date: date)
    send_email(findings, collection_summary: collection_summary, vm_health: vm_health, error_summary: error_summary, stuck_semaphores: stuck_semaphores, dashboards: dashboards, date: date)
  end

  private

  # ── Slack ─────────────────────────────────────────────────────────────────────

  def send_slack(findings, vm_health: [], error_summary: [], stuck_semaphores: [], dashboards: {}, date:)
    return warn 'Notifier: no Slack webhook configured' unless @slack_webhook

    critical = findings.count { |f| f[:severity] == 'CRITICAL' }
    high     = findings.count { |f| f[:severity] == 'HIGH' }
    top      = findings.first

    worst_vm    = vm_health.first
    total_errs  = error_summary.sum { |e| e[:error_count].to_i }
    infra_line  = worst_vm ? "*Infra (24h peak):* worst VM `#{worst_vm[:vm]}` cpu #{worst_vm[:cpu_peak]}% / mem #{worst_vm[:mem_peak]}% / disk #{worst_vm[:disk_peak]}%" : nil
    error_line  = error_summary.any? ? "*Errors (24h):* #{total_errs} across #{error_summary.size} log streams" : nil
    stuck_line  = stuck_semaphores.any? ? "*Stuck machines:* #{stuck_semaphores.size} stuck on semaphore locks (worst `#{stuck_semaphores.first[:lock_key]}` ×#{stuck_semaphores.first[:tries]})" : nil
    sk          = dashboards[:sidekiq_performance]
    sidekiq_line = sk ? "*Sidekiq:* #{sk[:throughput_per_min]}/min, #{sk[:busy_workers]} busy, #{sk[:retry]} retry / #{sk[:dead]} dead" : nil

    # TODO: build richer Block Kit payload if desired
    text = <<~MSG.strip
      :rotating_light: *PerformanceIQ Audit — #{date}*
      #{critical} CRITICAL  |  #{high} HIGH  |  #{findings.size} total slow query shapes

      *Top offender:* `#{top&.dig(:collection) || 'n/a'}` — avg #{top&.dig(:avg_duration_ms).to_i}ms, #{top&.dig(:total_ops).to_i} ops in 24h
      *What's slow:* #{top&.dig(:impact_summary) || top&.dig(:root_cause) || top&.dig(:root_cause_type) || 'pending RCA'}
      *What we'll do:* #{top&.dig(:fix_summary) || top&.dig(:pipeline_rewrite) || top&.dig(:fix_description) || 'see email for details'}
      #{[infra_line, error_line, stuck_line, sidekiq_line].compact.join("\n")}
      #{findings.size > 1 ? "+#{findings.size - 1} more findings in email report" : ''}
    MSG

    HTTParty.post(
      @slack_webhook,
      headers: { 'Content-Type' => 'application/json' },
      body:    { text: text }.to_json,
      timeout: 10
    )
  rescue => e
    warn "Notifier: Slack send failed — #{e.message}"
  end

  # ── Email ─────────────────────────────────────────────────────────────────────

  def send_email(findings, collection_summary:, vm_health: [], error_summary: [], stuck_semaphores: [], dashboards: {}, date:)
    return warn 'Notifier: no SendGrid API key configured'  unless @sendgrid_key
    return warn 'Notifier: no recipient emails configured'  if @to_emails.empty?

    critical = findings.count { |f| f[:severity] == 'CRITICAL' }
    high     = findings.count { |f| f[:severity] == 'HIGH' }

    html = build_email_html(findings, collection_summary: collection_summary,
                            vm_health: vm_health, error_summary: error_summary,
                            stuck_semaphores: stuck_semaphores, dashboards: dashboards, date: date)
    payload = {
      personalizations: [{ to: @to_emails.map { |e| { email: e } } }],
      from:             { email: @from_email, name: 'PerformanceIQ' },
      subject:          "[PerformanceIQ] Daily Audit — #{critical} critical, #{high} high — #{date}",
      content:          [{ type: 'text/html', value: html }]
    }

    HTTParty.post(
      SENDGRID_URL,
      headers: {
        'Authorization' => "Bearer #{@sendgrid_key}",
        'Content-Type'  => 'application/json'
      },
      body:    payload.to_json,
      timeout: 15
    )
  rescue => e
    warn "Notifier: email send failed — #{e.message}"
  end

  # ── Email template ────────────────────────────────────────────────────────────

  def build_email_html(findings, collection_summary:, vm_health: [], error_summary: [], stuck_semaphores: [], dashboards: {}, date:)
    critical = findings.count { |f| f[:severity] == 'CRITICAL' }
    high     = findings.count { |f| f[:severity] == 'HIGH' }

    # Only show findings that actually got an RCA. Shapes below this run's deep-analysis
    # cut-off (rca_limit) carry no root_cause/impact_summary and would render as empty
    # "Not analysed" rows — omit them from the table and report the count as an aggregate.
    analysed = findings.select { |f| analysed?(f) }
    omitted  = findings.size - analysed.size

    rows = analysed.map do |f|
      color = f[:severity] == 'CRITICAL' ? '#c0392b' : f[:severity] == 'HIGH' ? '#e67e22' : '#2980b9'
      <<~ROW
        <tr>
          <td style="padding:6px 8px;border-bottom:1px solid #eee">
            <span style="color:#{color};font-weight:bold">#{f[:severity]}</span>
          </td>
          <td style="padding:6px 8px;border-bottom:1px solid #eee;font-family:monospace">#{f[:collection]}</td>
          <td style="padding:6px 8px;border-bottom:1px solid #eee;text-align:right">#{f[:avg_duration_ms].to_i}ms</td>
          <td style="padding:6px 8px;border-bottom:1px solid #eee;text-align:right">#{f[:max_duration_ms].to_i}ms</td>
          <td style="padding:6px 8px;border-bottom:1px solid #eee;text-align:right">#{f[:total_ops].to_i}</td>
          <td style="padding:6px 8px;border-bottom:1px solid #eee">
            #{why_cell(f)}
          </td>
          <td style="padding:6px 8px;border-bottom:1px solid #eee">
            #{fix_cell(f)}
          </td>
          <td style="padding:6px 8px;border-bottom:1px solid #eee">#{status_cell(f)}</td>
        </tr>
      ROW
    end.join

    <<~HTML
      <html><body style="font-family:Arial,sans-serif;color:#333;max-width:1100px;margin:auto">
        <h2 style="color:#2c3e50">PerformanceIQ — Daily Audit Report</h2>
        <p style="color:#666">#{date} &nbsp;|&nbsp;
          <span style="color:#c0392b;font-weight:bold">#{critical} CRITICAL</span> &nbsp;|&nbsp;
          <span style="color:#e67e22;font-weight:bold">#{high} HIGH</span> &nbsp;|&nbsp;
          #{findings.size} slow query shapes flagged, #{analysed.size} deep-analysed (detail at bottom)
        </p>

        <!-- ── 1. Sidekiq ── -->
        #{sidekiq_section(dashboards[:sidekiq_performance], dashboards[:sidekiq_queues])}

        <!-- ── 2. MongoDB storage utilisation ── -->
        #{mongo_utilisation_section(dashboards[:mongo_utilisation])}

        <!-- ── 3. MongoDB slowest collections ── -->
        #{mongo_performance_section(dashboards[:mongo_performance])}

        <!-- ── 4. Infrastructure (VM health) ── -->
        #{vm_health_section(vm_health)}

        <!-- ── 5. MongoDB slow queries & fixes ── -->
        <h3 style="color:#2c3e50;margin-top:32px">MongoDB slow queries — flagged shapes &amp; fixes</h3>
        <table style="width:100%;border-collapse:collapse;font-size:14px">
          <thead>
            <tr style="background:#f5f5f5;text-align:left">
              <th style="padding:8px">Severity</th>
              <th style="padding:8px">Collection</th>
              <th style="padding:8px;text-align:right">Avg ms</th>
              <th style="padding:8px;text-align:right">Max ms</th>
              <th style="padding:8px;text-align:right">Ops/24h</th>
              <th style="padding:8px">What's slow &amp; why</th>
              <th style="padding:8px">What we'll do</th>
              <th style="padding:8px">Status</th>
            </tr>
          </thead>
          <tbody>#{rows}</tbody>
        </table>
        #{omitted.positive? ? %(<p style="color:#888;font-size:12px;margin-top:8px">+#{omitted} more lower-priority slow query #{omitted == 1 ? 'shape' : 'shapes'} flagged but below this run's deep-analysis cut-off (<code>rca_limit</code>). Increase <code>rca_limit</code> to analyse more per run.</p>) : ''}

        <!-- ── 6. Operational logs — error scan last (stuck semaphores grouped with it) ── -->
        #{stuck_semaphore_section(stuck_semaphores)}
        #{error_scan_section(error_summary)}

        <hr style="margin-top:32px">
        <p style="color:#aaa;font-size:12px">
          Generated by PerformanceIQ &mdash; Altizon Hackathon 2026
        </p>
      </body></html>
    HTML
  end

  # ── Per-finding cells: plain-English why / fix / status ─────────────────────────

  # True when the finding received an RCA pass (Claude produced a cause/impact). Findings below
  # the run's rca_limit never reach the engine, so they have neither — those are omitted from the
  # email table rather than shown as empty "Not analysed" rows.
  def analysed?(f)
    !(f[:impact_summary] || f[:root_cause]).nil?
  end

  # "What's slow & why" — friendly summary, technical subtext, or an honest "not analysed".
  def why_cell(f)
    if f[:impact_summary] || f[:root_cause]
      tech = f[:impact_summary] && f[:root_cause] ? "<div style='color:#999;font-size:11px;margin-top:4px'>Technical: #{escape(f[:root_cause])}</div>" : ''
      "#{escape(f[:impact_summary] || f[:root_cause])}#{tech}"
    else
      "<span style='color:#999'>Not analysed yet — flagged as <b>#{escape(humanize(f[:root_cause_type]))}</b>. Only the top findings are deep-analysed each run.</span>"
    end
  end

  # "What we'll do" — friendly fix, expected gain, technical + advisory subtext.
  def fix_cell(f)
    return "<span style='color:#999'>—</span>" unless f[:fix_summary] || f[:pipeline_rewrite] || f[:fix_description]
    parts = [escape(f[:fix_summary] || f[:pipeline_rewrite] || f[:fix_description])]
    parts << "<div style='color:#27ae60;font-size:11px;margin-top:4px'>Expected: #{escape(f[:estimated_speedup])}</div>" if f[:estimated_speedup]
    parts << "<div style='color:#999;font-size:11px;margin-top:4px'>Technical: #{escape(f[:pipeline_rewrite])}</div>" if f[:fix_summary] && f[:pipeline_rewrite]
    parts << "<div style='color:#999;font-size:11px;margin-top:4px'>Advisory (not applied): #{escape(f[:index_suggestion])}</div>" if f[:index_suggestion]
    parts.join
  end

  # "Status" — where this finding is in the workflow, so a reader knows what (if anything)
  # is waiting on whom.
  def status_cell(f)
    if f[:pr_url]
      "<span style='color:#8250df;font-weight:bold'>PR raised</span>"\
      "<div style='font-size:11px;margin-top:2px'>Awaiting developer approval</div>"\
      "<div style='font-size:11px;margin-top:2px'><a href='#{escape(f[:pr_url])}' style='color:#1f6feb'>#{escape(f[:pr_url])}</a></div>"
    elsif f[:code_patch]
      "<span style='color:#e67e22;font-weight:bold'>Fix ready</span><div style='font-size:11px;margin-top:2px'>PR pending</div>"
    elsif f[:index_suggestion]
      "<span style='color:#2980b9'>Advisory</span><div style='font-size:11px;margin-top:2px'>For DBA review — no code change</div>"
    elsif f[:patch_skip_reason]
      "<span style='color:#777'>Needs manual review</span><div style='font-size:11px;margin-top:2px'>#{escape(f[:patch_skip_reason])}</div>"
    elsif f[:root_cause] || f[:impact_summary]
      "<span style='color:#777'>Analysed</span><div style='font-size:11px;margin-top:2px'>No automatic fix</div>"
    else
      "<span style='color:#aaa'>Not analysed</span><div style='font-size:11px;margin-top:2px'>Below this run's priority cut-off</div>"
    end
  end

  # Turns a rule label like POOR_INDEX_SELECTIVITY into "Poor index selectivity".
  def humanize(label)
    label.to_s.split('_').map(&:capitalize).join(' ').then { |s| s.empty? ? 'pending analysis' : s }
  end

  # ── Dashboards: Sidekiq ─────────────────────────────────────────────────────────

  def sidekiq_section(perf, queues)
    return '' if perf.nil? && (queues.nil? || queues.empty?)

    stats = ''
    if perf
      retry_c = perf[:retry].to_i.positive? ? '#e67e22' : '#27ae60'
      dead_c  = perf[:dead].to_i.positive?  ? '#c0392b' : '#27ae60'
      stats = <<~STATS
        <table style="border-collapse:collapse;font-size:13px;margin:0 0 10px">
          <tr>
            #{stat_box('Throughput', "#{perf[:throughput_per_min]}/min")}
            #{stat_box('Busy workers', perf[:busy_workers])}
            #{stat_box('Processed 24h', perf[:processed_window])}
            #{stat_box('Failed 24h', perf[:failed_window], perf[:failed_window].to_i.positive? ? '#c0392b' : '#27ae60')}
            #{stat_box('Retry', perf[:retry], retry_c)}
            #{stat_box('Dead', perf[:dead], dead_c)}
            #{stat_box('Scheduled', perf[:scheduled])}
          </tr>
        </table>
      STATS
    end

    # Bars are scaled to the busiest queue in this run so the worst one fills the track.
    max_backlog = ((queues || []).map { |q| q[:enqueued].to_i }.max || 0)
    max_backlog = 1 if max_backlog <= 0
    max_wait    = ((queues || []).map { |q| q[:latency_s].to_f }.max || 0.0)
    max_wait    = 1.0 if max_wait <= 0
    qrows = (queues || []).map do |q|
      lat_c  = q[:latency_s].to_f >= 60 ? '#c0392b' : q[:latency_s].to_f >= 10 ? '#e67e22' : '#27ae60'
      back_c = q[:enqueued].to_i.positive? ? '#2980b9' : '#27ae60'
      <<~ROW
        <tr>
          <td style="padding:5px 8px;border-bottom:1px solid #eee;font-family:monospace">#{escape(q[:queue])}</td>
          <td style="padding:5px 8px;border-bottom:1px solid #eee">#{bar_html(q[:enqueued].to_i * 100.0 / max_backlog, back_c, q[:enqueued], width_px: 130)}</td>
          <td style="padding:5px 8px;border-bottom:1px solid #eee">#{bar_html(q[:latency_s].to_f * 100.0 / max_wait, lat_c, "#{q[:latency_s]}s", width_px: 130)}</td>
          <td style="padding:5px 8px;border-bottom:1px solid #eee;text-align:right">#{q[:busy]}</td>
        </tr>
      ROW
    end.join

    <<~HTML
      <h3 style="color:#2c3e50;margin-top:32px">Sidekiq — job processing (last 24h)</h3>
      #{stats}
      #{qrows.empty? ? '' : %(<table style="width:100%;border-collapse:collapse;font-size:13px">
        <thead><tr style="background:#f5f5f5;text-align:left">
          <th style="padding:6px 8px">Queue</th>
          <th style="padding:6px 8px;text-align:right">Backlog</th>
          <th style="padding:6px 8px;text-align:right">Wait</th>
          <th style="padding:6px 8px;text-align:right">Busy</th>
        </tr></thead><tbody>#{qrows}</tbody></table>)}
    HTML
  end

  def stat_box(label, value, color = '#2c3e50')
    "<td style='padding:8px 14px;border:1px solid #eee;text-align:center'>"\
    "<div style='font-size:18px;font-weight:bold;color:#{color}'>#{value}</div>"\
    "<div style='font-size:11px;color:#888'>#{label}</div></td>"
  end

  # ── Dashboards: MongoDB ─────────────────────────────────────────────────────────

  def mongo_performance_section(rows)
    return '' if rows.nil? || rows.empty?
    # Scale bars to the slowest collection so it fills the track; colour by absolute ms (2ms = red).
    max_ms = rows.map { |c| c[:read_latency_us].to_f / 1000 }.max
    max_ms = 1.0 if max_ms.nil? || max_ms <= 0
    body = rows.map do |c|
      ms = (c[:read_latency_us].to_f / 1000).round(2)
      lat_c = ms >= 2 ? '#c0392b' : ms >= 1 ? '#e67e22' : '#27ae60'
      <<~ROW
        <tr>
          <td style="padding:5px 8px;border-bottom:1px solid #eee;font-family:monospace">#{escape(c[:collection])}</td>
          <td style="padding:5px 8px;border-bottom:1px solid #eee;font-size:12px;color:#888">#{escape(c[:db])}</td>
          <td style="padding:5px 8px;border-bottom:1px solid #eee">#{bar_html(ms * 100.0 / max_ms, lat_c, "#{ms} ms", width_px: 170)}</td>
          <td style="padding:5px 8px;border-bottom:1px solid #eee;text-align:right">#{c[:read_ops_sec]}/s</td>
        </tr>
      ROW
    end.join
    <<~HTML
      <h3 style="color:#2c3e50;margin-top:32px">MongoDB — slowest collections to read (24h avg)</h3>
      <p style="color:#666;font-size:12px;margin:0 0 8px">Average time per read operation, busiest-latency first. Over 2ms is flagged red.</p>
      <table style="width:100%;border-collapse:collapse;font-size:13px">
        <thead><tr style="background:#f5f5f5;text-align:left">
          <th style="padding:6px 8px">Collection</th>
          <th style="padding:6px 8px">Database</th>
          <th style="padding:6px 8px;text-align:right">Avg read time</th>
          <th style="padding:6px 8px;text-align:right">Read load</th>
        </tr></thead><tbody>#{body}</tbody></table>
    HTML
  end

  def mongo_utilisation_section(util)
    return '' if util.nil? || (util[:disk].to_a.empty? && util[:top_dbs].to_a.empty?)
    disk = (util[:disk] || []).map do |d|
      c = d[:used_pct] >= 85 ? '#c0392b' : d[:used_pct] >= 70 ? '#e67e22' : '#27ae60'
      "<tr><td style='padding:5px 8px;border-bottom:1px solid #eee;font-family:monospace'>#{escape(d[:rs])}</td>"\
      "<td style='padding:5px 8px;border-bottom:1px solid #eee;text-align:right;color:#{c};font-weight:bold'>#{d[:used_pct]}%</td></tr>"
    end.join
    dbs = (util[:top_dbs] || []).map do |d|
      "<tr><td style='padding:5px 8px;border-bottom:1px solid #eee;font-family:monospace'>#{escape(d[:db])}</td>"\
      "<td style='padding:5px 8px;border-bottom:1px solid #eee;text-align:right'>#{d[:data_gb]} GB</td>"\
      "<td style='padding:5px 8px;border-bottom:1px solid #eee;text-align:right'>#{d[:index_gb]} GB</td></tr>"
    end.join
    <<~HTML
      <h3 style="color:#2c3e50;margin-top:32px">MongoDB — storage utilisation</h3>
      <table style="width:48%;border-collapse:collapse;font-size:13px;display:inline-table;vertical-align:top;margin-right:3%">
        <thead><tr style="background:#f5f5f5;text-align:left"><th style="padding:6px 8px">Replica set</th><th style="padding:6px 8px;text-align:right">Disk used</th></tr></thead>
        <tbody>#{disk}</tbody>
      </table>
      <table style="width:48%;border-collapse:collapse;font-size:13px;display:inline-table;vertical-align:top">
        <thead><tr style="background:#f5f5f5;text-align:left"><th style="padding:6px 8px">Largest DBs</th><th style="padding:6px 8px;text-align:right">Data</th><th style="padding:6px 8px;text-align:right">Indexes</th></tr></thead>
        <tbody>#{dbs}</tbody>
      </table>
    HTML
  end

  # ── Stuck machines: repeated semaphore lock failures (sidekiq logs) ─────────────

  def stuck_semaphore_section(stuck)
    return '' if stuck.nil? || stuck.empty?

    rows = stuck.map do |s|
      span = span_label(s[:span_hours])
      # Spread over many hours = persistently stuck (worse than a quick burst).
      sticky = s[:span_hours].to_f >= 1 ? '#c0392b' : '#e67e22'
      <<~ROW
        <tr>
          <td style="padding:5px 8px;border-bottom:1px solid #eee;font-family:monospace">#{escape(s[:lock_key])}</td>
          <td style="padding:5px 8px;border-bottom:1px solid #eee;text-align:right;color:#{sticky};font-weight:bold">#{s[:tries]}</td>
          <td style="padding:5px 8px;border-bottom:1px solid #eee">#{span}</td>
          <td style="padding:5px 8px;border-bottom:1px solid #eee;font-size:12px">#{escape(s[:worker])}</td>
          <td style="padding:5px 8px;border-bottom:1px solid #eee;font-family:monospace;font-size:12px">#{escape(s[:vm])}</td>
        </tr>
      ROW
    end.join

    <<~HTML
      <h3 style="color:#2c3e50;margin-top:32px">Stuck machines — continuous semaphore-lock failures, last 24h (#{stuck.size})</h3>
      <p style="color:#666;font-size:12px;margin:0 0 8px">These machines have failed to get their lock several times in a row with <b>no successful lock since</b> — i.e. still stuck right now (not momentary contention; machines that recovered are excluded). Red = stuck for over an hour.</p>
      <table style="width:100%;border-collapse:collapse;font-size:13px">
        <thead><tr style="background:#f5f5f5;text-align:left">
          <th style="padding:6px 8px">Lock / machine</th>
          <th style="padding:6px 8px;text-align:right">Failed tries</th>
          <th style="padding:6px 8px">Stuck for</th>
          <th style="padding:6px 8px">Worker</th>
          <th style="padding:6px 8px">VM</th>
        </tr></thead>
        <tbody>#{rows}</tbody>
      </table>
    HTML
  end

  def span_label(hours)
    h = hours.to_f
    return 'momentary (<1h)' if h < 1
    return "#{h.round}h" if h < 48
    "#{(h / 24).round}d"
  end

  # ── Infra: per-VM health (Prometheus / node_exporter) ──────────────────────────

  # Hot threshold: a VM is "hot" if its peak on any of CPU/Mem/Disk reaches this. Healthy VMs
  # are collapsed into a single count instead of 50+ near-idle rows.
  VM_HOT_PCT = 70

  def vm_health_section(vm_health)
    return '' if vm_health.nil? || vm_health.empty?

    hot     = vm_health.select { |v| [v[:cpu_peak], v[:mem_peak], v[:disk_peak]].compact.max.to_f >= VM_HOT_PCT }
    healthy = vm_health.size - hot.size

    title = "Infrastructure — VM health over 24h (#{vm_health.size} VMs, #{hot.size} hot)"

    if hot.empty?
      return <<~HTML
        <h3 style="color:#2c3e50;margin-top:32px">#{title}</h3>
        <p style="color:#27ae60;font-size:13px;margin:0">All #{vm_health.size} VMs healthy — peak CPU/Mem/Disk stayed below #{VM_HOT_PCT}% over 24h.</p>
      HTML
    end

    rows = hot.map do |v|
      <<~ROW
        <tr>
          <td style="padding:6px 8px;border-bottom:1px solid #eee;font-family:monospace;font-size:12px">#{v[:vm]}</td>
          <td style="padding:6px 8px;border-bottom:1px solid #eee">#{vm_bar(v[:cpu_peak], v[:cpu_avg])}</td>
          <td style="padding:6px 8px;border-bottom:1px solid #eee">#{vm_bar(v[:mem_peak], v[:mem_avg])}</td>
          <td style="padding:6px 8px;border-bottom:1px solid #eee">#{vm_bar(v[:disk_peak], v[:disk_avg])}</td>
          <td style="padding:6px 8px;border-bottom:1px solid #eee;text-align:right;font-size:12px">#{v[:load1_peak] || '—'} <span style="color:#999">(#{v[:load1_avg] || '—'})</span></td>
        </tr>
      ROW
    end.join

    <<~HTML
      <h3 style="color:#2c3e50;margin-top:32px">#{title}</h3>
      <p style="color:#666;font-size:12px;margin:0 0 8px">Bars show <b>24h peak</b> utilisation (<span style="color:#999">avg</span> in brackets). Only VMs with a peak ≥#{VM_HOT_PCT}% on any metric are listed — red ≥85%, amber ≥#{VM_HOT_PCT}%. Sorted worst-first.</p>
      <table style="width:100%;border-collapse:collapse;font-size:13px">
        <thead><tr style="background:#f5f5f5;text-align:left">
          <th style="padding:6px 8px">VM</th>
          <th style="padding:6px 8px">CPU peak</th>
          <th style="padding:6px 8px">Mem peak</th>
          <th style="padding:6px 8px">Disk peak</th>
          <th style="padding:6px 8px;text-align:right">Load1</th>
        </tr></thead>
        <tbody>#{rows}</tbody>
      </table>
      #{healthy.positive? ? %(<p style="color:#27ae60;font-size:12px;margin-top:8px">+#{healthy} more VMs healthy — peak below #{VM_HOT_PCT}% on CPU, Mem and Disk.</p>) : ''}
    HTML
  end

  # Per-metric utilisation bar coloured by peak, with "peak% (avg%)" label. Used in VM health.
  def vm_bar(peak, avg)
    return '<span style="color:#999">—</span>' if peak.nil?
    color = peak >= 85 ? '#c0392b' : peak >= VM_HOT_PCT ? '#e67e22' : '#27ae60'
    bar_html(peak, color, "#{peak}% <span style='color:#999'>(#{avg || '—'}%)</span>", width_px: 90)
  end

  # Email-safe horizontal bar: a grey track with a coloured fill at `pct`% width, plus a label to
  # the right. Pure inline CSS (no SVG/canvas/JS) so it renders in Gmail, Outlook, Apple Mail, etc.
  # `pct` is clamped to 0..100; `width_px` is the track width in pixels.
  def bar_html(pct, color, label, width_px: 120)
    w = [[pct.to_f, 0.0].max, 100.0].min.round
    %(<span style="display:inline-block;vertical-align:middle;width:#{width_px}px;height:12px;background:#eee;border-radius:3px;overflow:hidden">) +
      %(<span style="display:inline-block;width:#{w}%;height:12px;background:#{color};border-radius:3px"></span></span>) +
      %( <span style="display:inline-block;vertical-align:middle;font-size:12px;color:#333">#{label}</span>)
  end

  # ── Other ELK logs: error scan ─────────────────────────────────────────────────

  def error_scan_section(error_summary)
    return '' if error_summary.nil? || error_summary.empty?

    rows = error_summary.map do |e|
      vms     = e[:top_vms].to_a.map { |v| "#{v[:vm]} (#{v[:count]})" }.join(', ')
      sample  = e[:samples].to_a.first
      count_c = e[:error_count].to_i.positive? ? '#c0392b' : '#27ae60'
      <<~ROW
        <tr>
          <td style="padding:5px 8px;border-bottom:1px solid #eee;font-family:monospace">#{e[:index]}</td>
          <td style="padding:5px 8px;border-bottom:1px solid #eee;text-align:right;color:#{count_c};font-weight:bold">#{e[:error_count]}</td>
          <td style="padding:5px 8px;border-bottom:1px solid #eee;font-size:12px">#{vms.empty? ? '—' : vms}</td>
          <td style="padding:5px 8px;border-bottom:1px solid #eee;font-family:monospace;font-size:11px;color:#777">#{escape(sample)}</td>
        </tr>
      ROW
    end.join

    total = error_summary.sum { |e| e[:error_count].to_i }
    <<~HTML
      <h3 style="color:#2c3e50;margin-top:32px">Error scan — other ELK log streams (#{total} errors / 24h)</h3>
      <p style="color:#666;font-size:12px;margin:0 0 8px">Severity-filtered (error/fatal/crit/alert/emerg/exception) across non-Mongo log indices.</p>
      <table style="width:100%;border-collapse:collapse;font-size:13px">
        <thead><tr style="background:#f5f5f5;text-align:left">
          <th style="padding:6px 8px">Log index</th>
          <th style="padding:6px 8px;text-align:right">Errors</th>
          <th style="padding:6px 8px">Top VMs</th>
          <th style="padding:6px 8px">Latest sample</th>
        </tr></thead>
        <tbody>#{rows}</tbody>
      </table>
    HTML
  end

  def escape(str)
    str.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
  end
end
