require 'httparty'
require 'json'

# Pulls per-VM health from Prometheus (node_exporter) for the infra section of the digest.
# Reports PEAK and AVERAGE over a trailing window (default 24h, matching the ELK log lookback)
# rather than a single instant — so the email reflects the whole audit period. Read-only; returns
# [] on any failure so a Prometheus outage never breaks the audit.
class PrometheusClient
  # Base instant expressions (current value per instance). The *_over_time wrappers turn these
  # into windowed peak/avg via subqueries: (expr)[<window>:<step>].
  CPU_BASE  = '100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])))'.freeze
  MEM_BASE  = '100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)'.freeze
  DISK_BASE = '100 * max by (instance) (1 - node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs"})'.freeze

  def initialize(config)
    @host        = config && config['host']
    @token       = config && config['auth_token']
    @range_hours = (config && config['range_hours']) || 24
    @step        = (config && config['step']) || '10m'
  end

  def configured?
    !@host.to_s.empty?
  end

  # Returns [{ vm:, cpu_peak:, cpu_avg:, mem_peak:, mem_avg:, disk_peak:, disk_avg:,
  #            load1_peak:, load1_avg: }, ...] over the trailing window, worst-first (by peak).
  def vm_health
    return [] unless configured?

    win = "#{@range_hours}h"
    cpu_peak  = instant("max_over_time((#{CPU_BASE})[#{win}:#{@step}])")
    cpu_avg   = instant("avg_over_time((#{CPU_BASE})[#{win}:#{@step}])")
    mem_peak  = instant("max_over_time((#{MEM_BASE})[#{win}:#{@step}])")
    mem_avg   = instant("avg_over_time((#{MEM_BASE})[#{win}:#{@step}])")
    disk_peak = instant("max_over_time((#{DISK_BASE})[#{win}:#{@step}])")
    disk_avg  = instant("avg_over_time((#{DISK_BASE})[#{win}:#{@step}])")
    load_peak = instant("max_over_time(node_load1[#{win}])")
    load_avg  = instant("avg_over_time(node_load1[#{win}])")

    vms = cpu_peak.keys | mem_peak.keys | disk_peak.keys | load_peak.keys
    vms.map do |vm|
      {
        vm: vm,
        cpu_peak:  cpu_peak[vm],  cpu_avg:  cpu_avg[vm],
        mem_peak:  mem_peak[vm],  mem_avg:  mem_avg[vm],
        disk_peak: disk_peak[vm], disk_avg: disk_avg[vm],
        load1_peak: load_peak[vm], load1_avg: load_avg[vm]
      }
    end.sort_by { |h| -[h[:cpu_peak], h[:mem_peak], h[:disk_peak]].compact.max.to_f }
  rescue => e
    warn "PrometheusClient: vm_health failed — #{e.message}"
    []
  end

  # Bundle of dashboard-style panels for the digest. Each is guarded so one failure can't
  # break the others or the audit.
  def dashboards
    return {} unless configured?
    {
      sidekiq_performance: safe { sidekiq_performance },
      sidekiq_queues:      safe { sidekiq_queues },
      mongo_performance:   safe { mongo_performance },
      mongo_utilisation:   safe { mongo_utilisation }
    }
  end

  # Sidekiq throughput/health over the window. processed/failed are counters → use increase().
  def sidekiq_performance
    win = "#{@range_hours}h"
    {
      busy_workers:       single('sum(sidekiq_busy_workers)').to_i,
      throughput_per_min: (single('sum(rate(sidekiq_processed_jobs_total[5m]))') * 60).round,
      processed_window:   single("sum(increase(sidekiq_processed_jobs_total[#{win}]))").to_i,
      failed_window:      single("sum(increase(sidekiq_failed_jobs_total[#{win}]))").to_i,
      dead:               single('sum(sidekiq_dead_jobs)').to_i,
      retry:              single('sum(sidekiq_retry_jobs)').to_i,
      scheduled:          single('sum(sidekiq_scheduled_jobs)').to_i
    }
  end

  # Per-queue backlog + wait time, worst-first (longest queue / highest latency).
  def sidekiq_queues
    enq  = by_label('sidekiq_queue_enqueued_jobs', 'name')
    lat  = by_label('sidekiq_queue_latency_seconds', 'name')
    busy = by_label('sidekiq_queue_busy_workers', 'name')
    (enq.keys | lat.keys | busy.keys).map do |name|
      { queue: name, enqueued: enq[name].to_i, latency_s: (lat[name] || 0).round(1), busy: busy[name].to_i }
    end.sort_by { |q| [-q[:enqueued], -q[:latency_s]] }
  end

  # Slowest collections by avg read latency over the window, with their read load.
  def mongo_performance(top: 8)
    win = "#{@range_hours}h"
    lat = query_series("topk(#{top}, rate(mongodb_collstats_latencyStats_reads_latency[#{win}]) / rate(mongodb_collstats_latencyStats_reads_ops[#{win}]))")
    ops = {}
    query_series("rate(mongodb_collstats_latencyStats_reads_ops[#{win}])").each { |s| ops[coll_key(s[:labels])] = s[:value] }
    lat.map do |s|
      { collection: s[:labels]['collection'], db: s[:labels]['database'],
        read_latency_us: s[:value].round, read_ops_sec: (ops[coll_key(s[:labels])] || 0).round(2) }
    end.sort_by { |c| -c[:read_latency_us] }
  end

  # Disk usage per replica set + the largest databases by data/index size (primary only).
  def mongo_utilisation(top: 6)
    disk = query_series('100 * max by (rs_nm) (mongodb_dbstats_fsUsedSize{rs_state="1"} / mongodb_dbstats_fsTotalSize{rs_state="1"})')
    dbs  = query_series(%(topk(#{top}, max by (database) (mongodb_dbstats_dataSize{rs_state="1"}))))
    idx  = {}
    query_series('max by (database) (mongodb_dbstats_indexSize{rs_state="1"})').each { |s| idx[s[:labels]['database']] = s[:value] }
    {
      disk:    disk.map { |s| { rs: s[:labels]['rs_nm'], used_pct: s[:value].round(1) } }.sort_by { |d| -d[:used_pct] },
      top_dbs: dbs.map  { |s| db = s[:labels]['database']; { db: db, data_gb: (s[:value] / 1e9).round(2), index_gb: ((idx[db] || 0) / 1e9).round(2) } }.sort_by { |d| -d[:data_gb] }
    }
  end

  private

  def safe
    yield
  rescue => e
    warn "PrometheusClient: panel failed — #{e.message}"
    nil
  end

  def coll_key(labels)
    [labels['database'], labels['collection']]
  end

  # Instant query → array of { labels:, value: } for every series.
  def query_series(promql)
    resp = HTTParty.get(
      "#{@host}/api/v1/query",
      query:   { query: promql },
      headers: @token ? { 'Authorization' => "Bearer #{@token}" } : {},
      timeout: 30
    )
    return [] unless resp.success?
    (JSON.parse(resp.body).dig('data', 'result') || []).map { |r| { labels: r['metric'] || {}, value: r.dig('value', 1).to_f } }
  rescue => e
    warn "PrometheusClient: query_series failed (#{promql[0, 50]}...) — #{e.message}"
    []
  end

  # Instant query expected to return a single value → Float (0.0 if absent).
  def single(promql)
    query_series(promql).first&.fetch(:value, 0.0) || 0.0
  end

  # Instant query grouped by one label → { label_value => value }.
  def by_label(promql, label)
    query_series(promql).each_with_object({}) { |s, acc| acc[s[:labels][label]] = s[:value] if s[:labels][label] }
  end

  # Runs an instant PromQL query, returns { instance => rounded_value }.
  def instant(promql)
    resp = HTTParty.get(
      "#{@host}/api/v1/query",
      query:   { query: promql },
      headers: @token ? { 'Authorization' => "Bearer #{@token}" } : {},
      timeout: 30
    )
    return {} unless resp.success?

    result = JSON.parse(resp.body).dig('data', 'result') || []
    result.each_with_object({}) do |r, acc|
      inst = r.dig('metric', 'instance')
      val  = r.dig('value', 1)
      acc[inst] = val.to_f.round(1) if inst && val
    end
  rescue => e
    warn "PrometheusClient: query failed (#{promql[0, 50]}...) — #{e.message}"
    {}
  end
end
