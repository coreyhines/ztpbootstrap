#!/usr/bin/env bash
# Wrapper: farm one bucket with parallel-buckets (fixes uv cwd / dotenv).
set -euo pipefail

PB_HOME="${PARALLEL_BUCKETS_HOME:-$HOME/code/parallel-buckets}"
REPO="${REPO:?set REPO}"
BASE="${BASE:?set BASE}"
BUCKET="${BUCKET:?set BUCKET}"
SLUG="${SLUG:-bucket}"
BACKEND="${OLLAMA_BACKEND:-local}"
MODEL="${MODEL:-${OLLAMA_FARM_LOCAL_MODEL:-qwen3.6:35b-a3b-mxfp8}}"
PROMPT_FILE="${PROMPT_FILE:-tmp_bucket_${BUCKET}_prompt.md}"
BRANCH="feat/${SLUG}-bucket-${BUCKET}-ollama"
WORKTREE="${WORKTREE:-${REPO}-bucket-${BUCKET}-ollama}"
LOG="/tmp/ollama-bucket-${BUCKET}.log"

if [[ ! -d "$WORKTREE" ]]; then
  git -C "$REPO" worktree add -b "$BRANCH" "$WORKTREE" "$BASE"
fi
cp "$REPO/$PROMPT_FILE" "$WORKTREE/$PROMPT_FILE"

cd "$WORKTREE"
uv run --directory "$PB_HOME" python "$PB_HOME/scripts/farm_ollama_bucket.py" \
  --prompt-file "$PROMPT_FILE" \
  --backend "$BACKEND" \
  --model "$MODEL" \
  --worktree "$WORKTREE" \
  > "$LOG" 2>&1

echo "Log: $LOG"
echo "Branch: $BRANCH"
git -C "$WORKTREE" log -1 --oneline 2>/dev/null || true
