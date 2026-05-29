require 'httparty'
require 'json'

# Track 3 — Root Cause Analysis Engine
# Step 1: Rule-based classification (deterministic, instant)
# Step 2: Claude AI for plain-English diagnosis + fix suggestion (HIGH/CRITICAL only)
class RcaEngine
  ANTHROPIC_URL = 'https://api.anthropic.com/v1/messages'
  MODEL         = 'claude-sonnet-4-6'

  SYSTEM_PROMPT = <<~PROMPT.freeze
    You are a MongoDB performance expert for a Ruby manufacturing platform (DFX by Altizon).
    Given slow query metrics, return ONLY a valid JSON object with these exact keys:
    {
      "root_cause": "one concise sentence explaining why the query is slow",
      "fix_description": "one sentence describing the fix",
      "index_suggestion": "db.collection.create_index(...) command string, or null",
      "pipeline_rewrite": "plain string description of pipeline rewrite, or null"
    }
    STRICT RULES:
    - Return only the JSON object — no markdown, no code fences, no explanation outside the JSON.
    - All values must be plain strings or null — no nested objects, no arrays.
    - Never use ISODate(), ObjectId(), or any MongoDB shell syntax inside the JSON values.
    - Date references in strings must use ISO 8601 format (e.g. "2025-06-11T00:00:00Z").
  PROMPT

  def initialize(config)
    @api_key = config&.fetch('api_key', nil)
    @model   = config&.fetch('model', MODEL) || MODEL
  end

  # Enriches the finding hash in-place with RCA fields.
  # Returns the finding.
  def diagnose(finding)
    finding[:root_cause_type] = classify(finding)
    return finding unless @api_key && %w[CRITICAL HIGH].include?(finding[:severity])

    ai_result = call_claude(finding)
    finding.merge!(ai_result.transform_keys(&:to_sym)) if ai_result
    finding
  end

  private

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
      max_tokens: 512,
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
    parse_claude_json(text)
  rescue => e
    warn "RCA Claude API error: #{e.message}"
    nil
  end

  def parse_claude_json(text)
    cleaned = text.gsub(/```json\n?|\n?```/, '').strip
    JSON.parse(cleaned)
  rescue JSON::ParserError
    # Claude returned non-JSON syntax (e.g. ISODate) — extract the safe fields via regex
    result = {}
    %w[root_cause fix_description index_suggestion pipeline_rewrite].each do |key|
      match = cleaned.match(/"#{key}"\s*:\s*"((?:[^"\\]|\\.)*)"/m)
      result[key] = match ? match[1].gsub('\\"', '"') : nil
    end
    result.any? { |_, v| v } ? result : nil
  end

  def build_user_prompt(finding)
    <<~PROMPT
      Collection:       #{finding[:collection]}
      Command type:     #{finding[:command_type]}
      Avg duration:     #{finding[:avg_duration_ms]}ms
      Max duration:     #{finding[:max_duration_ms]}ms
      Avg scan ratio:   #{finding[:avg_scan_ratio]} (docs examined / docs returned)
      Avg docs examined:#{finding[:avg_docs_examined]}
      Plan summary:     #{finding[:plan_summary]}
      Needs index:      #{finding[:needs_index]}
      Rule diagnosis:   #{finding[:root_cause_type]}

      Sample query (truncated):
      #{finding[:sample_query]&.slice(0, 1500) || 'unavailable'}
    PROMPT
  end
end
