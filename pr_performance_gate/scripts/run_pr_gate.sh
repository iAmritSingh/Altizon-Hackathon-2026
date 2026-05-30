#!/usr/bin/env bash
# Track 1 — One-shot PR performance gate (local).
#
# Runs locally exactly what CI's .github/workflows/performance_gate.yml runs, against a real PR:
#   1. fetch the PR head from origin
#   2. detect changed FaaS functions vs the PR's merge-base (functions/**/*.rb, excluding *_spec.rb)
#   3. pipeline-shape gate (static_gate.rb)  — always; no DB, no fixtures
#   4. load-test gate (load_gate.rb)         — only with --load; seeds a throwaway Mongo, A/Bs p95
#
# The PR is checked out in a throwaway `git worktree`, so your current branch / working tree is
# never touched. Overall exit code is non-zero if any enabled gate fails.
#
# Usage:
#   run_pr_gate.sh <pr-number|pr-url> [options]
#
# Options:
#   --repo DIR        path to the mint-content checkout            (default: $PWD)
#   --base REF        base branch to diff against                  (default: origin/master)
#   --load            also run the load-test gate (needs Mongo; see below)
#   --mongo-url URL   seeded Mongo for the load gate. If --load is set and this is omitted,
#                     a throwaway mongod is auto-started on :27018 and torn down at the end.
#   --bootstrap FILE  PERF_GATE_BOOTSTRAP runtime loader for load test
#                     (default: <gate>/test/bootstrap_local.rb — only fits the demo functions;
#                      for real functions use <gate>/test/bootstrap_factory.rb + FACTORY_DIR)
#   --concurrency N   load-test concurrency                        (default: 8)
#   --duration N      load-test seconds per version                (default: 15)
#   --out DIR         where to write the gate comment files        (default: ./pr-<N>-gate)
#
# Examples:
#   scripts/run_pr_gate.sh 20898 --repo ~/source/.../mint-content
#   scripts/run_pr_gate.sh https://github.com/Altizon/mint-content/pull/20898 --repo ~/.../mint-content
#   scripts/run_pr_gate.sh 20898 --repo ~/.../mint-content --load   # + load test (auto mongo)

set -euo pipefail

GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # pr_performance_gate/
SCRIPTS="$GATE_DIR/scripts"
PERF="$GATE_DIR/.performance"

# ── defaults ─────────────────────────────────────────────────────────────────────
PR_ARG="${1:-}"; shift || true
REPO="$PWD"; BASE_REF="origin/master"; DO_LOAD=0
MONGO_URL=""; BOOTSTRAP="$GATE_DIR/test/bootstrap_local.rb"
CONC=8; DUR=15; OUT=""
DO_POST=0; NEW_COMMENT=0; TOKEN="${GH_TOKEN:-${GH_PAT:-${GITHUB_TOKEN:-}}}"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)        REPO="$2"; shift 2 ;;
    --base)        BASE_REF="$2"; shift 2 ;;
    --load)        DO_LOAD=1; shift ;;
    --mongo-url)   MONGO_URL="$2"; shift 2 ;;
    --bootstrap)   BOOTSTRAP="$2"; shift 2 ;;
    --concurrency) CONC="$2"; shift 2 ;;
    --duration)    DUR="$2"; shift 2 ;;
    --out)         OUT="$2"; shift 2 ;;
    --post)        DO_POST=1; shift ;;          # post results back to the PR (needs a token)
    --new-comment) NEW_COMMENT=1; shift ;;      # force a fresh PR comment instead of updating in place
    --token)       TOKEN="$2"; shift 2 ;;       # GitHub PAT (repo scope); else $GH_TOKEN/$GH_PAT
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# accept either a bare number or a full PR URL
PR_NUM="$(echo "$PR_ARG" | grep -oE '[0-9]+' | tail -1 || true)"
[ -z "$PR_NUM" ] && { echo "usage: run_pr_gate.sh <pr-number|pr-url> [options]" >&2; exit 2; }
[ -d "$REPO/.git" ] || { echo "not a git repo: $REPO (pass --repo)" >&2; exit 2; }
OUT="${OUT:-$PWD/pr-$PR_NUM-gate}"; mkdir -p "$OUT"

cd "$REPO"

# ── 1. fetch PR head + base, resolve diff base (merge-base = fork point) ───────────
echo "▸ Fetching PR #$PR_NUM and base ($BASE_REF) ..."
git fetch -q origin "pull/$PR_NUM/head:refs/pr-gate/$PR_NUM"
git fetch -q origin "${BASE_REF#origin/}" || true
PR_SHA="$(git rev-parse "refs/pr-gate/$PR_NUM")"
BASE_SHA="$(git merge-base "$BASE_REF" "$PR_SHA")"
echo "  PR head : $PR_SHA"
echo "  base    : $BASE_SHA"

# ── throwaway worktree (never touches your checkout); cleaned up on exit ───────────
WORK="$(mktemp -d)"; MONGO_PID=""; MONGO_DB=""
cleanup() {
  [ -n "$MONGO_PID" ] && kill "$MONGO_PID" 2>/dev/null || true
  [ -n "$MONGO_DB" ]  && rm -rf "$MONGO_DB" 2>/dev/null || true
  git -C "$REPO" worktree remove --force "$WORK" 2>/dev/null || true
  git -C "$REPO" update-ref -d "refs/pr-gate/$PR_NUM" 2>/dev/null || true
}
trap cleanup EXIT
git worktree add -q --detach "$WORK" "$PR_SHA"
cd "$WORK"

# ── 2. detect changed functions (same filter as CI) ───────────────────────────────
FILES="$(git diff --name-only "$BASE_SHA"...HEAD | grep 'functions/.*\.rb$' | grep -v '_spec\.rb$' | tr '\n' ' ' || true)"
if [ -z "$(echo "$FILES" | tr -d ' ')" ]; then
  echo "✅ No changed FaaS functions in PR #$PR_NUM — nothing to gate."
  exit 0
fi
echo "▸ Changed functions:"; for f in $FILES; do echo "    $f"; done

FAIL=0

# ── 3. pipeline-shape gate (primary, no infra) ────────────────────────────────────
echo; echo "════ Pipeline-shape gate ════"
if ruby "$SCRIPTS/static_gate.rb" --functions "$FILES" --base "$BASE_SHA" --out "$OUT/pipeline_shape.md"; then
  echo "  → pipeline-shape: PASS"
else
  echo "  → pipeline-shape: FAIL"; FAIL=1
fi

# ── 4. load-test gate (optional; seeds Mongo, A/Bs master vs PR) ───────────────────
if [ "$DO_LOAD" = 1 ]; then
  echo; echo "════ Load-test gate ════"
  if [ -z "$MONGO_URL" ]; then
    command -v mongod >/dev/null || { echo "  mongod not found; install it or pass --mongo-url" >&2; exit 2; }
    MONGO_DB="$(mktemp -d)"; LOG="$MONGO_DB/mongod.log"
    echo "  starting throwaway mongod on :27018 ..."
    mongod --dbpath "$MONGO_DB" --port 27018 --fork --logpath "$LOG" >/dev/null
    MONGO_PID="$(pgrep -f "mongod --dbpath $MONGO_DB" | head -1)"
    MONGO_URL="mongodb://127.0.0.1:27018/perf_gate"
  fi
  export PERF_GATE_MONGO_URL="$MONGO_URL"
  export PERF_GATE_BOOTSTRAP="$BOOTSTRAP"

  echo "  seeding prod-scale data + indexes ..."
  ruby "$SCRIPTS/seed_dummy_data.rb" --mongo-url "$MONGO_URL" \
    --indexes "$PERF/indexes.json" --spec "$PERF/seed_spec.json"

  echo "  load-testing master vs PR ($CONC concurrent × ${DUR}s each) ..."
  if ruby "$SCRIPTS/load_gate.rb" --functions "$FILES" --base "$BASE_SHA" \
       --fixtures-dir "$PERF/fixtures" --probe "$SCRIPTS/load_probe.rb" \
       --concurrency "$CONC" --duration "$DUR" \
       --threshold-pct 20 --threshold-ms 50 --out "$OUT/load_test.md"; then
    echo "  → load-test: PASS / skipped"
  else
    echo "  → load-test: FAIL"; FAIL=1
  fi
fi

# ── 5. post results back to the PR (optional) ─────────────────────────────────────
if [ "$DO_POST" = 1 ]; then
  echo; echo "════ Posting results to PR #$PR_NUM ════"
  # Fall back to the token in performance_iq/config/settings.yml (github.access_token) if none given.
  if [ -z "$TOKEN" ]; then
    SETTINGS="${PERFIQ_SETTINGS:-$GATE_DIR/../performance_iq/config/settings.yml}"
    if [ -f "$SETTINGS" ]; then
      TOKEN="$(ruby -ryaml -e "puts (YAML.load_file(ARGV[0]).dig('github','access_token') rescue '')" "$SETTINGS" 2>/dev/null)"
      [ -n "$TOKEN" ] && echo "  using github.access_token from $(basename "$(dirname "$(dirname "$SETTINGS")")")/config/settings.yml"
    fi
  fi
  if [ -z "$TOKEN" ]; then
    echo "  --post given but no token (pass --token <PAT>, set GH_TOKEN, or add github.access_token to settings.yml). Skipping post." >&2
  else
    SLUG="$(git -C "$REPO" remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
    [ "$NEW_COMMENT" = 1 ] && NEW_FLAG="--new" || NEW_FLAG=""
    ruby "$SCRIPTS/post_pr_comment.rb" --repo-slug "$SLUG" --pr "$PR_NUM" --token "$TOKEN" \
      --files "$OUT/pipeline_shape.md,$OUT/load_test.md" $NEW_FLAG
  fi
fi

echo; echo "════ Summary ════"
echo "  comments written to: $OUT/"
[ "$FAIL" = 0 ] && echo "✅ Performance gate PASSED" || echo "❌ Performance gate FAILED"
exit "$FAIL"
