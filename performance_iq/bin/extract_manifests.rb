#!/usr/bin/env ruby
# frozen_string_literal: true
#
# PerformanceIQ — Manifest Extractor (PHASE 1, deterministic, ZERO Claude tokens)
#
# Parses the factory + mint-content codebases ONCE and boils them down to two
# compact JSON lookups that the RCA engine reads at diagnose-time:
#
#   index_manifest.json     collection -> existing Mongoid indexes  (kills duplicate /
#                                                                     wrong-ESR suggestions)
#   pipeline_manifest.json  collection -> candidate aggregation pipelines (unlocks
#                                                                          pipeline_rewrite)
#
# The repos are NEVER fed to Claude. Only the tiny matched slice of these manifests is.
#
# Usage:
#   ruby bin/extract_manifests.rb \
#     --factory      /path/to/factory \
#     --mint-content /path/to/mint-content \
#     --out          manifests
#
# Re-run whenever the repos change (cache by repo SHA in CI).

require 'json'
require 'optparse'
require 'find'

# ── Inflector (Mongoid default collection naming: ClassName -> collection) ───────

UNCOUNTABLE = %w[data info equipment series].freeze

def underscore(camel)
  camel.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
       .gsub(/([a-z\d])([A-Z])/, '\1_\2')
       .downcase
end

def pluralize_word(word)
  return word if UNCOUNTABLE.include?(word)

  case word
  when /(s|x|z|ch|sh)$/ then "#{word}es"
  when /[^aeiou]y$/     then "#{word[0..-2]}ies"
  else                       "#{word}s"
  end
end

# ClassName -> Mongoid default collection name (pluralize the last token only).
def collection_for(class_name)
  parts = underscore(class_name).split('_')
  parts[-1] = pluralize_word(parts[-1])
  parts.join('_')
end

# ── Brace-balanced extraction of the first {...} group after a marker ────────────

def first_brace_group(line, start_at)
  open = line.index('{', start_at)
  return nil unless open

  depth = 0
  open.upto(line.length - 1) do |i|
    depth += 1 if line[i] == '{'
    depth -= 1 if line[i] == '}'
    return line[open..i] if depth.zero?
  end
  nil # unbalanced on this line (rare for index specs)
end

# ── Manifest 1 — existing indexes per collection ─────────────────────────────────

def extract_index_manifest(factory_root)
  manifest = {}
  models_dir = File.join(factory_root, 'app', 'models')
  return manifest unless Dir.exist?(models_dir)

  Find.find(models_dir) do |path|
    next unless path.end_with?('.rb')

    src = File.read(path, encoding: 'UTF-8', invalid: :replace, undef: :replace)
    next unless src.include?('Mongoid::Document')

    class_match = src.match(/^\s*class\s+([A-Z]\w*)/)
    next unless class_match

    class_name = class_match[1]

    # Explicit override wins; else derive Mongoid default.
    store_in = src.match(/store_in\s+collection:\s*['"]([^'"]+)['"]/)
    collection = store_in ? store_in[1] : collection_for(class_name)

    indexes = []
    src.each_line do |line|
      stripped = line.strip
      next unless stripped.start_with?('index(')
      next if stripped.start_with?('#')

      spec = first_brace_group(line, line.index('index(') + 'index('.length)
      indexes << spec.gsub(/\s+/, ' ').strip if spec
    end

    next if indexes.empty?

    manifest[collection] = {
      'class'      => class_name,
      'model_file' => path.sub("#{factory_root}/", ''),
      'indexes'    => indexes
    }
  end

  manifest
end

# ── Manifest 2 — candidate aggregation pipelines per collection ──────────────────

STAGE_RE = /\$(match|lookup|unwind|group|project|facet|sort|addFields|replaceRoot|count)\b/.freeze
PIPELINE_HINT_RE = /\.aggregate\b|\$match|\$lookup|\$unwind|\$group/.freeze
MAX_EXCERPT_LINES = 200

def stages_in(text)
  text.scan(STAGE_RE).flatten.map { |s| "$#{s}" }.uniq
end

# Split a file's lines into per-method chunks at `def` boundaries.
# Returns array of { name:, lines: } hashes.
def split_into_methods(lines)
  methods = []
  current_name = nil
  current_lines = []

  lines.each do |line|
    if (m = line.match(/^\s*def\s+([a-z_][a-z0-9_]*)/))
      methods << { name: current_name, lines: current_lines } if current_name && !current_lines.empty?
      current_name = m[1]
      current_lines = [line]
    else
      current_lines << line
    end
  end
  methods << { name: current_name, lines: current_lines } if current_name && !current_lines.empty?

  # Also include a synthetic "top-level" chunk for files without def (simple script functions)
  if methods.empty?
    methods << { name: nil, lines: lines }
  end

  methods
end

# Capture the WHOLE method, not just a window around the $-stage markers. The fix generator
# needs the full body to see variable definitions (e.g. parameter_map), the pipeline assembly
# (e.g. aggregate([s1, s2, s3])), and the method boundary — without these it hallucinates
# fragments that are never wired in or references vars from sibling methods. We start from the
# method signature (or two lines before the first stage for def-less chunks) through the last
# stage's closing context, capped generously.
def extract_pipeline_excerpt(lines)
  marker_idxs = lines.each_index.select { |i| lines[i] =~ STAGE_RE }
  return nil if marker_idxs.empty?

  def_idx = lines.each_index.find { |i| lines[i] =~ /^\s*def\s/ }
  first   = def_idx || [marker_idxs.first - 2, 0].max
  # Extend past the last stage to the pipeline-assembly / aggregate call when it follows closely.
  assembly_idx = lines.each_index.select { |i| lines[i] =~ /\.aggregate\b/ }.find { |i| i >= marker_idxs.last }
  last    = [marker_idxs.last + 2, assembly_idx || 0, lines.length - 1].compact.max
  last    = lines.length - 1 if last > lines.length - 1

  window = lines[first..last]
  window = window.first(MAX_EXCERPT_LINES) if window.length > MAX_EXCERPT_LINES
  window.join
end

def extract_pipeline_manifest(roots, known_collections)
  # word -> collection, so a class reference in a function maps back to a collection.
  class_to_coll = {}
  known_collections.each { |coll, meta| class_to_coll[meta['class']] = coll }

  manifest = Hash.new { |h, k| h[k] = [] }

  roots.each do |root|
    next unless root && Dir.exist?(root)

    Find.find(root) do |path|
      # Only Ruby function/report sources; skip specs, vendor, hidden dirs.
      Find.prune if File.basename(path).start_with?('.')
      next unless path.end_with?('.rb')
      next if path.end_with?('_spec.rb')

      src = File.read(path, encoding: 'UTF-8', invalid: :replace, undef: :replace)
      next unless src =~ PIPELINE_HINT_RE

      lines = src.lines
      rel_path = path.sub("#{root}/", '')
      file_basename = File.basename(path, '.rb')

      # Which collections does this file touch? (by referenced model class)
      collections = class_to_coll.keys.select { |cls| src =~ /\b#{Regexp.escape(cls)}\b/ }
                                 .map { |cls| class_to_coll[cls] }
      src.scan(/\.collection\(['"]([a-z_]+)['"]\)/).flatten.each { |c| collections << c }
      collections.uniq!
      next if collections.empty?

      # One manifest entry per method — prevents a 60-line cap from hiding a later method
      # that contains the actual problematic pipeline (e.g. bqi_index_report.rb has both
      # create_inspection_bookings_pipeline AND create_inspection_bookings_pipeline_checker).
      split_into_methods(lines).each do |method|
        method_lines = method[:lines]
        next unless method_lines.join =~ PIPELINE_HINT_RE

        signature = stages_in(method_lines.join)
        next if signature.empty?

        excerpt = extract_pipeline_excerpt(method_lines)
        next unless excerpt

        fn_name = method[:name] ? "#{file_basename}##{method[:name]}" : file_basename
        entry = {
          'function'         => fn_name,
          'file'             => rel_path,
          'stage_signature'  => signature,
          'pipeline_excerpt' => excerpt
        }
        collections.each { |coll| manifest[coll] << entry }
      end
    end
  end

  manifest
end

# ── Main ─────────────────────────────────────────────────────────────────────────

options = { out: 'manifests', factory_branch: 'rel_7.0', mint_content_branch: 'master' }
OptionParser.new do |o|
  o.banner = 'Usage: ruby bin/extract_manifests.rb --factory PATH [--factory-branch BRANCH] ' \
             '[--mint-content PATH] [--mint-content-branch BRANCH] [--out DIR]'
  o.on('--factory PATH')               { |v| options[:factory] = v }
  o.on('--factory-branch BRANCH')      { |v| options[:factory_branch] = v }
  o.on('--mint-content PATH')          { |v| options[:mint_content] = v }
  o.on('--mint-content-branch BRANCH') { |v| options[:mint_content_branch] = v }
  o.on('--out DIR')                    { |v| options[:out] = v }
end.parse!

abort 'ERROR: --factory PATH is required' unless options[:factory]
abort "ERROR: factory path not found: #{options[:factory]}" unless Dir.exist?(options[:factory])

require 'fileutils'
FileUtils.mkdir_p(options[:out])

# Checkout the requested branch in-place (non-destructive — switches back on exit if needed).
def checkout_branch(repo_path, branch, label)
  return unless branch

  current = `git -C "#{repo_path}" rev-parse --abbrev-ref HEAD`.strip
  if current == branch
    puts "  #{label}: already on branch #{branch}"
    return
  end

  result = system("git -C \"#{repo_path}\" checkout #{branch} --quiet 2>&1")
  if result
    puts "  #{label}: switched to branch #{branch}"
  else
    abort "ERROR: could not checkout branch '#{branch}' in #{repo_path}"
  end
end

checkout_branch(options[:factory],      options[:factory_branch],      'factory')
checkout_branch(options[:mint_content], options[:mint_content_branch], 'mint-content') if options[:mint_content]

puts 'PerformanceIQ Manifest Extractor'
puts "  factory      : #{options[:factory]}#{options[:factory_branch] ? " (branch: #{options[:factory_branch]})" : ''}"
puts "  mint-content : #{options[:mint_content] ? "#{options[:mint_content]}#{options[:mint_content_branch] ? " (branch: #{options[:mint_content_branch]})" : ''}" : '(skipped)'}"
puts "  out          : #{options[:out]}\n\n"

puts 'Extracting index manifest from Mongoid models...'
index_manifest = extract_index_manifest(options[:factory])
index_path = File.join(options[:out], 'index_manifest.json')
File.write(index_path, JSON.pretty_generate(index_manifest))
puts "  #{index_manifest.size} collections with indexes -> #{index_path}\n\n"

puts 'Extracting pipeline manifest from functions...'
roots = [options[:mint_content], File.join(options[:factory], 'lib', 'reports')].compact
pipeline_manifest = extract_pipeline_manifest(roots, index_manifest)
pipeline_path = File.join(options[:out], 'pipeline_manifest.json')
File.write(pipeline_path, JSON.pretty_generate(pipeline_manifest))
total_pipes = pipeline_manifest.values.sum(&:size)
puts "  #{pipeline_manifest.size} collections, #{total_pipes} candidate pipelines -> #{pipeline_path}\n\n"

puts 'Done.'
