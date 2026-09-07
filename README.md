# dotfiles

Terminal環境の設定一式（zsh / tmux / vim / git / Claude Code 等）。
macOS と Linux / WSL2 に対応。

## ワンライナーセットアップ

新規マシンで、ターミナルから以下を1行実行するだけで完了します。

```sh
curl -fsSL https://raw.githubusercontent.com/mekajiki/dotfiles/master/bootstrap.sh | bash
```

`bootstrap.sh` がやること:

1. `git` と `curl` が無ければ apt または brew で導入
2. `~/ghq/github.com/mekajiki/dotfiles` にこのリポジトリを clone
3. `install.sh` を実行

## 手動でやる場合

```sh
mkdir -p ~/ghq/github.com/mekajiki
git clone https://github.com/mekajiki/dotfiles.git ~/ghq/github.com/mekajiki/dotfiles
cd ~/ghq/github.com/mekajiki/dotfiles
./install.sh
```

## install.sh の中身

OSを自動判定 (`macOS` / `Linux` / `WSL2`) し、冪等に以下を実行：

| 項目 | macOS | Linux / WSL |
| --- | --- | --- |
| パッケージ | brew で zsh / tmux / vim / git / ghq / rbenv / ruby-build / nvm / coreutils / z | apt で zsh / tmux / vim / git / xclip / locales / build-essential など |
| locale | -- | `en_US.UTF-8` を生成 |
| ghq | brew | GitHub release のバイナリを `~/.local/bin` |
| rupa/z | brew | `ghq get rupa/z` |
| rbenv / ruby-build | brew | 公式リポジトリを `~/.rbenv` に clone |
| nvm | brew | 公式 installer |
| Vundle | -- | `~/.vim/vundle` に clone して `:PluginInstall` |
| デフォルトシェル | `chsh -s zsh` | `chsh -s zsh` |
| symlink | `link_files.sh` | `link_files.sh` |

途中で `sudo` パスワードや `chsh` 用パスワードを聞かれる箇所があります。

## install.sh がやらないこと（手作業）

「個人 × ホスト」固有の操作は意図的にスクリプト化していない。
新規マシンを実用状態に持っていくときの手順メモ：

- **SSH 鍵の生成と GitHub 登録**
  ```sh
  ssh-keygen -t ed25519 -C "$(whoami)+$(hostname)" -f ~/.ssh/id_ed25519 -N ""
  gh ssh-key add ~/.ssh/id_ed25519.pub --title "$(hostname)"
  # 既存clone済みrepoはSSHに切替
  git remote set-url origin git@github.com:Mekajiki/dotfiles.git
  ```
  `gh` を使うには別マシンで `admin:public_key` スコープ持ちの `gh auth login` 済みであることが前提。
- **言語ランタイムの具体バージョン**
  ```sh
  rbenv install 3.3.6 && rbenv global 3.3.6
  nvm install --lts
  ```
- **Claude Code CLI のログイン**（`/login`）
- **gcloud / kubectl などのクラウド系**（必要なら個別に）
- **WSL 限定の事前作業**: `%UserProfile%\.wslconfig` に `[wsl2] networkingMode=mirrored` を入れて `wsl --shutdown`。これをやらないと Tailscale 経由の SSH が PMTU 起因でハングする。

## Claude Code 並行作業

同一リポで複数の Claude セッションを並行させるための `cl` コマンドと自動掃除フックを提供。詳細は [`docs/claude-worktree.md`](docs/claude-worktree.md)。

## 個別ファイル

- `link_files.sh` — dotfiles を `$HOME` に symlink する単独実行用スクリプト（`install.sh` から呼ばれる）
- `src/` — 配布対象の dotfiles
- `src/ghostty/config.ghostty` — `~/.config/ghostty/config.ghostty` に symlink。Ghostty の設定（XDG パスなので mac/Linux 共通、`config.ghostty` は 1.2.3 以降の正式名）
- `src/claude-settings.local.json` — `~/.claude/settings.local.json` に symlink。Claude Code 本体が書き込まないため symlink 可、permissions / enabledPlugins / theme / hooks など dotfiles で同期したい設定をすべてここに置く（`settings.json` と Claude Code 側でマージされる）
- `src/CLAUDE.md` — Claude Code 用のグローバル指示
- `src/claude-hooks/` — Claude Code の SessionStart / SessionEnd で動かすシェルスクリプト（worktree 自動掃除など）
- `src/claude-skills/` — Claude Code のスキル（`~/.claude/skills/` に symlink）。PR レビュー、Slack 読み書き、ディスク掃除（`/disk-cleanup`）
- `docs/` — 設計文書
