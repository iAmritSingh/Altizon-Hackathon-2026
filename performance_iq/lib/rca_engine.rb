require 'httparty'
require 'json'

# Track 3 — Root Cause Analysis Engine
# Step 1: Rule-based classification (deterministic, instant)
# Step 2: Codebase enrichment (existing indexes + candidate pipeline — from manifests, ZERO extra tokens to build)
# Step 3: Claude AI for plain-English diagnosis + fix suggestion (HIGH/CRITICAL only)
class RcaEngine
  ANTHROPIC_URL = 'https://api.anthropic.com/v1/messages'
  MODEL         = 'claude-sonnet-4-6'

  # System prompt is CACHED (ephemeral) — charged once, cache-read for every other finding.
  # So all the heavy domain knowledge lives here, cheaply.
  SYSTEM_PROMPT = <<~PROMPT.freeze
    You are the RCA engine for PerformanceIQ, an automated performance system for
    DFX by Altizon — a multi-tenant manufacturing IoT platform on Rails + Mongoid (MongoDB).

    ## Your data source: LOGS, not a live database
    You are given metrics aggregated from MongoDB slow-query LOGS (shipped to Elasticsearch),
    covering ONE query shape over the last 24h. You do NOT have live DB access. Reason ONLY
    from the signals provided. The strongest signal is `plan_summary`:
      - "COLLSCAN" => no index was used at all.
      - "IXSCAN { ...keys... }" => an index WAS used; if scan_ratio is still high it exists but
        is not selective enough. Do NOT call an index "missing" when plan_summary shows IXSCAN.

    ## Existing indexes may be provided
    When an `existing_indexes` list is given, it is the ACTUAL current indexes on that collection.
    NEVER suggest one that already exists or is a prefix of an existing one. Build on them.

    ## Candidate source pipeline may be provided
    When a `candidate_pipeline` excerpt is given, it is the most likely source aggregation for
    this query shape. Use it to ground `pipeline_rewrite`; if absent, leave pipeline_rewrite null.

    ## Hard rules for this codebase (a fix that breaks these is wrong)
    1. MULTI-TENANCY: collections are shared across tenants — a compound index MUST lead with `license_key`.
    2. INDEX ORDER = ESR: Equality keys first, then Sort keys, then Range keys (e.g. time from/to).
    3. SAFE CREATION: every create_index includes `background: true` and a short `name:`.
    4. NULLABILITY: only return index_suggestion when a missing/poor index is the cause. For
       aggregation-shape problems ($unwind blow-up, $lookup fan-out, $match not first), set
       index_suggestion: null and put the fix in pipeline_rewrite.

    ## You are given a deterministic rule diagnosis (computed from the same log metrics). Treat as a prior:
      MISSING_INDEX -> propose the ESR-correct compound index (respecting existing_indexes).
      POOR_INDEX_SELECTIVITY -> add the high-cardinality field to the index that ran.
      CARTESIAN_EXPANSION -> $unwind/$lookup fan-out; fix via $match-before-$lookup; index may stay null.
      HEAVY_AGGREGATION -> push $match first / reduce stages / add supporting index.
      FAAS_DATA_SCAN -> add date-partition filter + index on (license_key, <type>, from:-1).
    If the metrics contradict the rule diagnosis, trust the metrics and note it in root_cause.

    ## Output — return ONLY this JSON, no prose, no markdown fences:
    {
      "root_cause": "one precise sentence; cite the log signal (plan_summary / scan_ratio / docs_examined)",
      "fix_description": "one imperative sentence",
      "index_suggestion": "db.<collection>.create_index({...}, { background: true, name: '...' }) OR null",
      "pipeline_rewrite": "minimal corrected pipeline snippet OR null",
      "confidence": 0.0,
      "estimated_speedup": "e.g. 'scan ratio 8853 -> ~1' or '~40x'"
    }

    Confidence 0.0-1.0: be honest — you reason from logs, not an explain plan. High (>=0.8) only
    when plan_summary + scan_ratio clearly pinpoint the cause and the field to add is inferable.
    Lower it when the sample query is truncated or the selective field is a guess. Auto-PR only
    fires above 0.75.
  PROMPT

  MAX_PIPELINE_CHARS = 1500

  def initialize(config, rca_config = nil)
    @api_key = config&.fetch('api_key', nil)
    @model   = config&.fetch('model', MODEL) || MODEL

    manifests_dir = rca_config&.fetch('manifests_dir', nil) ||
                    File.join(__dir__, '..', 'manifests')
    @index_manifest    = load_manifest(File.join(manifests_dir, 'index_manifest.json'))
    @pipeline_manifest = load_manifest(File.join(manifests_dir, 'pipeline_manifest.json'))
  end

  # Enriches the finding hash in-place with RCA fields. Returns the finding.
  def diagnose(finding)
    finding[:root_cause_type] = classify(finding)
    return finding unless @api_key && %w[CRITICAL HIGH].include?(finding[:severity])

    enrich_from_codebase(finding) # cheap local lookup, no tokens
    ai_result = call_claude(finding)
    finding.merge!(symbolize(ai_result)) if ai_result
    finding
  end

  private

  # ── Manifest loading + codebase enrichment ──────────────────────────────────────

  def load_manifest(path)
    return {} unless File.exist?(path)
    JSON.parse(File.read(path))
  rescue => e
    warn "RCA manifest load failed (#{File.basename(path)}): #{e.message}"
    {}
  end

  # Attaches :existing_indexes and :candidate_pipeline to the finding (if found).
  def enrich_from_codebase(finding)
    collection = finding[:collection].to_s

    entry = @index_manifest[collection]
    finding[:existing_indexes] = entry['indexes'] if entry

    finding[:candidate_pipeline] = best_pipeline(collection, finding[:sample_query])
  end

  # Pick the single best-matching pipeline by stage-signature overlap with the logged query.
  def best_pipeline(collection, sample_query)
    candidates = @pipeline_manifest[collection]
    return nil if candidates.nil? || candidates.empty?

    query_stages = stages_in(sample_query.to_s)
    return nil if query_stages.empty? # plain find() — no pipeline to rewrite

    best = candidates.max_by do |c|
      sig = c['stage_signature'] || []
      overlap = (sig & query_stages).size
      # prefer higher overlap, then more specific (smaller) signatures
      [overlap, -sig.size]
    end

    sig = best['stage_signature'] || []
    return nil if (sig & query_stages).empty? # no shared stages -> not a real match

    {
      'function' => best['function'],
      'file'     => best['file'],
      'excerpt'  => best['pipeline_excerpt'].to_s.slice(0, MAX_PIPELINE_CHARS)
    }
  end

  STAGE_RE = /\$(match|lookup|unwind|group|project|facet|sort|addFields|replaceRoot|count)\b/.freeze

  def stages_in(text)
    text.scan(STAGE_RE).flatten.map { |s| "$#{s}" }.uniq
  end

  # ── Rule-based classifier ──────────────────────────────────────────────────────

  def classify(finding)
    scan_ratio  = finding[:avg_scan_ratio].to_f
    needs_index = finding[:needs_index]
    plan        = finding[:plan_summary].to_s
    collection  = finding[:collection].to_s
    command     = finding[:command_type].to_s
    avg_ms      = finding[:avg_duration_ms].to_f

    if scan_ratio > 100_000
      'CARTESIAN_EXPANSION'        # $unwind + post-filter, or $lookup without pipeline filter
    elsif plan.include?('COLLSCAN') || needs_index == true
      'MISSING_INDEX'              # no usable index at all
    elsif scan_ratio > 1_000
      'POOR_INDEX_SELECTIVITY'     # index exists but too broad
    elsif command == 'pipeline' && avg_ms > 5_000
      'HEAVY_AGGREGATION'          # complex $group / $facet / $lookup chain
    elsif collection == 'faas_data' && avg_ms > 1_000
      'FAAS_DATA_SCAN'             # FaasData without date partitioning
    else
      'SLOW_QUERY'
    end
  end

  # ── Claude API ────────────────────────────────────────────────────────────────

  def call_claude(finding)
    payload = {
      model:      @model,
      max_tokens: 600,
      system: [
        {
          type: 'text',
          text: SYSTEM_PROMPT,
          cache_control: { type: 'ephemeral' }  # cache system prompt across findings
        }
      ],
      messages: [
        { role: 'user', content: build_user_prompt(finding) }
      ]
    }

    response = HTTParty.post(
      ANTHROPIC_URL,
      headers: {
        'x-api-key'         => @api_key,
        'anthropic-version' => '2023-06-01',
        'content-type'      => 'application/json',
        'anthropic-beta'    => 'prompt-caching-2024-07-31'
      },
      body:    payload.to_json,
      timeout: 30
    )

    return nil unless response.success?

    text = response.dig('content', 0, 'text')
    JSON.parse(text.gsub(/```json\n?|\n?```/, '').strip)
  rescue => e
    warn "RCA Claude API error: #{e.message}"
    nil
  end

  def build_user_prompt(finding)
    prompt = +<<~PROMPT
      collection:        #{finding[:collection]}
      command_type:      #{finding[:command_type]}
      avg_duration_ms:   #{finding[:avg_duration_ms]}
      max_duration_ms:   #{finding[:max_duration_ms]}
      avg_scan_ratio:    #{finding[:avg_scan_ratio]}   # docs_examined / docs_returned
      avg_docs_examined: #{finding[:avg_docs_examined]}
      plan_summary:      #{finding[:plan_summary]}
      needs_index:       #{finding[:needs_index]}
      rule_diagnosis:    #{finding[:root_cause_type]}   # deterministic prior
      severity:          #{finding[:severity]}
    PROMPT

    if finding[:existing_indexes]
      prompt << "\nexisting_indexes (current indexes on #{finding[:collection]} — do not duplicate):\n"
      finding[:existing_indexes].each { |i| prompt << "  - #{i}\n" }
    end

    if (cp = finding[:candidate_pipeline])
      prompt << "\ncandidate_pipeline (likely source: #{cp['function']} in #{cp['file']}):\n"
      prompt << cp['excerpt']
      prompt << "\n"
    end

    prompt << "\nsample_query (from log, truncated):\n"
    prompt << (finding[:sample_query]&.slice(0, 1200) || 'unavailable')
    prompt
  end

  def symbolize(hash)
    hash.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
  end
end
