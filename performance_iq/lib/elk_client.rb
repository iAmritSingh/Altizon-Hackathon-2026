require 'httparty'
require 'json'
require 'time'

class ELKClient
  DEFAULT_INDEX = 'dfx-mongodb-logs-*'

  def initialize(config)
    @host    = config['host']
    @api_key = config['api_key']
    @index   = config.fetch('index', DEFAULT_INDEX)
  end

  # Returns top slow query shapes aggregated by query_hash, sorted by avg duration desc.
  def fetch_top_offenders(hours: 24, min_duration_ms: 100, limit: 20)
    body     = top_offenders_query(hours: hours, min_duration_ms: min_duration_ms, limit: limit)
    response = post("#{@index}/_search", body)
    parse_offenders(response)
  end

  # Returns per-collection summary — useful for the digest headline numbers.
  def fetch_collection_summary(hours: 24, min_duration_ms: 100)
    body     = collection_summary_query(hours: hours, min_duration_ms: min_duration_ms)
    response = post("#{@index}/_search", body)
    parse_collection_summary(response)
  end

  # Scans other log indices (nginx/app error streams) for genuine error-level entries and
  # summarises them for the digest. These indices carry warnings/notices too, so we filter the
  # `message` text to error-severity tokens — verified to cut e.g. nginx noise 4.8M -> ~14.
  # Returns [{ index:, error_count:, top_vms: [{vm,count}], samples: [..] }], worst-first.
  def fetch_error_summary(indices:, hours: 24, severity_terms: 'error crit alert emerg fatal exception', sample_size: 3)
    Array(indices).map do |index|
      body = error_query(hours: hours, severity_terms: severity_terms, sample_size: sample_size)
      resp = post("#{index}/_search", body)
      {
        index:       index,
        error_count: resp.dig('hits', 'total', 'value').to_i,
        top_vms:     (resp.dig('aggregations', 'by_vm', 'buckets') || []).map { |b| { vm: b['key'], count: b['doc_count'] } },
        samples:     (resp.dig('hits', 'hits') || []).map { |h| h.dig('_source', 'message').to_s.strip[0, 200] }
      }
    rescue => e
      warn "ELK error-scan failed for #{index}: #{e.message}"
      { index: index, error_count: 0, top_vms: [], samples: [], error: e.message }
    end.sort_by { |h| -h[:error_count] }
  end

  # Detects machines CURRENTLY stuck on a semaphore. Sidekiq workers log
  # "Semaphore lock request failed by ... for <lock_key>" when they can't acquire a lock, and
  # "Semaphore locked/unlocked by ... for <lock_key>" when they DO. A machine that fails a few
  # times but locks/unlocks in between is just contending — not stuck. We only flag a machine
  # when its MOST RECENT semaphore events (in the window) are >= min_tries failures in a row with
  # NO successful lock/unlock since — i.e. it is continuously failing and still unresolved now.
  # Returns [{ lock_key:, tries:, worker:, vm:, first_seen:, last_seen:, span_hours: }], worst-first.
  SEMAPHORE_FAIL_PHRASE = 'Semaphore lock request failed'.freeze

  def fetch_stuck_semaphores(hours: 24, min_tries: 4, index: 'factory-sidekiq-*', recent_events: 50)
    # 1. Candidate locks — anything that failed at least once in the window.
    fail_hits = post("#{index}/_search", {
      size:    1000,
      sort:    [{ '@timestamp' => { order: 'desc' } }],
      _source: %w[message vm_hostname @timestamp],
      query:   { bool: { must: [
        { range: { '@timestamp' => { gte: "now-#{hours}h" } } },
        { match_phrase: { message: SEMAPHORE_FAIL_PHRASE } }
      ] } }
    }).dig('hits', 'hits') || []

    candidates = {}
    fail_hits.each do |h|
      msg = h.dig('_source', 'message').to_s.strip
      next unless msg.include?(' for ')
      key = msg.split(' for ').last.strip
      next if key.empty?
      candidates[key] ||= { worker: msg[/(\w+(?:Worker|Generation))/, 1], vm: h.dig('_source', 'vm_hostname') }
    end

    # 2. For each candidate, walk its recent event stream newest-first and count the trailing
    #    run of consecutive failures, stopping at the first successful lock/unlock (= recovered).
    candidates.map do |key, meta|
      events = post("#{index}/_search", {
        size:    recent_events,
        sort:    [{ '@timestamp' => { order: 'desc' } }],
        _source: %w[message @timestamp],
        query:   { bool: { must: [
          { range: { '@timestamp' => { gte: "now-#{hours}h" } } },
          { match_phrase: { message: key } }
        ] } }
      }).dig('hits', 'hits') || []

      streak = []
      events.each do |e|
        m = e.dig('_source', 'message').to_s
        if m.include?('request failed')
          streak << e.dig('_source', '@timestamp')
        elsif m.include?('Semaphore locked') || m.include?('Semaphore unlocked')
          break # got the lock since — not stuck anymore
        end
      end
      next nil if streak.size < min_tries

      { lock_key: key, tries: streak.size, worker: meta[:worker], vm: meta[:vm],
        last_seen: streak.first, first_seen: streak.last,
        span_hours: span_hours(streak.last, streak.first) }
    end.compact.sort_by { |x| -x[:tries] }
  rescue => e
    warn "ELK semaphore-scan failed: #{e.message}"
    []
  end

  # Total slow op count across all collections for the period.
  def total_slow_ops(hours: 24, min_duration_ms: 100)
    body = {
      size:  0,
      query: time_and_duration_filter(hours: hours, min_duration_ms: min_duration_ms)
    }
    response = post("#{@index}/_search", body)
    response.dig('hits', 'total', 'value') || 0
  end

  private

  # ── Query builders ─────────────────────────────────────────────────────────────

  def top_offenders_query(hours:, min_duration_ms:, limit:)
    {
      size:  0,
      query: time_and_duration_filter(hours: hours, min_duration_ms: min_duration_ms),
      aggs: {
        by_query_hash: {
          terms: {
            field: 'query_hash',
            size:  limit,
            order: { avg_duration: 'desc' }
          },
          aggs: {
            avg_duration:   { avg:         { field: 'duration_ms' } },
            max_duration:   { max:         { field: 'duration_ms' } },
            p95_duration:   { percentiles: { field: 'duration_ms', percents: [95] } },
            avg_scan_ratio: { avg:         { field: 'scan_ratio' } },
            total_ops:      { value_count: { field: 'query_hash' } },
            avg_docs_examined: { avg:      { field: 'docs_examined' } },
            avg_docs_returned: { avg:      { field: 'docs_returned' } },
            collection:  { terms: { field: 'collection',   size: 1 } },
            plan_summary:{ terms: { field: 'plan_summary', size: 1 } },
            needs_index: { terms: { field: 'needs_index',  size: 1 } },
            command_type:{ terms: { field: 'command_type', size: 1 } },
            # Grab one real query for RCA context (truncated later)
            sample: {
              top_hits: {
                size: 1,
                _source: %w[query collection license_key database],
                sort: [{ duration_ms: { order: 'desc' } }]
              }
            }
          }
        }
      }
    }
  end

  def collection_summary_query(hours:, min_duration_ms:)
    {
      size:  0,
      query: time_and_duration_filter(hours: hours, min_duration_ms: min_duration_ms),
      aggs: {
        by_collection: {
          terms: {
            field: 'collection',
            size:  10,
            order: { total_duration: 'desc' }
          },
          aggs: {
            total_duration:    { sum: { field: 'duration_ms' } },
            avg_duration:      { avg: { field: 'duration_ms' } },
            max_duration:      { max: { field: 'duration_ms' } },
            avg_docs_examined: { avg: { field: 'docs_examined' } }
          }
        }
      }
    }
  end

  def span_hours(first, last)
    return 0 unless first && last
    ((Time.parse(last) - Time.parse(first)) / 3600.0).round(1)
  rescue
    0
  end

  def error_query(hours:, severity_terms:, sample_size:)
    {
      size:             sample_size,
      track_total_hits: true,
      sort:             [{ '@timestamp' => { order: 'desc' } }],
      _source:          %w[message vm_hostname],
      query: {
        bool: {
          must: [
            { range: { '@timestamp' => { gte: "now-#{hours}h" } } },
            { match: { message: { query: severity_terms, operator: 'or' } } }
          ]
        }
      },
      aggs: { by_vm: { terms: { field: 'vm_hostname.keyword', size: 5 } } }
    }
  end

  def time_and_duration_filter(hours:, min_duration_ms:)
    {
      bool: {
        must: [
          { range: { '@timestamp' => { gte: "now-#{hours}h" } } },
          { range: { duration_ms:  { gte: min_duration_ms } } },
          { exists: { field: 'collection' } }
        ]
      }
    }
  end

  # ── Response parsers ───────────────────────────────────────────────────────────

  def parse_offenders(response)
    buckets = response.dig('aggregations', 'by_query_hash', 'buckets') || []
    buckets.map do |b|
      avg_ms     = b.dig('avg_duration', 'value')
      scan_ratio = b.dig('avg_scan_ratio', 'value')

      sample_meta = extract_sample_meta(b)
      {
        query_hash:        b['key'],
        collection:        b.dig('collection',   'buckets', 0, 'key'),
        plan_summary:      b.dig('plan_summary',  'buckets', 0, 'key'),
        needs_index:       b.dig('needs_index',   'buckets', 0, 'key'),
        command_type:      b.dig('command_type',  'buckets', 0, 'key'),
        avg_duration_ms:   avg_ms&.round(1),
        max_duration_ms:   b.dig('max_duration',  'value')&.round(1),
        p95_duration_ms:   b.dig('p95_duration',  'values', '95.0')&.round(1),
        avg_scan_ratio:    scan_ratio&.round(1),
        total_ops:         b.dig('total_ops',     'value').to_i,
        avg_docs_examined: b.dig('avg_docs_examined', 'value')&.round(0),
        avg_docs_returned: b.dig('avg_docs_returned', 'value')&.round(0),
        sample_query:      sample_meta[:query],
        pipeline_stages:   sample_meta[:pipeline_stages],
        query_type:        sample_meta[:query_type],
        field_paths:       sample_meta[:field_paths],
        app_name:          sample_meta[:app_name],
        license_key_count: sample_meta[:license_key_count],
        severity:          classify_severity(avg_ms)
      }
    end
  end

  def parse_collection_summary(response)
    buckets = response.dig('aggregations', 'by_collection', 'buckets') || []
    buckets.map do |b|
      {
        collection:        b['key'],
        slow_op_count:     b['doc_count'].to_i,
        avg_duration_ms:   b.dig('avg_duration',      'value')&.round(1),
        max_duration_ms:   b.dig('max_duration',      'value')&.round(1),
        avg_docs_examined: b.dig('avg_docs_examined', 'value')&.round(0)
      }
    end
  end

  # Extracts query text, app_name, and license_key_count from the sample hit.
  # For getMore queries uses originatingCommand so Claude sees the real filter.
  def extract_sample_meta(bucket)
    raw = bucket.dig('sample', 'hits', 'hits', 0, '_source', 'query')
    return { query: nil, app_name: nil, license_key_count: nil } unless raw

    parsed = JSON.parse(raw) rescue nil
    return { query: raw[0, 2000], app_name: nil, license_key_count: nil } unless parsed

    attr     = parsed['attr'] || {}
    app_name = attr['appName']

    # For getMore, the real filter is in originatingCommand — use that for RCA
    cmd = attr['originatingCommand'] || attr['command'] || {}

    filter   = cmd['filter'] || cmd['pipeline']&.first&.dig('$match') || {}
    lk_val   = filter['license_key']
    lk_count = case lk_val
               when Hash   then lk_val['$in']&.size  # {"$in": [...]} — multi-tenant
               when String then 1                     # plain string — single tenant
               end

    full_cmd_json = JSON.generate(cmd)
    query_for_rca = full_cmd_json[0, 2000]

    # Extract pipeline stages from the FULL cmd before truncation so manifest matching
    # doesn't miss late stages ($group, $facet) that fall past the 2000-char cutoff.
    stage_re = /\$(match|lookup|unwind|group|project|facet|sort|addFields|replaceRoot|count)\b/
    pipeline_stages = full_cmd_json.scan(stage_re).flatten.map { |s| "$#{s}" }.uniq

    # Same idea for CONTENT matching: pull the `type` partition value and the dotted field
    # paths from the FULL cmd, so the RCA matcher compares the query's real fields (including
    # energy_consumption_cost, energy_co2_emission, …) even when they fall past the cutoff.
    query_type  = full_cmd_json[/["']type["']\s*:\s*["']([a-z0-9_]+)["']/i, 1]
    field_paths = full_cmd_json.scan(/\$?([a-zA-Z_][a-zA-Z0-9_]*(?:\.[a-zA-Z0-9_]+)+)/).flatten.uniq

    {
      query:             query_for_rca,
      app_name:          app_name,
      license_key_count: lk_count,
      pipeline_stages:   pipeline_stages,
      query_type:        query_type,
      field_paths:       field_paths
    }
  rescue
    { query: nil, app_name: nil, license_key_count: nil, pipeline_stages: [], query_type: nil, field_paths: [] }
  end

  # ── Severity ───────────────────────────────────────────────────────────────────

  def classify_severity(avg_ms)
    return 'UNKNOWN' unless avg_ms
    case avg_ms
    when 10_000.. then 'CRITICAL'
    when 1_000..  then 'HIGH'
    else               'MEDIUM'
    end
  end

  # ── HTTP ───────────────────────────────────────────────────────────────────────

  def post(path, body)
    url      = "#{@host}/#{path}"
    response = HTTParty.post(
      url,
      headers: {
        'Authorization' => "ApiKey #{@api_key}",
        'Content-Type'  => 'application/json'
      },
      body:    body.to_json,
      timeout: 30
    )
    unless response.success?
      raise "ELK request failed [#{response.code}]: #{response.body[0, 300]}"
    end
    JSON.parse(response.body)
  end
end
