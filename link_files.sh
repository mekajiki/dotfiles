#!/bin/sh
base_dir=`pwd`/$(dirname $0)/src

# Link dotfiles to $HOME
cd $HOME
ln -sfn $base_dir/.[a-z]* ./



# Ghostty config (config.ghostty は 1.2.3 以降の正式名。XDG パスなら mac/Linux 共通)
mkdir -p $HOME/.config/ghostty
ln -sfn $base_dir/ghostty/config.ghostty $HOME/.config/ghostty/config.ghostty

# Claude Code config
# ~/.claude = 個人アカウント，~/.claude-anipos = アニポス会社アカウント（CLAUDE_CONFIG_DIR で切替．.zshrc の claude 関数参照）．
# 両方に同じ CLAUDE.md / hooks / skills / settings.local.json を張る．
for claude_dir in $HOME/.claude $HOME/.claude-anipos; do
  mkdir -p $claude_dir
  ln -sfn $base_dir/CLAUDE.md $claude_dir/

  # Claude Code hooks
  mkdir -p $claude_dir/hooks
  for hook in $base_dir/claude-hooks/*.sh; do
    [ -e "$hook" ] || continue
    ln -sfn "$hook" $claude_dir/hooks/
  done

  # Claude Code skills (ディレクトリ単位で symlink。各 skill は <name>/SKILL.md)
  mkdir -p $claude_dir/skills
  for skill in $base_dir/claude-skills/*/; do
    [ -d "$skill" ] || continue
    ln -sfn "${skill%/}" $claude_dir/skills/
  done

  # settings.local.json は Claude 本体が書き込まないので symlink して dotfiles から管理する。
  # permissions / enabledPlugins / hooks 等の dotfiles で同期したい設定はここに置く。
  # settings.json と Claude Code 側でマージされ、scalar は settings.local が優先、
  # array は連結+重複排除、object は deep merge される。
  ln -sfn "$base_dir/claude-settings.local.json" "$claude_dir/settings.local.json"
done
