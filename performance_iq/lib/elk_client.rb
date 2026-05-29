require 'httparty'
require 'json'

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
        sample_query:      extract_sample_query(b),
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

  # Pull the raw query string from the sample hit and truncate it safely.
  def extract_sample_query(bucket)
    raw = bucket.dig('sample', 'hits', 'hits', 0, '_source', 'query')
    return nil unless raw

    parsed = JSON.parse(raw) rescue nil
    return raw[0, 2000] unless parsed

    # Extract just the pipeline/filter part to keep Claude prompt concise
    attr = parsed.dig('attr', 'command') || parsed
    JSON.generate(attr)[0, 2000]
  rescue
    nil
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
