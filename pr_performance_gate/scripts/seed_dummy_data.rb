#!/usr/bin/env ruby
# Track 1 — Dummy data seeder for the explain() gate
#
# Seeds a THROWAWAY Mongo (e.g. the CI `mongo` service) with production-SCALE synthetic documents
# and the SAME indexes prod has, so explain(executionStats) reflects real scan behaviour without
# any prod/staging access. The gate compares PR vs baseline on this fixed dataset, so synthetic
# distribution need not match prod exactly — only the volume + indexes + field cardinality matter.
#
# What it controls (the only things that drive docs-examined): the indexed/filter fields
# (license_key, machine_key, type, from/to, properties.date) at realistic cardinality. Deep nested
# payload fields are stubbed minimally — they don't affect the index-scan cost the gate measures.
#
#   ruby seed_dummy_data.rb --mongo-url mongodb://localhost:27017/perf_gate \
#       --indexes .performance/indexes.json --spec .performance/seed_spec.json
#
# --spec example (per collection): how many docs + the cardinality of each filter field, and the
# fixture's query values are force-included so the gate's query actually matches.

require 'optparse'
require 'json'
require 'mongo'
require 'securerandom'

opts = { mongo_url: ENV['PERF_GATE_MONGO_URL'], indexes: '.performance/indexes.json', spec: '.performance/seed_spec.json' }
OptionParser.new do |o|
  o.on('--mongo-url U') { |v| opts[:mongo_url] = v }
  o.on('--indexes P')   { |v| opts[:indexes] = v }
  o.on('--spec P')      { |v| opts[:spec] = v }
end.parse!
abort 'need --mongo-url (or PERF_GATE_MONGO_URL)' unless opts[:mongo_url]

index_manifest = File.exist?(opts[:indexes]) ? JSON.parse(File.read(opts[:indexes])) : {}
spec           = JSON.parse(File.read(opts[:spec]))

Mongo::Logger.logger.level = Logger::WARN
client = Mongo::Client.new(opts[:mongo_url])

# Parse "{ license_key: 1, machine_key: 1, type: 1, from: -1 }" -> { 'license_key'=>1, ... }
def parse_index(str)
  str.gsub(/[{}]/, '').split(',').each_with_object({}) do |part, h|
    k, v = part.split(':').map(&:strip)
    h[k] = v.to_i unless k.to_s.empty?
  end
end

# Pick from a fixed pool so cardinality is controlled (a query for pool[0] matches ~count/pool docs).
def pool(prefix, n)
  Array.new(n) { |i| "#{prefix}_#{i}" }
end

spec.each do |collection, cfg|
  coll  = client[collection]
  coll.drop
  count = cfg['count'] || 200_000
  card  = cfg['cardinality'] || {}
  fixed = cfg['fixture_values'] || {}   # values the gate's query uses — guaranteed present

  lks   = (fixed['license_key'] ? [fixed['license_key']] : []) + pool('lk', card['license_key'] || 20)
  mks   = (fixed['machine_key'] ? [fixed['machine_key']] : []) + pool('mk', card['machine_key'] || 200)
  types = cfg['types'] || %w[pph_slot machine_slot operator_assignment part_opn_aggr]
  day0  = (fixed['date_from'] || 1_779_840_000).to_i
  span  = (cfg['date_span_days'] || 180)

  puts "Seeding #{collection}: #{count} docs (#{lks.size} license_keys, #{mks.size} machine_keys, #{types.size} types)..."
  batch = []
  count.times do |i|
    day = day0 + rand(span) * 86_400
    batch << {
      license_key:  lks.sample,
      machine_key:  mks.sample,
      machine_set_key: mks.sample,
      line_key:     mks.sample,
      type:         types.sample,
      from:         day, to: day + 3600,
      generic_object_id: SecureRandom.hex(6),
      created_at:   Time.at(day),
      properties:   { 'date' => day, 'shift_key' => "shift_#{rand(3)}", 'Electricity' => { 'kwh' => rand(1000) } }
    }
    if batch.size >= 5_000
      coll.insert_many(batch, ordered: false)
      batch = []
    end
  end
  coll.insert_many(batch, ordered: false) unless batch.empty?

  (index_manifest.dig(collection, 'indexes') || []).each do |idx_str|
    keys = parse_index(idx_str)
    next if keys.empty?
    coll.indexes.create_one(keys) rescue warn("  index #{idx_str} skipped: #{$!.message}")
  end
  puts "  done: #{coll.count_documents({})} docs, #{coll.indexes.to_a.size} indexes"
end

client.close
puts 'Seed complete.'
