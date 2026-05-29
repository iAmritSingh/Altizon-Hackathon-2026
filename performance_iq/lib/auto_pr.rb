require 'octokit'
require 'base64'

# Track 4 — Auto-PR Bot
# Raises a PR to mint-content when the RCA engine produced a code_patch (actual pipeline rewrite).
# Index-only suggestions skip the PR — they appear in the audit email digest instead.
class AutoPr
  LABEL_NAME  = 'PerformanceIQ'.freeze
  LABEL_COLOR = '1f6feb'.freeze # GitHub blue

  def initialize(config)
    @token             = config&.fetch('access_token', nil)
    @mint_content_repo = config&.fetch('mint_content_repo', nil)
    @base_branch       = config&.fetch('base_branch', 'master')
    @client            = Octokit::Client.new(access_token: @token) if @token
  end

  # Raises a mint-content PR when a pipeline code fix was generated.
  # Index-only suggestions are surfaced in the audit email, not as PRs.
  # Returns the PR URL string, or nil when skipped / on error.
  def raise_pr(finding)
    return warn 'AutoPr: no GitHub token configured' unless @client
    return unless finding[:code_patch]

    raise_mint_content_pr(finding)
  end

  private

  # ── Mint-content PR: edits the actual Ruby pipeline function ─────────────────

  def raise_mint_content_pr(finding)
    unless @mint_content_repo
      warn 'AutoPr: mint_content_repo not configured — skipping pipeline fix PR'
      return nil
    end

    patch      = finding[:code_patch]
    file_path  = patch['file']
    old_code   = patch['old_excerpt']
    new_code   = patch['new_excerpt']

    branch = branch_name(file_path)

    # mint-content uses a PERSISTENT branch per function (ccci-staging/<file-path>). We add our
    # fix as a new commit on top of that branch's head (the "New Commits added to ..." flow), or
    # create it from master when it doesn't exist yet. Either way the commit fast-forwards.
    base_sha = resolve_branch_head(branch)

    # IMPORTANT: read + patch the file from MASTER, not from the branch. The manifest (and thus
    # the anchor Claude rewrote against) is built from master; a staging branch can carry
    # functionally-identical but byte-divergent content (e.g. reordered $match keys), which
    # would break the exact-string anchor match. We commit master's patched file onto the branch.
    github_file  = @client.contents(@mint_content_repo, path: file_path, ref: @base_branch)
    file_content = Base64.decode64(github_file.content)

    # Bail if Claude's excerpt no longer appears in master (file changed since manifest build)
    unless file_content.include?(old_code)
      warn "AutoPr: patch anchor not found in #{file_path} on #{@base_branch} — manifest may be stale, skipping"
      return nil
    end

    # Transparency: note when the branch's version differs from the master version we're patching.
    if branch_diverges_from_master?(branch, file_path, file_content)
      warn "AutoPr: #{file_path} on #{branch} differs from master — committing master's patched version"
    end

    new_content = file_content.sub(old_code, new_code)

    blob_sha   = @client.create_blob(@mint_content_repo, Base64.strict_encode64(new_content), 'base64')
    tree_sha   = @client.create_tree(
      @mint_content_repo,
      [{ path: file_path, mode: '100644', type: 'blob', sha: blob_sha }],
      base_tree: base_sha
    ).sha
    commit_sha = @client.create_commit(
      @mint_content_repo,
      "perf: fix #{finding[:collection]} pipeline scan ratio [PerformanceIQ]",
      tree_sha,
      base_sha
    ).sha
    @client.update_ref(@mint_content_repo, "heads/#{branch}", commit_sha)

    pr = existing_pr(branch) || @client.create_pull_request(
      @mint_content_repo,
      @base_branch,
      branch,
      mint_pr_title(branch),
      mint_pr_body(finding, patch)
    )
    apply_label(pr)
    pr.html_url
  rescue => e
    warn "AutoPr mint-content error (#{finding[:collection]}): #{e.message}"
    nil
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  def head_sha(repo)
    @client.ref(repo, "heads/#{@base_branch}").object.sha
  end

  # mint-content branch convention: ccci-staging/<file path without the .rb extension>,
  # e.g. iprod/functions/default/foo.rb -> ccci-staging/iprod/functions/default/foo
  def branch_name(file_path)
    "ccci-staging/#{file_path.to_s.sub(/\.rb\z/, '')}"
  end

  # True when the branch's copy of the file differs from the master version we're patching.
  # Used only to log a transparency note; never blocks the PR.
  def branch_diverges_from_master?(branch, file_path, master_content)
    f = @client.contents(@mint_content_repo, path: file_path, ref: branch)
    Base64.decode64(f.content) != master_content
  rescue Octokit::NotFound
    false # file not on branch yet (branch just created from master)
  end

  # Current head of the function branch if it exists; otherwise create it from master and
  # return master's head. Either way the returned SHA is a valid parent for our commit.
  def resolve_branch_head(branch)
    @client.ref(@mint_content_repo, "heads/#{branch}").object.sha
  rescue Octokit::NotFound
    base = head_sha(@mint_content_repo)
    @client.create_ref(@mint_content_repo, "refs/heads/#{branch}", base)
    base
  end

  # Reuse an already-open PR for this branch instead of failing on a duplicate. Returns the PR
  # object (so it can be labelled), or nil when none is open.
  def existing_pr(branch)
    owner = @mint_content_repo.split('/').first
    @client.pull_requests(@mint_content_repo, state: 'open', head: "#{owner}:#{branch}").first
  rescue
    nil
  end

  # Tag the PR with the PerformanceIQ label so these auto-raised PRs are filterable. Creates the
  # label on first use. Never fails the PR — labelling is best-effort.
  def apply_label(pr)
    return unless pr
    ensure_label_exists
    @client.add_labels_to_an_issue(@mint_content_repo, pr.number, [LABEL_NAME])
  rescue => e
    warn "AutoPr: could not label PR ##{pr.number} with '#{LABEL_NAME}': #{e.message}"
  end

  def ensure_label_exists
    @client.label(@mint_content_repo, LABEL_NAME)
  rescue Octokit::NotFound
    @client.add_label(@mint_content_repo, LABEL_NAME, LABEL_COLOR)
  end

  # ── Mint-content PR copy ─────────────────────────────────────────────────────

  # mint-content title convention (see PR #20886): "New Commits added to <branch>".
  def mint_pr_title(branch)
    "New Commits added to #{branch}"
  end

  def mint_pr_body(finding, patch)
    avg_ms = finding[:avg_duration_ms].to_i
    max_ms = finding[:max_duration_ms].to_i
    ratio  = finding[:avg_scan_ratio].to_f.round(0).to_i

    <<~BODY
      ## Performance Issue Fixed by PerformanceIQ

      **Collection:** `#{finding[:collection]}` | **Avg query time:** #{avg_ms}ms | **Max:** #{max_ms}ms | **Ops in 24h:** #{finding[:total_ops]}
      **Query hash:** `#{finding[:query_hash]}` | **Scan ratio:** #{ratio} (#{ratio} docs examined per doc returned)

      ## Root Cause
      #{finding[:root_cause] || finding[:root_cause_type]}

      ## What Changed
      Query optimisation only — no index or schema changes. Modified `#{patch['file']}` → `#{patch['function']}` (#{patch['function']} pipeline restructure): #{finding[:pipeline_rewrite]}

      ## Before / After (estimated)

      | Metric | Before | After |
      |--------|--------|-------|
      | Avg query time | #{avg_ms}ms | #{finding[:estimated_speedup] || '~significantly less'} |
      | Scan ratio | #{ratio} | ~1 |
      | Confidence | — | #{((finding[:confidence].to_f) * 100).round}% |

      ## Review Checklist
      - [ ] Pipeline logic is functionally equivalent (same output, faster execution)
      - [ ] Change is query-only — no new/changed index and no schema/model change
      - [ ] Restructured query uses an existing index (verify the $match leading fields)
      - [ ] Tested against staging with representative data

      ---
      🤖 Auto-generated by PerformanceIQ — always review pipeline changes before merging
    BODY
  end

end
