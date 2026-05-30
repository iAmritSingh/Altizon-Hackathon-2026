require 'httparty'
require 'json'
require 'set'

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
    Treat them as FIXED — do not propose adding to or changing them. Use them as the target:
    restructure the query's $match so its leading equality fields line up with an existing
    index's prefix, so that index gets used and scans fewer documents.

    ## FIRST find the exact source function (candidate_source_functions)
    You are given a SHORTLIST of candidate functions (full bodies). They were pre-filtered by
    shape/type/field similarity, so they LOOK alike — but at most one truly generates the logged
    query, and sometimes none does. Before anything else, verify which one would actually produce
    the sample_query by comparing, for each candidate:
      - the $match `type` literal (must equal the query's type),
      - the $match field set (must line up with the query's $match fields),
      - the pipeline stages and their order (must correspond to the query's pipeline),
    treating the query's concrete values (machine_key:[...], dates) as the runtime form of the
    function's variables. Report your pick in `matched_function` (exact name) with one line of
    evidence in `match_evidence`. If NO candidate generates this query, set matched_function to
    "none" — do NOT force a match. Only ground a `pipeline_rewrite` in a function you confirmed;
    if matched_function is "none", set pipeline_rewrite null and only describe a generic
    query-structure fix in fix_description.

    ## Core doctrine: OPTIMISE THE QUERY — never create/alter indexes or schema
    The actionable fix is ALWAYS a query/pipeline rewrite. Do NOT propose creating or altering
    an index, and do NOT propose changing the document model/schema. These collections are
    huge, multi-tenant, and write-heavy; new indexes are expensive, can't be added for every
    query shape, and only mask the underlying query problem. Your job is to make the QUERY
    cheaper against the indexes that ALREADY exist.

    ## How to optimise a query (in order — pick the first that applies)
    1. PUT THE MOST SELECTIVE $match FIRST, and make it align with an EXISTING index prefix.
       If `existing_indexes` shows an index whose leading keys the query could match (e.g. it
       leads with license_key + machine_key + type), ensure the query's first $match supplies
       those fields as equality/$in so that index is actually used and scans less.
    2. PRE-FILTER BEFORE EXPANSION: add the post-$unwind / post-$lookup filter conditions into
       the FIRST $match too (as a non-lossy document-level superset) so $unwind/$lookup fan out
       far fewer rows. Keep the original post-stage $match for per-element precision.
    3. REMOVE FAN-OUT: eliminate unnecessary $unwind, convert correlated $lookup to a pipelined
       $lookup with its own $match, drop post-$unwind $match that should be pre-filters.
    4. NARROW THE WORK: project only needed fields early; cut redundant $project/$group stages.
    None of these require a new index or a schema change — they restructure the query itself.

    ## Multi-tenancy (context, not an instruction to index)
    Collections are shared across tenants, so every query MUST filter by `license_key` (and it
    should be the first equality key in the $match so the existing license_key-leading indexes
    are used). This is about how the QUERY is written, not about creating indexes.

    ## Cross-run history context
    ELK retains logs for only 2 days. PerformanceIQ maintains a 30-day local history store.
    You will receive `appearance_count` (how many past runs saw this query_hash) and
    `confirmed_slow` (true when it appeared in >= 2 distinct runs).
    - If confirmed_slow is false (appearance_count == 0): this is the FIRST time this shape
      was seen. It may be a transient infra event. Lower your confidence. Diagnose but note
      the query needs further observation before a PR is warranted.
    - If confirmed_slow is true: this is a real regression. Raise confidence accordingly.
    - If consecutive_runs >= 3: the regression is persistent and worsening — treat as CRITICAL
      regardless of the current run's severity label.

    ## You are given a deterministic rule diagnosis (computed from the same log metrics). Use it as a prior signal — not a prescription. Trust the full metrics and sample_query over the label if they conflict.

    ## What to produce — follow in order, stop at the first applicable level:
    1. PIPELINE / FUNCTION FIX (matched_function is a confirmed candidate):
       You confirmed which shortlisted function generates this query. Rewrite ITS pipeline
       structure using the query-optimisation techniques above (most-selective $match first
       aligned to an existing index, pre-filter before $unwind/$lookup, remove fan-out). The
       rewrite MUST be functionally equivalent — same results, only faster — and may only use
       variables/fields already present in that function. Describe it in pipeline_rewrite. This
       triggers an Auto-PR — be precise. index_suggestion stays null.

    2. QUERY OPTIMISATION (matched_function is "none"):
       No shortlisted function generates this query. Reason from the raw filter/pipeline in
       sample_query, plan_summary, app_name, and license_key_count to understand what the query
       is doing and why it is slow, then describe the minimal query restructure that eliminates
       the scan in fix_description. Leave pipeline_rewrite null (no confirmed code to rewrite).

    Even when plan_summary is COLLSCAN, the fix is to restructure the query so it can use an
    EXISTING index (reorder/supply the leading match fields), NOT to create a new one.
    If the metrics contradict the rule diagnosis, trust the metrics and note it in root_cause.

    ## Output — return ONLY this JSON object. No prose, no markdown fences, no code blocks.
    {
      "matched_function": "exact name of the candidate that generates this query, or \"none\"",
      "match_evidence": "one line: which $match type/fields and stages line up (or why none fit)",
      "root_cause": "one precise TECHNICAL sentence citing the key log signal (for engineers)",
      "fix_description": "one imperative TECHNICAL sentence describing the query/pipeline restructure",
      "impact_summary": "PLAIN-ENGLISH, non-technical: what is slow and why it matters, in business terms a manager would understand. No jargon (no 'index', 'scan ratio', '$unwind', 'IXSCAN'). Mention the user-facing effect and the wait time. e.g. 'The energy dashboard is slow to load (about 25 seconds) because the system sifts through far more records than it needs each time someone opens it.'",
      "fix_summary": "PLAIN-ENGLISH, non-technical: what the fix does and the expected improvement, no jargon. e.g. 'We reorganised how this report fetches its data so it only looks at the records it actually needs — this should make the dashboard load almost instantly.' Use null only when there is genuinely no fix.",
      "index_suggestion": "ALMOST ALWAYS null. At most a SHORT plain-English advisory that a DBA could LATER evaluate whether an index helps (e.g. 'if this shape persists, a DBA could assess an index covering license_key+machine_key+properties.date') — NEVER a create_index/createIndex command, never DDL, never presented as the fix.",
      "pipeline_rewrite": "one plain-English sentence describing the query/pipeline change, or null when matched_function is none",
      "confidence": 0.85,
      "estimated_speedup": "e.g. 'scan ratio 41M -> ~1' or '~200x'"
    }

    CRITICAL OUTPUT RULES:
    - Your reply MUST begin with the character { and end with } — NO reasoning, prose, or
      "json" label before or after the object. Do all reasoning silently.
    - The actionable fix is ALWAYS the query/pipeline rewrite. NEVER recommend creating or
      altering an index or schema as the fix; index_suggestion is advisory-only and usually null.
    - NEVER output create_index, createIndex, ensureIndex, or any DDL anywhere in the response.
    - pipeline_rewrite must be a SHORT PLAIN ENGLISH DESCRIPTION — NOT code, NOT a Ruby hash, NOT multi-line.
    - All JSON string values must fit on one line. Never include literal newlines inside a string value.
    - Confidence 0.0-1.0: high (>=0.8) only when signals clearly pinpoint the cause. Auto-PR fires above 0.75.
  PROMPT

  MAX_PIPELINE_CHARS = 6000 # full method body — the fix generator needs var scope + assembly, not just the stages

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

    enrich_from_codebase(finding) # cheap local lookup, no tokens — builds the candidate shortlist
    ai_result = call_claude(finding)
    finding.merge!(symbolize(ai_result)) if ai_result

    # The LLM picked which shortlisted function ACTUALLY generates this query (or "none").
    # Ground the fix on that confirmed source — never on the heuristic's raw top-1.
    finding[:candidate_pipeline] = resolve_confirmed_source(finding)

    # Generate the actual Ruby patch only when the source was CONFIRMED by the LLM, a rewrite
    # was proposed, and confidence clears the bar. No confirmed source => advisory only, no PR.
    # finding[:patch_skip_reason] records WHY a PR wasn't raised, surfaced in the run summary.
    if finding[:candidate_pipeline].nil?
      finding[:patch_skip_reason] = 'no source function confirmed in codebase (advisory only)'
    elsif finding[:pipeline_rewrite].to_s.empty?
      finding[:patch_skip_reason] = 'no query rewrite proposed'
    elsif finding[:confidence].to_f < 0.75
      finding[:patch_skip_reason] = "confidence #{(finding[:confidence].to_f * 100).round}% below 75% threshold"
    else
      finding[:code_patch] = generate_code_fix(finding)
    end

    finding
  end

  # Maps the LLM's matched_function answer back to the shortlist entry it confirmed. Returns nil
  # when the LLM found no real source ("none") — which routes the finding to advisory-only.
  def resolve_confirmed_source(finding)
    name = finding[:matched_function].to_s.strip
    return nil if name.empty? || name.casecmp?('none')
    (finding[:candidate_shortlist] || []).find { |c| c['function'] == name }
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

  # Attaches :existing_indexes, :candidate_shortlist, and :functions_with_same_pattern to the
  # finding. The shortlist is the heuristic's best guesses; the LLM confirms the real source.
  def enrich_from_codebase(finding)
    collection = finding[:collection].to_s

    entry = @index_manifest[collection]
    finding[:existing_indexes] = entry['indexes'] if entry

    finding[:candidate_shortlist] = shortlist_pipelines(collection, finding)

    # Count how many distinct functions share the same stage pattern on this collection.
    # Claude uses this to decide whether an index is broadly justified or the caller should be fixed.
    finding[:functions_with_same_pattern] = count_similar_functions(collection, finding)
  end

  # Count functions that plausibly share this query shape — same stage pattern AND not a
  # different document class. The partition-key gate (see #conflicting_type?) is what keeps
  # this honest: structurally-identical pipelines on a DIFFERENT `type` are not "the same
  # pattern", so they don't inflate the count that justifies a broad index.
  def count_similar_functions(collection, finding)
    candidates = @pipeline_manifest[collection]
    return 0 if candidates.nil? || candidates.empty?

    query_stages = query_stages_for(finding)
    return 0 if query_stages.empty? # plain find() — no pipeline stages to match against

    q_type = query_type_for(finding)
    candidates.count do |c|
      sig = c['stage_signature'] || []
      next false if (sig & query_stages).size < 2
      !conflicting_type?(q_type, match_type(c['pipeline_excerpt']))
    end
  end

  SHORTLIST_SIZE = 5

  # Build a SHORTLIST of the most plausible source functions for the logged query — the LLM
  # then reads their full bodies and confirms which one (if any) actually generates it. This is
  # CONTENT-aware, not just stage-shape-aware: many functions share the same
  # [$match,$project,$unwind,$group] shape while operating on entirely different documents.
  # Ranking signals, in priority order:
  #   1. type partition match — `generic_events` et al. partition by a literal `type`; a
  #      function whose `type` literal CONFLICTS with the query's is disqualified outright
  #      (it physically cannot be the source), and a matching `type` ranks above an unknown one.
  #   2. shared field paths — how many of the same dotted fields (properties.date,
  #      properties.energy_consumption_cost, …) both the query and the function reference.
  #   3. stage overlap / Dice — the original structural signal, now only a tie-breaker.
  # Returns [] when nothing is even plausibly related, so the LLM reasons from the raw query.
  def shortlist_pipelines(collection, finding)
    candidates = @pipeline_manifest[collection]
    return [] if candidates.nil? || candidates.empty?

    query_stages = query_stages_for(finding)
    return [] if query_stages.empty? # plain find() — no pipeline to rewrite

    q_type   = query_type_for(finding)
    q_tokens = query_tokens_for(finding)

    scored = candidates.map { |c| score_candidate(c, query_stages, q_type, q_tokens) }.compact
    return [] if scored.empty? # every candidate either shared no stages or had a conflicting type

    scored
      .sort_by { |s| [-s[:type_rank], -s[:token_overlap], -s[:stage_overlap], -s[:stage_dice]] }
      .first(SHORTLIST_SIZE)
      .map do |s|
        c = s[:candidate]
        {
          'function'    => c['function'],
          'file'        => c['file'],
          'excerpt'     => c['pipeline_excerpt'].to_s.slice(0, MAX_PIPELINE_CHARS),
          'match_basis' => s[:basis] # heuristic reason it was shortlisted — shown to the LLM
        }
      end
  end

  # Scores one manifest function against the logged query. Returns nil to DISQUALIFY the
  # candidate (no shared stages, or a conflicting partition type), otherwise a score hash.
  def score_candidate(candidate, query_stages, q_type, q_tokens)
    sig = candidate['stage_signature'] || []
    stage_overlap = (sig & query_stages).size
    return nil if stage_overlap.zero? # no structural relationship at all

    c_type = match_type(candidate['pipeline_excerpt'])
    return nil if conflicting_type?(q_type, c_type) # different document class — cannot be the source

    stage_dice    = 2.0 * stage_overlap / (sig.size + query_stages.size)
    token_overlap = (q_tokens & content_tokens(candidate['pipeline_excerpt'])).size
    type_rank     = (q_type && c_type && q_type == c_type) ? 1 : 0

    basis = []
    basis << "type=#{q_type}"            if type_rank == 1
    basis << "#{token_overlap} fields"   if token_overlap.positive?
    basis << "#{stage_overlap}/#{query_stages.size} stages"

    {
      candidate:     candidate,
      type_rank:     type_rank,
      token_overlap: token_overlap,
      stage_overlap: stage_overlap,
      stage_dice:    stage_dice,
      basis:         basis.join(', ')
    }
  end

  STAGE_RE = /\$(match|lookup|unwind|group|project|facet|sort|addFields|replaceRoot|count)\b/.freeze

  # Literal `type` partition value — matches both query JSON ("type":"x") and Ruby excerpt
  # ("type" => "x"). nil when type is absent (e.g. qualities/workorders) or built dynamically.
  TYPE_LITERAL_RE = /["']type["']\s*(?::|=>)\s*["']([a-z0-9_]+)["']/i.freeze

  # Dotted field paths the query/excerpt touches (leading $ stripped). These let us compare
  # WHICH fields each side reads — properties.date, properties.energy_consumption_cost, etc.
  FIELD_PATH_RE = /\$?([a-zA-Z_][a-zA-Z0-9_]*(?:\.[a-zA-Z0-9_]+)+)/.freeze

  def stages_in(text)
    text.scan(STAGE_RE).flatten.map { |s| "$#{s}" }.uniq
  end

  def match_type(text)
    m = text.to_s.match(TYPE_LITERAL_RE)
    m && m[1]
  end

  def content_tokens(text)
    text.to_s.scan(FIELD_PATH_RE).flatten.to_set
  end

  # True only when BOTH sides declare a literal type and they differ. Unknown/dynamic type on
  # either side is not a conflict — we fall back to field + stage signals in that case.
  def conflicting_type?(q_type, c_type)
    q_type && c_type && q_type != c_type
  end

  # Prefer pre-extracted full stages (set by elk_client before 2000-char truncation).
  # Falls back to parsing sample_query so existing tests stay compatible.
  def query_stages_for(finding)
    ps = finding[:pipeline_stages]
    return ps if ps && !ps.empty?
    stages_in(finding[:sample_query].to_s)
  end

  # Query's `type` partition value — prefer elk_client's full-cmd extraction (sees fields past
  # the 2000-char sample cutoff); fall back to parsing the truncated sample_query.
  def query_type_for(finding)
    finding[:query_type] || match_type(finding[:sample_query])
  end

  # Query's referenced field paths — same full-cmd-preferred, sample-query-fallback strategy.
  def query_tokens_for(finding)
    fp = finding[:field_paths]
    return fp.to_set if fp && !fp.empty?
    content_tokens(finding[:sample_query])
  end

  # ── Rule-based classifier ──────────────────────────────────────────────────────

  def classify(finding)
    scan_ratio  = finding[:avg_scan_ratio].to_f
    needs_index = finding[:needs_index]
    plan        = finding[:plan_summary].to_s
    collection  = finding[:collection].to_s
    command     = finding[:command_type].to_s
    avg_ms      = finding[:avg_duration_ms].to_f
    app_name    = finding[:app_name].to_s
    lk_count    = finding[:license_key_count].to_i

    if app_name == 'mongoexport' || (command == 'getMore' && lk_count > 1)
      'CROSS_TENANT_EXPORT'        # CLI/ETL export querying multiple tenants at once
    elsif scan_ratio > 100_000
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
      max_tokens: 1024,
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
    parse_response(text)
  rescue => e
    warn "RCA Claude API error: #{e.message}"
    nil
  end

  def parse_response(text)
    cleaned = text.to_s.gsub(/```json\n?|```/, '').strip
    # Sonnet often prepends reasoning ("Looking at the sample_query...") and a bare `json`
    # line before the object. Isolate the outermost {...} block so leading prose is dropped.
    if (start = cleaned.index('{')) && (finish = cleaned.rindex('}')) && finish > start
      cleaned = cleaned[start..finish]
    end

    parsed = try_parse_json(cleaned)
    return parsed if parsed

    # Last resort: pull out each field individually via regex.
    result = {}
    %w[matched_function match_evidence root_cause fix_description impact_summary fix_summary index_suggestion pipeline_rewrite confidence estimated_speedup].each do |key|
      m = cleaned.match(/"#{key}"\s*:\s*(?:"((?:[^"\\]|\\.)*)"|([0-9.]+)|null)/m)
      next unless m
      result[key] = m[2] ? m[2].to_f : m[1]&.gsub('\\"', '"')
    end
    result.any? { |_, v| v } ? result : nil
  end

  # Parse JSON, tolerating literal newlines inside string values (which Claude sometimes emits
  # in pipeline_rewrite). Returns the hash or nil — never raises (so the regex fallback runs).
  def try_parse_json(str)
    JSON.parse(str)
  rescue JSON::ParserError
    escaped = str.gsub(/("(?:[^"\\]|\\.)*")/m) { |m| m.gsub("\n", '\n').gsub("\r", '') }
    begin
      JSON.parse(escaped)
    rescue JSON::ParserError
      nil
    end
  end

  def build_user_prompt(finding)
    prompt = +<<~PROMPT
      collection:          #{finding[:collection]}
      command_type:        #{finding[:command_type]}
      app_name:            #{finding[:app_name] || 'factory_application'}
      license_key_count:   #{finding[:license_key_count] || 1}   # tenants queried in one request
      avg_duration_ms:     #{finding[:avg_duration_ms]}
      max_duration_ms:     #{finding[:max_duration_ms]}
      avg_scan_ratio:      #{finding[:avg_scan_ratio]}   # docs_examined / docs_returned
      avg_docs_examined:   #{finding[:avg_docs_examined]}
      plan_summary:        #{finding[:plan_summary]}
      needs_index:         #{finding[:needs_index]}
      rule_diagnosis:      #{finding[:root_cause_type]}   # deterministic prior
      severity:            #{finding[:severity]}
    PROMPT

    if (n = finding[:functions_with_same_pattern])
      prompt << "\nfunctions_with_same_pattern: #{n}  # distinct functions sharing this query pattern on #{finding[:collection]}\n"
      prompt << "# Use this to judge index vs code fix: index justified only when >= 3 AND no pipeline fix is possible.\n"
    end

    # Cross-run history context — helps distinguish real regressions from infra blips.
    if finding[:appearance_count]
      prompt << "\n# Cross-run history (ELK only retains 2 days; this store persists 30 days):\n"
      prompt << "appearance_count: #{finding[:appearance_count]}  # times this query_hash appeared in past runs\n"
      prompt << "confirmed_slow:   #{finding[:confirmed_slow]}    # true = appeared in >= 2 distinct runs (real regression, not a blip)\n"
      if finding[:consecutive_runs].to_i >= 2
        prompt << "consecutive_runs: #{finding[:consecutive_runs]}  # appeared in this many consecutive runs — escalate priority\n"
      end
      prompt << "avg_ms_history:   #{finding[:avg_ms_history]}  # rolling average across past runs (nil = first time seen)\n" if finding[:avg_ms_history]
    end

    if finding[:existing_indexes]
      prompt << "\nexisting_indexes (current indexes on #{finding[:collection]} — do not duplicate):\n"
      finding[:existing_indexes].each { |i| prompt << "  - #{i}\n" }
    end

    if (shortlist = finding[:candidate_shortlist]) && !shortlist.empty?
      prompt << "\ncandidate_source_functions — #{shortlist.size} functions whose shape/type/fields\n"
      prompt << "resemble the logged query. EXACTLY ONE, or NONE, is the true source. Identify the one\n"
      prompt << "that would actually GENERATE the sample_query below — compare each function's $match\n"
      prompt << "`type` value, $match fields, and pipeline stages to the sample_query (the query's\n"
      prompt << "concrete values like machine_key:[...] are the runtime form of the function's variables).\n"
      prompt << "Set matched_function to that function's exact name, or \"none\" if no function here\n"
      prompt << "generates this query. Only propose a pipeline_rewrite when matched_function is not none.\n"
      shortlist.each_with_index do |c, i|
        prompt << "\n[#{i + 1}] #{c['function']}  (in #{c['file']}; heuristic: #{c['match_basis']})\n"
        prompt << c['excerpt']
        prompt << "\n"
      end
    end

    prompt << "\nsample_query (the ACTUAL logged query — match candidates against THIS):\n"
    prompt << (finding[:sample_query]&.slice(0, 1500) || 'unavailable')
    prompt
  end

  def symbolize(hash)
    hash.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
  end

  MAX_FIX_ATTEMPTS = 2

  # Second Claude call: rewrites the actual Ruby pipeline. If the rewrite trips the safety guard,
  # we retry ONCE with the specific violation as feedback (rather than dropping the fix entirely).
  # Returns { 'file', 'function', 'old_excerpt', 'new_excerpt' } or nil (no safe patch).
  def generate_code_fix(finding)
    return nil unless @api_key
    cp = finding[:candidate_pipeline]
    return nil unless cp
    old_excerpt = cp['excerpt'].to_s.strip
    return nil if old_excerpt.empty?

    messages = [{ role: 'user', content: code_fix_prompt(finding, cp, old_excerpt) }]

    last_violation = nil
    MAX_FIX_ATTEMPTS.times do |attempt|
      new_excerpt = call_code_model(messages)
      if new_excerpt.to_s.empty?
        finding[:patch_skip_reason] = 'code-fix generation returned nothing'
        return nil
      end
      if new_excerpt == old_excerpt
        finding[:patch_skip_reason] = 'LLM found no safe equivalent rewrite (returned code unchanged)'
        return nil
      end

      violation = rewrite_violation(old_excerpt, new_excerpt, finding)
      unless violation
        return {
          'file'        => cp['file'],
          'function'    => cp['function'],
          'old_excerpt' => old_excerpt,
          'new_excerpt' => new_excerpt
        }
      end

      last_violation = violation
      warn "RCA: rewrite attempt #{attempt + 1}/#{MAX_FIX_ATTEMPTS} for #{cp['function']} rejected — #{violation}"
      # Feed the violation back for one corrective retry.
      messages << { role: 'assistant', content: new_excerpt }
      messages << { role: 'user', content: <<~FEEDBACK }
        That rewrite is NOT safe: #{violation}.
        Produce a functionally-equivalent rewrite that improves ONLY performance, using just the
        variables and fields already present in the original method. If no such safe rewrite is
        possible, output the ORIGINAL method UNCHANGED.
      FEEDBACK
    end

    finding[:patch_skip_reason] = "rewrite failed safety check after #{MAX_FIX_ATTEMPTS} attempts — #{last_violation}"
    nil
  rescue => e
    warn "RCA code-fix generation error: #{e.message}"
    finding[:patch_skip_reason] = "code-fix error: #{e.message}"
    nil
  end

  # Builds the initial rewrite prompt (full method + hard safety rules).
  def code_fix_prompt(finding, cp, old_excerpt)
    <<~PROMPT
      You are rewriting a Ruby aggregation pipeline to fix a MongoDB performance issue.

      Collection : #{finding[:collection]}
      Fix needed : #{finding[:pipeline_rewrite]}
      Root cause : #{finding[:root_cause]}
      Source     : #{cp['function']} in #{cp['file']}

      Rewrite the code below to apply exactly the fix described — but ONLY if you can do
      so without changing what the query returns. This is a performance fix, not a
      behaviour change.

      HARD SAFETY RULES (a rewrite that breaks any of these is WRONG — return the code
      UNCHANGED instead):
      - FUNCTIONAL EQUIVALENCE: the pipeline must return the exact same documents/values,
        just faster. Never add a filter condition that removes results the original kept.
      - NO NEW STAGES THAT FAN OUT: never add a $lookup or a $unwind. Those increase work;
        they never fix a scan/fan-out problem.
      - ONLY use variables, fields, and collections that ALREADY APPEAR in the code below.
        Never invent a variable (e.g. a map/list from another method) — if the fix needs
        something not defined here, you cannot do it safely: return the code unchanged.
      - SAFE TRANSFORMS ONLY: reorder $match to come first; move a filter that already
        exists LATER in this same pipeline UP into the first $match as a non-lossy
        pre-filter (keeping the later one too); drop a redundant stage. Nothing else.
      - Keep the pipeline assembly intact: if stages are assembled into an array/variable
        (e.g. aggregate([s1, s2, s3])), any stage you add MUST be wired into that same
        assembly — never leave a dangling fragment.
      - Output ONLY the modified Ruby code. No explanations, no markdown fences.
      - Preserve all surrounding indentation and Ruby style exactly. Do not add or remove
        method definitions.
      - If you cannot produce a SAFE, equivalent speedup from the code shown, output the
        original code UNCHANGED (this signals "no patch").

      Full method (rewrite within this; the result replaces it verbatim):
      #{old_excerpt}
    PROMPT
  end

  # Calls the model for a code rewrite and returns the stripped text (or nil).
  def call_code_model(messages)
    response = HTTParty.post(
      ANTHROPIC_URL,
      headers: {
        'x-api-key'         => @api_key,
        'anthropic-version' => '2023-06-01',
        'content-type'      => 'application/json'
      },
      body:    { model: @model, max_tokens: 2048, messages: messages }.to_json,
      timeout: 90
    )
    return nil unless response.success?
    response.dig('content', 0, 'text')&.strip
  end

  # Mongo operator / Ruby keyword tokens that are not "variables" — excluded from the
  # new-identifier check so adding e.g. a $match doesn't look like an invented variable.
  CODE_STOPWORDS = %w[
    match lookup unwind group project facet sort addfields replaceroot count
    in gte gt lte lt ne eq exists and or not nin expr cond ifnull sum push first
    map collect each select reject to_i to_a utc present nil true false def end do
    if unless then else elsif return pipeline aggregate collection from to as let path
  ].to_set.freeze

  # Guard against the failure modes seen in production PRs. Returns a human-readable violation
  # string (used as retry feedback), or nil when the rewrite is safe.
  def rewrite_violation(old_code, new_code, finding)
    # 1. Never add fan-out stages — they cannot be a performance fix.
    return 'you added a $lookup stage (joins/fan out — never a speedup)'  if new_code.scan(/\$lookup\b/).size > old_code.scan(/\$lookup\b/).size
    return 'you added a $unwind stage (fans out rows — never a speedup)'  if new_code.scan(/\$unwind\b/).size > old_code.scan(/\$unwind\b/).size
    # For a cartesian / fan-out root cause, also forbid adding $facet expansion.
    if finding[:root_cause_type] == 'CARTESIAN_EXPANSION' && new_code.scan(/\$facet\b/).size > old_code.scan(/\$facet\b/).size
      return 'you added a $facet stage to a fan-out query'
    end

    # 2. No invented identifiers: every variable/method name in the rewrite must already exist
    #    in the original code (safe transforms only reuse what's there). Catches references to
    #    vars defined in other methods (the #20892 parameter_map class of bug).
    new_ids = code_identifiers(new_code) - code_identifiers(old_code)
    return "you referenced identifier(s) not present in the original: #{new_ids.to_a.sort.join(', ')}" unless new_ids.empty?

    # 3. No newly range-filtered field: adding a $gte/$lte on a field the original did not range
    #    on changes which documents match (the #20896 from/to bug). Moving an existing $in/equality
    #    filter earlier — the safe transform — adds no new range field, so this won't flag it.
    new_ranges = range_fields(new_code) - range_fields(old_code)
    return "you added a range filter ($gte/$lte) on field(s) the original did not range-filter: #{new_ranges.to_a.sort.join(', ')} (this changes which documents match)" unless new_ranges.empty?

    nil
  end

  IDENTIFIER_RE = /[a-z_][a-z0-9_]*/.freeze

  # Lower-case identifier tokens that are NOT mongo operators / ruby keywords (i.e. plausible
  # variables, fields, and method names). Field names inside string keys are included on
  # purpose — a rewrite shouldn't reference a field the original never touched.
  def code_identifiers(code)
    code.scan(IDENTIFIER_RE).reject { |t| CODE_STOPWORDS.include?(t) }.to_set
  end

  # Field names that are range-filtered ("field" => { ... $gte/$gt/$lte/$lt ... }) in the code.
  RANGE_FIELD_RE = /["']([a-zA-Z_][\w.]*)["']\s*=>\s*\{[^{}]*\$(?:gte|gt|lte|lt)\b/.freeze

  def range_fields(code)
    code.scan(RANGE_FIELD_RE).flatten.to_set
  end
end
