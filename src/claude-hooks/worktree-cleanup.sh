#!/bin/sh
# Claude セッション開始時、cwd の git リポで不要になった worktree を掃除する。
# 3 pass 構成:
#   1. 登録済み worktree のうち「origin に branch が無い」かつ「merged PR がある」もの
#   2. git に登録が無いのにディレクトリだけ残っている孤児
#   3. worktree が消えた後に取り残された worktree-* branch
#
# 孤児ができる理由: compose が `./:/rails` を bind mount していてコンテナが root で
# 動くため、worktree に root 所有ファイルが大量にできる。これを消せずに
# `git worktree remove` が Permission denied で失敗するのだが、git は削除に失敗しても
# admin entry の方は消してしまう。結果 worktree は `git worktree list` から消え、
# ディレクトリだけが誰からも発見されずに残り続ける。
#
# 対策として、削除は docker 経由で行う (root の daemon に消させる) 。また
# `git worktree remove` は使わず、ディレクトリを消してから `git worktree prune` で
# admin entry を回収する (remove は失敗しても admin entry を消してしまうため) 。
#
# compose のリソースは project 名を指定して落とす。孤児は partial delete で
# compose.yml 自体を失っていることがあり、その状態で `cd` して `docker compose` を
# 叩くと上位ディレクトリの compose.yml が拾われて main の project を落としかねない。
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
repo_root=$(git rev-parse --show-toplevel)
wt_dir="${repo_root}/.claude/worktrees"
[ -d "$wt_dir" ] || exit 0
repo_name=$(basename "$repo_root")

# compose の project 名正規化 (cl-setup.sh と同じ規則)
normalize() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g'
}

# main worktree の project 名。ここを掃除対象にしては絶対にいけないので、
# 後段で候補から必ず除外する。
main_project=$(cd "$repo_root" && docker compose config 2>/dev/null | sed -n 's/^name: *//p' | head -1)
[ -n "$main_project" ] || main_project=$(normalize "$repo_name")

# worktree に対応する compose のリソースを落とす。
# project 名は cl-setup.sh を通っていれば <repo>-<dir 名>、通っていなければ compose
# 既定の <dir 名> になるので両方試す。実在するものだけ叩く。
compose_down() {
  dir_name=$1
  for p in "$(normalize "${repo_name}-${dir_name}")" "$(normalize "$dir_name")"; do
    [ -n "$p" ] || continue
    [ "$p" = "$main_project" ] && continue
    containers=$(docker ps -aq --filter "label=com.docker.compose.project=$p" 2>/dev/null)
    volumes=$(docker volume ls -q --filter "label=com.docker.compose.project=$p" 2>/dev/null)
    [ -z "$containers" ] && [ -z "$volumes" ] && continue
    echo "worktree-cleanup: docker compose -p $p down -v"
    docker compose -p "$p" down -v --remove-orphans
  done
}

# コンテナが root で書いたファイルは通常の rm では消せないので、同じ docker daemon
# (root) に消させる。
force_rmdir() {
  target=$1
  case "$target" in
    "$wt_dir"/*) ;;
    *)
      echo "worktree-cleanup: refusing to delete $target (outside $wt_dir)" >&2
      return 1
      ;;
  esac
  # root 所有ファイルで必ず失敗するので、ここのエラーは想定内として捨てる
  rm -rf "$target" 2>/dev/null
  if [ -e "$target" ]; then
    docker run --rm -v "$wt_dir":/wt busybox rm -rf "/wt/$(basename "$target")"
  fi
  if [ -e "$target" ]; then
    echo "worktree-cleanup: failed to delete $target" >&2
    return 1
  fi
  return 0
}

# default branch (origin/HEAD) 。取れなければ master。
default_branch=$(git -C "$repo_root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
[ -n "$default_branch" ] || default_branch=master

# branch が「もう master に入っている」か。次のどちらかで真:
#   (a) merged PR がある (squash merge 対応)
#   (b) branch の全コミットが origin/<default> に patch 同値で含まれる
#       (`git cherry` が "+" 行を出さない) 。PR を作らず worktree から直接
#       origin/master に push する運用 (rebase して push / cherry-pick) はこちらで拾う。
#       worktree を切っただけでコミットが無い branch も (b) で真になるので、
#       呼び出し側で locked / dirty な worktree を先に除外すること。
branch_is_merged() {
  branch=$1
  merged=$(cd "$repo_root" && gh pr list --state merged --head "$branch" --json number --limit 1 2>/dev/null)
  if [ -n "$merged" ] && [ "$merged" != "[]" ]; then
    return 0
  fi
  cherry=$(git -C "$repo_root" cherry "origin/$default_branch" "$branch" 2>/dev/null) || return 1
  if printf '%s\n' "$cherry" | grep -q '^+'; then
    return 1
  fi
  return 0
}

# branch の削除条件は worktree の削除条件と同じ (origin に無く master に取り込み済み) 。
# worktree を消した後に呼ぶので、admin entry が prune 済みであることが前提。
delete_branch_if_safe() {
  branch=$1
  [ -n "$branch" ] || return 0
  git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch" || return 0
  # まだどこかの worktree が使っているなら消せない
  if git -C "$repo_root" worktree list --porcelain | grep -qx "branch refs/heads/$branch"; then
    return 0
  fi
  if git -C "$repo_root" ls-remote --heads origin "$branch" 2>/dev/null | grep -q .; then
    return 0
  fi
  branch_is_merged "$branch" || return 0
  git -C "$repo_root" branch -D "$branch"
}

git -C "$repo_root" fetch --prune origin 2>/dev/null

# main checkout を origin/<default> に追従させる。worktree から直接 origin/master に
# push する運用では main checkout を誰も更新しないため、他セッションが「現状」として
# 読む main が古くなる。default branch 上で追跡ファイルに変更が無いときだけ ff する。
if [ "$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$default_branch" ] \
   && [ -z "$(git -C "$repo_root" status --porcelain --untracked-files=no)" ]; then
  if ! git -C "$repo_root" merge --ff-only --quiet "origin/$default_branch" 2>/dev/null; then
    echo "worktree-cleanup: main checkout の $default_branch を origin/$default_branch に ff できず (ローカルに独自コミットがある)" >&2
  fi
fi

# --- 1. 登録済みで不要になった worktree ---
# branch 名は `git worktree list --porcelain` の `branch refs/heads/<name>` から取る。
# Claude の EnterWorktree は dir basename と異なる branch 名 (worktree-<name>) を
# 作るので、dir basename を branch 名として扱うのは誤り。
git -C "$repo_root" worktree list --porcelain \
  | awk '
      /^worktree / { if (wt != "") print wt "|" branch "|" locked; wt = $2; branch = ""; locked = "" }
      /^branch refs\/heads\// { branch = substr($2, 12) }
      /^locked/ { locked = "locked" }
      END { if (wt != "") print wt "|" branch "|" locked }
    ' \
  | while IFS='|' read -r wt branch locked; do
      case "$wt" in
        "$wt_dir"/*) ;;
        *) continue ;;
      esac
      [ -z "$branch" ] && continue
      # 使用中 (EnterWorktree は lock する) の worktree は触らない
      [ "$locked" = "locked" ] && continue
      # 未コミットの変更がある worktree も触らない (切った直後の空 branch を守る)
      if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
        continue
      fi
      # 条件A: origin にまだあるなら保護
      if git -C "$repo_root" ls-remote --heads origin "$branch" 2>/dev/null | grep -q .; then
        continue
      fi
      # 条件B: master に取り込み済み (merged PR または patch 同値) でなければ保護
      branch_is_merged "$branch" || continue
      echo "worktree-cleanup: removing $wt (branch $branch)"
      compose_down "$(basename "$wt")"
      # locked のままだと prune が admin entry を残すので外す (locked でなければ
      # エラーになるが、それは想定内)
      git -C "$repo_root" worktree unlock "$wt" 2>/dev/null
      force_rmdir "$wt"
    done

# ディレクトリを消した分の admin entry を回収する。branch の削除はこの後
# (admin entry が残っていると "used by worktree" で拒否される)。
git -C "$repo_root" worktree prune

# --- 2. 孤児ディレクトリ ---
# 「登録が無い」だけを条件にすると、別セッションが今まさに作っている最中の worktree を
# 巻き込みかねない。`git worktree add` は admin entry を先に作るので、登録済みなら
# ここに来ない。その上で「.git が無い、または .git の指す admin entry が存在しない」
# = 削除に失敗した残骸、という形のものだけを対象にする。
registered=$(git -C "$repo_root" worktree list --porcelain | sed -n 's/^worktree //p')
for d in "$wt_dir"/*/; do
  [ -d "$d" ] || continue
  d=${d%/}
  printf '%s\n' "$registered" | grep -qxF "$d" && continue
  if [ -f "$d/.git" ]; then
    gitdir=$(sed -n 's/^gitdir: //p' "$d/.git")
    [ -n "$gitdir" ] && [ -d "$gitdir" ] && continue
  fi
  echo "worktree-cleanup: removing orphan $d (git に登録が無い残骸)"
  compose_down "$(basename "$d")"
  force_rmdir "$d"
done

# --- 3. worktree が消えた後に取り残された branch ---
# 孤児の削除では branch まで辿れない (admin entry が既に無く branch 名が分からない)
# ため、worktree の有無と切り離してここでまとめて処理する。EnterWorktree が作る
# branch は worktree-<名前> なので、その prefix のものだけを対象にする。
git -C "$repo_root" for-each-ref --format='%(refname:short)' 'refs/heads/worktree-*' \
  | while read -r branch; do
      delete_branch_if_safe "$branch"
    done

exit 0
