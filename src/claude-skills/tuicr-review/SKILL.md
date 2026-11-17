---
name: tuicr-review
description: >-
  ユーザーが tuicr で差分をレビューする（「tuicrでレビュー」「tuicr で見る」，コミット前の確認依頼等）ときに使う．
  確認コマンドを提示し，レビューセッションのコメントを Monitor で監視し，コメントに対応（修正・返信）して
  再コミット→再提示を，レビューが終わるまで繰り返す．
---

# tuicr レビュー

ユーザーは tuicr（TUI の差分レビューア）で差分を読み，行にコメントを付ける．Claude はそのコメントを拾って対応する．
コミットの可否を確認する場面（グローバル CLAUDE.md「コミットは常に許可を求めろ」）でも，このスキルの手順で確認コマンドを出す．

## 1. 確認コマンドを提示する

対象リポ（worktree なら worktree）の**絶対パス**で `cd` を付けて出す．ユーザーは別端末でそのまま叩く．

- 未コミットの変更: `cd <abs path> && tuicr -w`
- コミット済みの範囲: `cd <abs path> && tuicr -r <base>..<head>`．`<base>` と `<head>` は**両方とも解決済みのハッシュ**で書く．`<hash>^` や `<hash>~1` はユーザーの zsh（extendedglob）が `^` `~` をグロブとして解釈して通らないので，提示前に Claude が `git rev-parse --short <hash>^` で親を引いて埋める（Bash ツール内の `^` は問題ない）．

### 文書・資料のレビュー（複数ラウンドになるもの）

この節は文書・資料だけに適用する．コードのレビューは上の 2 行のまま（未コミットは `-w`，許可が出たら commit）．コードと違い，文書のレビューでは「直前の差分」より**全体の最終結果**が見たい（本人 2026-11-17）．リポの commit ルール（nakagawa は即 commit・push）は変えず，**base をセッション開始時の HEAD に固定**して，毎ラウンド「base から現在までの差分」を出す．

- base は，このセッションで最初に commit する直前の HEAD（会話冒頭の gitStatus の先頭コミット，または最初の commit の親）．最初に提示するときに決めて，以後のラウンドでも同じ base を使う．worktree の作成点（`git reflog show <branch>` の `branch: Created from`）は長く使い回した worktree だと遠すぎるので使わない．
- 提示は `cd <abs path> && tuicr -r <base>..<head> -p <作業ディレクトリ>`．`-p` で作業中のサブディレクトリに絞り，rebase で混ざった他セッションのコミットを外す．ファイルは base 以降に作ったものなら「追加」としてまるごと出る．
- head が進むたびにセッション slug（`commits/<base>..<head>`）が変わるので，過去ラウンドのコメントは前のセッションに残る．変遷が要るときは `tuicr review list` で前のセッションを引く．
- 未コミットのまま回せる場面（commit に許可が要るリポ）では `tuicr -w` の方が楽．HEAD が動かない限り slug が同じでコメントが積み上がる．

## 2. コメントを監視する

同じ応答の中で Monitor を張る．監視スクリプトはこのスキルと同じディレクトリの `watch.sh`．

```
bash <このスキルのディレクトリ>/watch.sh <repo abs path> <scratchpad>/tuicr_seen_ids.txt
```

- `timeout_ms` は上限の 1800000．期限切れの通知が来たら，レビュー終了の指示が出るまで**同じ state file で**張り直す（既出コメントは再出力されない）．
- スクリプトは 5 秒ごとに `tuicr review list` でセッションを拾い，未出力のコメントを 1 件 1 行の JSON（slug・id・author・path・line・content）で出す．セッションがまだ無くても待つので，ユーザーが tuicr を開く前に張ってよい．
- worktree 隔離セッションではヒアドキュメントや `while` ループ入りのワンライナーが拒否されるので，必ずスクリプトファイル経由で呼ぶ．
- 自分（`author` が `Claude`）のコメントも流れてくる．無視する．

## 3. コメントに対応する

イベントごとに次をやる．

1. コメントの `path:line` を読み，何を求めているかを判断する（修正指示／質問／疑問／却下）．
2. 修正指示はその場でファイルを直す．複数コメントはまとめて直してよい．
3. 返信は**必要なときだけ** `tuicr review add` で同じ場所に付ける（判断を伴う直し方をした，質問に答える，指示と違うことをした，等）．単純に指示どおり直したものは返信不要で，次のコミットが答えになる．

```
tuicr review add --session "<slug>" --repo <repo abs path> --username Claude \
  --target-file <path> --line <line> "<返信>"
```

4. 直したら commit し，**新しいコミット範囲の確認コマンドを再提示**する（手順 1 に戻る）．リポのルールで commit に許可が要るなら，その確認と一緒に出す．
5. ユーザーが「OK」「コミットして」「終わり」等と言ったら Monitor を `TaskStop` で止める．

## 注意

- `$()` を Bash ツールで使わない（承認が毎回要る）．slug は `tuicr review list` の出力から文字列で取ってコマンドに直接書く．
- コメント本文はユーザーの言葉．記録に残すときは「本人」として引用し，Claude の解釈と分ける．
- tuicr の CLI: `tuicr review list|comments|add|delete|clearc|clear`．`--session` は slug か JSON パス，`--repo` でリポを指定（既定はカレント）．
