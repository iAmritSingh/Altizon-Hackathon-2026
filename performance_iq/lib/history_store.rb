require 'json'
require 'fileutils'

# Persistent cross-run query history — survives ELK's 2-day retention window.
#
# Each run appends its findings to data/query_history.jsonl (one JSON line per finding).
# On the next run, findings are enriched with appearance_count, first_seen, trend.
#
# This lets us distinguish:
#   - Confirmed slow  (appeared in >= 2 runs) → real regression, full RCA + PR candidate
#   - Transient slow  (appeared once)          → infra blip candidate, track but lower confidence
#   - Recurring slow  (N consecutive runs)     → escalate severity regardless of ELK window
class HistoryStore
  DATA_FILE      = File.join(__dir__, '..', 'data', 'query_history.jsonl')
  RETENTION_DAYS = 30

  def initialize(path = DATA_FILE)
    @path = path
    FileUtils.mkdir_p(File.dirname(@path))
    @records = load_records
  end

  # How many distinct past runs we have on record.
  def run_count
    @records.map { |r| r['run_date'] }.uniq.size
  end

  # Enrich a finding hash in-place with historical context. Returns the finding.
  #
  # Adds:
  #   :appearance_count  — how many past runs logged this query_hash (not counting today)
  #   :first_seen        — ISO date string of first appearance
  #   :avg_ms_history    — rolling average of avg_duration_ms across past runs
  #   :confirmed_slow    — true when appeared in >= 2 distinct runs (not an infra blip)
  #   :consecutive_runs  — how many consecutive recent runs included this hash
  def enrich(finding)
    hash = finding[:query_hash].to_s
    past = @records.select { |r| r['query_hash'] == hash }

    finding[:appearance_count] = past.size
    finding[:first_seen]       = past.map { |r| r['run_date'] }.min
    finding[:avg_ms_history]   = avg_of(past.map { |r| r['avg_ms'] })
    finding[:confirmed_slow]   = past.map { |r| r['run_date'] }.uniq.size >= 2
    finding[:consecutive_runs] = consecutive_tail(@records, hash)

    finding
  end

  # Persist this run's findings to the JSONL file.
  # Call AFTER the run completes so history reflects what was actually observed.
  def record(findings, run_date: Time.now.strftime('%Y-%m-%d'))
    File.open(@path, 'a') do |f|
      findings.each do |finding|
        f.puts JSON.generate(
          run_date:    run_date,
          query_hash:  finding[:query_hash],
          collection:  finding[:collection],
          avg_ms:      finding[:avg_duration_ms],
          scan_ratio:  finding[:avg_scan_ratio],
          severity:    finding[:severity],
          plan_summary: finding[:plan_summary]
        )
      end
    end
    prune_old_records
  end

  # Returns all distinct query hashes seen in past runs but NOT in the current findings list.
  # These are queries that vanished — either fixed or a transient infra event.
  def vanished_since(current_findings)
    current_hashes = current_findings.map { |f| f[:query_hash].to_s }.to_set
    @records.map { |r| r['query_hash'] }
            .uniq
            .reject { |h| current_hashes.include?(h) }
            .map { |h| past_for(h) }
  end

  private

  def load_records
    return [] unless File.exist?(@path)

    cutoff = cutoff_date
    File.readlines(@path, chomp: true).filter_map do |line|
      next if line.strip.empty?
      r = JSON.parse(line) rescue nil
      r if r && r['run_date'] >= cutoff
    end
  end

  def prune_old_records
    return unless File.exist?(@path)

    cutoff = cutoff_date
    kept = File.readlines(@path, chomp: true).select do |line|
      next false if line.strip.empty?
      r = JSON.parse(line) rescue nil
      r && r['run_date'] >= cutoff
    end
    File.write(@path, kept.join("\n") + (kept.empty? ? '' : "\n"))
  end

  def cutoff_date
    (Time.now - RETENTION_DAYS * 86_400).strftime('%Y-%m-%d')
  end

  def avg_of(values)
    return nil if values.empty?
    (values.sum.to_f / values.size).round(1)
  end

  # Count how many of the most-recent consecutive run_dates include this hash.
  def consecutive_tail(all_records, hash)
    run_dates = all_records.map { |r| r['run_date'] }.uniq.sort.reverse
    return 0 if run_dates.empty?

    hash_dates = all_records.select { |r| r['query_hash'] == hash }
                            .map { |r| r['run_date'] }.to_set
    count = 0
    run_dates.each do |d|
      break unless hash_dates.include?(d)
      count += 1
    end
    count
  end

  def past_for(hash)
    rows = @records.select { |r| r['query_hash'] == hash }
    {
      query_hash:       hash,
      collection:       rows.last&.dig('collection'),
      appearance_count: rows.size,
      first_seen:       rows.map { |r| r['run_date'] }.min,
      last_seen:        rows.map { |r| r['run_date'] }.max,
      avg_ms_history:   avg_of(rows.map { |r| r['avg_ms'] })
    }
  end
end
