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

  def send_digest(findings, collection_summary: [], date: Time.now.strftime('%Y-%m-%d'))
    send_slack(findings, date: date)
    send_email(findings, collection_summary: collection_summary, date: date)
  end

  private

  # ── Slack ─────────────────────────────────────────────────────────────────────

  def send_slack(findings, date:)
    return warn 'Notifier: no Slack webhook configured' unless @slack_webhook

    critical = findings.count { |f| f[:severity] == 'CRITICAL' }
    high     = findings.count { |f| f[:severity] == 'HIGH' }
    top      = findings.first

    # TODO: build richer Block Kit payload if desired
    text = <<~MSG.strip
      :rotating_light: *PerformanceIQ Audit — #{date}*
      #{critical} CRITICAL  |  #{high} HIGH  |  #{findings.size} total slow query shapes

      *Top offender:* `#{top&.dig(:collection) || 'n/a'}` — avg #{top&.dig(:avg_duration_ms).to_i}ms, #{top&.dig(:total_ops).to_i} ops in 24h
      *Root cause:* #{top&.dig(:root_cause) || top&.dig(:root_cause_type) || 'pending RCA'}
      *Fix:* #{top&.dig(:index_suggestion) || top&.dig(:fix_description) || 'see email for details'}
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

  def send_email(findings, collection_summary:, date:)
    return warn 'Notifier: no SendGrid API key configured'  unless @sendgrid_key
    return warn 'Notifier: no recipient emails configured'  if @to_emails.empty?

    critical = findings.count { |f| f[:severity] == 'CRITICAL' }
    high     = findings.count { |f| f[:severity] == 'HIGH' }

    payload = {
      personalizations: [{ to: @to_emails.map { |e| { email: e } } }],
      from:             { email: @from_email, name: 'PerformanceIQ' },
      subject:          "[PerformanceIQ] Daily Audit — #{critical} critical, #{high} high — #{date}",
      content:          [{ type: 'text/html', value: build_email_html(findings, collection_summary: collection_summary, date: date) }]
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

  def build_email_html(findings, collection_summary:, date:)
    critical = findings.count { |f| f[:severity] == 'CRITICAL' }
    high     = findings.count { |f| f[:severity] == 'HIGH' }

    rows = findings.map do |f|
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
          <td style="padding:6px 8px;border-bottom:1px solid #eee">#{f[:root_cause] || f[:root_cause_type]}</td>
          <td style="padding:6px 8px;border-bottom:1px solid #eee;font-family:monospace;font-size:12px">
            #{f[:index_suggestion] || f[:fix_description] || '—'}
          </td>
        </tr>
      ROW
    end.join

    <<~HTML
      <html><body style="font-family:Arial,sans-serif;color:#333;max-width:1100px;margin:auto">
        <h2 style="color:#2c3e50">PerformanceIQ — Daily Audit Report</h2>
        <p style="color:#666">#{date} &nbsp;|&nbsp;
          <span style="color:#c0392b;font-weight:bold">#{critical} CRITICAL</span> &nbsp;|&nbsp;
          <span style="color:#e67e22;font-weight:bold">#{high} HIGH</span> &nbsp;|&nbsp;
          #{findings.size} total query shapes flagged
        </p>
        <table style="width:100%;border-collapse:collapse;font-size:14px">
          <thead>
            <tr style="background:#f5f5f5;text-align:left">
              <th style="padding:8px">Severity</th>
              <th style="padding:8px">Collection</th>
              <th style="padding:8px;text-align:right">Avg ms</th>
              <th style="padding:8px;text-align:right">Max ms</th>
              <th style="padding:8px;text-align:right">Ops/24h</th>
              <th style="padding:8px">Root Cause</th>
              <th style="padding:8px">Suggested Fix</th>
            </tr>
          </thead>
          <tbody>#{rows}</tbody>
        </table>
        <hr style="margin-top:32px">
        <p style="color:#aaa;font-size:12px">
          Generated by PerformanceIQ &mdash; Altizon Hackathon 2026
        </p>
      </body></html>
    HTML
  end
end
