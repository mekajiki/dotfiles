#!/bin/bash
# Claude が EnterWorktree で .claude/worktrees/<branch>/ に入った直後に呼ぶ想定。
# 当該 worktree に compose.override.yml (auto-load 名) を生成し、
# host port と docker compose project 名を branch ベースで決定的に分離する。
# branch 名は cwd の basename から導出。
# auto-load 名にすることで `make up` や bare `docker compose up` でも override が効く。
set -e

cwd=`pwd`
case "$cwd" in
  */.claude/worktrees/*) ;;
  *)
    echo "cl-setup: not inside .claude/worktrees/, skipping." >&2
    exit 0
    ;;
esac

branch=`basename "$cwd"`

# main worktree の repo root から repo 名を取る (cwd の basename は branch 名なので別途)
common=`git rev-parse --git-common-dir`
case "$common" in
  /*) ;;
  *) common="$cwd/$common" ;;
esac
main_repo=`cd "$(dirname "$common")" && pwd`
repo_name=`basename "$main_repo"`

# compose の project 名正規化 (小文字化 + [a-z0-9_-] 以外を除去) を先回りで適用する。
# volume 名を自前で組み立てるので、compose 内部の正規化結果とずれると参照できない。
normalize() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g'
}
project=`normalize "${repo_name}-${branch}"`

# branch 名から決定的に port を算出
if command -v sha1sum >/dev/null 2>&1; then
  hex=`printf '%s' "$branch" | sha1sum | cut -c1-4`
else
  hex=`printf '%s' "$branch" | shasum | cut -c1-4`
fi
hash=$((16#$hex))
server_port=$(( 20000 + (hash % 1000) ))
mailcatcher_port=$(( 21000 + (hash % 1000) ))
yard_port=$(( 22000 + (hash % 1000) ))
chrome_vnc_port=$(( 23000 + (hash % 1000) ))

# base compose を検出し、対応する auto-load override 名を決める
base=""
override=""
set -- \
  compose.yml         compose.override.yml \
  compose.yaml        compose.override.yaml \
  docker-compose.yml  docker-compose.override.yml \
  docker-compose.yaml docker-compose.override.yaml
while [ $# -ge 2 ]; do
  if [ -f "$1" ]; then
    base=$1
    override=$2
    break
  fi
  shift 2
done
if [ -z "$base" ]; then
  echo "cl-setup: no compose file in $cwd, skipping override generation." >&2
  exit 0
fi

# base に存在する service だけ override する (存在しない service を書くと
# compose が "service has neither image nor build context" でエラーになる)
existing=`docker compose -f "$base" config --services 2>/dev/null`

has_service() {
  echo "$existing" | grep -qx "$1"
}

emit_service() {
  name=$1
  host_port=$2
  target_port=$3
  if has_service "$name"; then
    cat <<EOF
  $name:
    ports: !override
      - "${host_port}:${target_port}"
EOF
  fi
}

# project 名を分けると volume も新規＝空になり、worktree ごとに bundle install /
# yarn install をやり直すことになって遅い。install 成果物・キャッシュの volume だけ
# main worktree のものを external として掴み、install 自体を不要にする。
# external なので worktree 側の `down -v` (SessionEnd フック) では消えない。
#
# 共有して良い理由:
#   bundler_volume は gems/<name>-<version>/ の version キーで加算のみ (bundle clean は
#   走らない)、native extension も extensions/<platform>/<ruby api version>/ 配下なので
#   branch 間で ruby 版が違っても共存する。並行 install は bundler が
#   <bundle_path>/bundler.lock に取る flock で直列化される。
#   yarn_volume は yarn の global cache でこれも content-addressed。
# 共有しないもの:
#   node_modules_volume は lockfile 1つに対応する実体ツリーなので branch 間で壊れる。
#   pg_volume 等のデータ volume も当然共有しない。
shared_volumes=""

# main worktree の project 名 (volume 名の prefix)。compose に聞くのが確実だが
# env_file 不足等で失敗し得るので、その場合は同じ正規化規則で組み立てる。
main_project=`cd "$main_repo" && docker compose config 2>/dev/null | sed -n 's/^name: *//p' | head -1`
[ -n "$main_project" ] || main_project=`normalize "$repo_name"`

defined_volumes=`docker compose -f "$base" config --volumes 2>/dev/null`
for v in bundler_volume yarn_volume; do
  if echo "$defined_volumes" | grep -qx "$v"; then
    shared_volumes="$shared_volumes $v"
  fi
done

emit_shared_volume() {
  cat <<EOF
  $1:
    name: ${main_project}_$1
    external: true
EOF
}

services_body=`
  emit_service server      "$server_port"      3000
  emit_service mailcatcher "$mailcatcher_port" 1080
  emit_service yard        "$yard_port"        8808
  emit_service chrome      "$chrome_vnc_port"  5900
`

{
  echo "name: ${project}"
  if [ -n "$services_body" ]; then
    echo "services:"
    echo "$services_body"
  else
    # override 対象の service が base に無い repo では services が空になる。
    # 値なしの "services:" は YAML では null になり compose が
    # "services must be a mapping" で落ちるので、空 mapping を明示する。
    # (project 名の分離だけでも mysql 等の container / volume が worktree 毎に分かれるので意味がある)
    echo "services: {}"
  fi
  if [ -n "$shared_volumes" ]; then
    echo "volumes:"
    for v in $shared_volumes; do
      emit_shared_volume "$v"
    done
  fi
} > "$override"

# 出力 (Claude / 人間向けに port をサマリ)
echo "cl-setup: $override generated (auto-loaded by docker compose)."
echo "  project: ${project}"
has_service server      && echo "  server (Rails):  http://localhost:${server_port}"
has_service mailcatcher && echo "  mailcatcher:     http://localhost:${mailcatcher_port}"
has_service yard        && echo "  yard:            http://localhost:${yard_port}"
has_service chrome      && echo "  chrome VNC:      vnc://localhost:${chrome_vnc_port}"
echo

# external volume は存在しないと compose が起動を拒否する。main worktree を一度も
# 立ち上げていない場合に備えて作っておく (既にあれば no-op)。
if [ -n "$shared_volumes" ]; then
  echo "cl-setup: sharing install volumes with ${main_project} (external, kept on 'down -v'):"
  for v in $shared_volumes; do
    docker volume create "${main_project}_${v}" >/dev/null
    echo "  $v -> ${main_project}_${v}"
  done
  echo
fi

echo "Run with: docker compose up -d   (or 'make up')"
