---
name: disk-cleanup
description: >-
  Mac のディスク空き容量を確保する（「ディスク空けて」「ソフトウェアアップデートに容量が足りない」
  「あと NN GB 欲しい」等）．~/ghq 以下の Rails 開発環境が肥大させる tmp/storage，worktree の残骸に
  紐付く Docker リソース，ホスト側キャッシュを，消してよいもの/温存するものの線引き込みで掃除する．
  過去実績（hammurabi 2026-08-21，m2pro 2026-08-30）の内訳も持つ．
---

# ディスク掃除

大物はほぼ毎回同じ場所に溜まる．闇雲に `du` で全域を舐めず，まず下の「候補」を直接測ってから消す．
目標容量（OS アップデートなら要求 GB + 余裕）に達したら止めてよいが，候補 1〜2 は害が無いので
ついでに全部やってしまって構わない．

## 調査

```bash
df -h /System/Volumes/Data
docker system df
# ~/ghq 以下の Rails プロジェクト（worktree 含む）の tmp/storage
find ~/ghq -maxdepth 8 -path '*/config/storage.yml' -not -path '*/node_modules/*' -not -path '*/vendor/*' 2>/dev/null \
  | sed 's|/config/storage.yml$||' | xargs -I{} du -sh {}/tmp/storage 2>/dev/null | sort -h -r | head
du -h ~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw   # 実消費（ls の見かけサイズではなく du）
du -xsh ~/Library/Caches/* ~/.gradle/* ~/.npm/* ~/.cache/* ~/.docker/* 2>/dev/null | sort -h -r | head -15
```

`docker system df -v` の Volumes 表で `LINKS` が 0 のものが dangling．

## 候補（効く順）

### 1. Rails の test 用 ActiveStorage / cache

Rails 既定の `config/storage.yml` では `tmp/storage` が `test` service の root，`storage/` が
`development` の `local` service の root．system spec を回すたびに `tmp/storage` に画像が溜まり，
リポによっては 40〜50GB になる．`tmp/cache`，`tmp/capybara` も消してよい．
**`storage/` は開発データなので消さない**．割り当てが既定と違うリポがあり得るので，消す前に
そのリポの `config/storage.yml` と `config/environments/*.rb` の `active_storage.service` を確認する．

```bash
for d in <repo>/tmp/{storage,cache,capybara}; do
  [ -e "$d" ] || continue
  rm -rf "$d" 2>/dev/null
  # compose が root で動くリポでは root 所有ファイルが残る．その場合は daemon (root) に消させる
  [ -e "$d" ] && docker run --rm -v "$(dirname "$d")":/t busybox rm -rf "/t/$(basename "$d")"
done
```

### 2. worktree 残骸に紐付く Docker リソース

merge 済み worktree の compose project（container / volume / network）は
`~/.claude/hooks/worktree-cleanup.sh` が SessionStart で掃除する設計だが，そのリポで Claude を
起動していなければ走っていない．`.claude/worktrees/` を持つ各リポで手動実行する．

```bash
find ~/ghq -maxdepth 5 -type d -name worktrees -path '*/.claude/worktrees' 2>/dev/null \
  | sed 's|/.claude/worktrees$||' | while read -r r; do (cd "$r" && bash ~/.claude/hooks/worktree-cleanup.sh); done
```

worktree ディレクトリ自体がもう無いのに compose project だけ残っているもの
（`docker ps -a --format '{{.Label "com.docker.compose.project"}}' | sort -u` に出る `<repo>-<branch>` 形の
project のうち，対応する `.claude/worktrees/<branch>/` が無いもの）は，フックの対象外なので
project 名を指定して直接落とす．**compose ファイルの無い場所から `-p` 指定で叩くこと**
（worktree に cd して叩くと上位の compose.yml を拾って main の project を落としかねない）．

```bash
docker compose -p <repo>-<branch> down -v --remove-orphans
```

その後，worktree project 用に build されたイメージ（compose 既定の `<project>-<service>:latest`）を消す．
`docker image prune -a` は main project や `postgres:*` `selenium/*` 等も巻き込んで再 build / pull に
なるので使わず，project 名で絞る．

```bash
docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^<repo>-<branch>-' | xargs docker rmi
docker image prune -f      # dangling (<none>) のみ
docker builder prune -f
```

### 3. dangling volume

`*_pg_volume` / `*_mysql_volume` 等の DB データは **温存**（消すなら DB の作り直しになる旨を
ユーザーに確認してから）．それ以外の install / cache 系（bundler / yarn / node_modules /
poetry / pip / gradle）は再取得できるので消してよい．

```bash
docker volume ls -qf dangling=true | grep -Ev '_pg_volume$|_mysql_volume$' | xargs docker volume rm
```

`LINKS` が付いている main project の `<repo>_yarn_volume` / `<repo>_bundler_volume` は
`cl-setup.sh` が worktree から `external` で相乗りする共有キャッシュ．10GB 級に肥大していても
消すと全 worktree で `bundle install` / `yarn install` のやり直しになるので温存する．

### 4. ホスト側キャッシュ

調査の `du` で大きかったものを消す．いずれも再生成・再ダウンロードされるだけ．
過去に大きかったのは以下（存在するものだけ）．

```bash
rm -rf ~/Library/Caches/{Google,Homebrew,com.openai.codex,JetBrains,"Microsoft Edge Dev",pip,pypoetry} \
       ~/.gradle/{caches,daemon} ~/.npm/_cacache ~/.docker/scout ~/.cache/{codex-runtimes,puppeteer}
```

- `~/Library/Caches/Google` は Chrome 起動中だと一部 `Directory not empty` で残るが，ほぼ消えているので気にしない
- `~/.gradle/wrapper`（gradle 配布物）は残す．`~/.gradle/caches` と `daemon` で十分
- `brew cleanup` は遅い（2 分でタイムアウトした実績あり）．`~/Library/Caches/Homebrew` を直接消す方が速く，効果は同じ

## 温存するもの

- `<repo>/storage/`（development の ActiveStorage）
- DB データの volume，main project の `*_yarn_volume` / `*_bundler_volume`（上記）
- `~/Library/Application Support/*`（ブラウザのプロファイル，各種アプリのデータ．キャッシュではない）
- `~/Library/Application Support/com.apple.wallpaper`（システム壁紙．数 GB あるが OS 管理）
- `~/Movies` 等の個人ファイル．大きければ候補として挙げるだけにし，勝手に消さない

## 確認

```bash
df -h /System/Volumes/Data
du -h ~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw   # Docker 内の削除後 TRIM で縮む
```

## 実績

| 日付 | ホスト | 空き | 主な内訳 |
| --- | --- | --- | --- |
| 2026-08-21 | hammurabi | 14GB → 62GB | Rails `tmp/storage` 39GB，`~/Library/Caches/Google` 7.6GB，gradle / npm cache |
| 2026-08-30 | m2pro | 10GB → 110GB | Rails `tmp/storage` 49GB，worktree 残骸の compose / image 約 10GB，Homebrew 7GB，Chrome 6.8GB，gradle 5.6GB，npm 3.2GB，dangling volume 4GB |
