#!/bin/bash
# tuicr のレビューセッションを 5 秒ごとに見て，未出力のコメントを 1 件 1 行の JSON で stdout に出す．
# Monitor ツールから `bash watch.sh <repo abs path> <state file>` で起動する想定．
# 既出のコメント id は state file に貯めるので，Monitor を張り直しても同じ state file を渡せば重複しない．
# worktree 隔離セッションではヒアドキュメントや複雑なワンライナーが拒否されるため，スクリプトファイルにしてある．
set -u
repo="$1"
state="$2"
touch "$state"
cd "$repo" || exit 1
while true; do
  for slug in $(tuicr review list --repo "$repo" 2>/dev/null | jq -r '.[].slug'); do
    tuicr review comments --session "$slug" --repo "$repo" 2>/dev/null \
      | jq -c --arg slug "$slug" '.[] | {slug: $slug, id, author, path, line: .start_line, end_line, created_at, content}' \
      | while IFS= read -r line; do
          id=$(printf '%s' "$line" | jq -r '.id')
          grep -qxF "$id" "$state" && continue
          printf '%s\n' "$id" >> "$state"
          printf '%s\n' "$line"
        done
  done
  sleep 5
done
