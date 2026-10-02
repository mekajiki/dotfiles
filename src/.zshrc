sumContribution(){
  author=$2
  if [ -z "$author" ]; then author='ii.hsif.drows@gmail.com'; fi
  echo "Author: $author"
  git log --author=$author --shortstat --since=$1 |grep 'files\? changed' | awk '{files+=$1; inserted+=$4; deleted+=$6} END {print "files changed", files, "lines inserted:", inserted, "lines deleted:", deleted}'
}

#by os settings
case ${OSTYPE} in
  darwin*)
    setopt hist_ignore_dups share_history inc_append_history extended_history

    fpath=($(brew --prefix)/share/zsh/site-functions $fpath)
    os_logo="🍎"
      ;;
  linux*)
    setopt hist_ignore_dups share_history inc_append_history
    if [[ -n $WSL_DISTRO_NAME ]] || grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null; then
      # WSL: bridge to the Windows clipboard so pbcopy/pbpaste work without WSLg/X.
      alias pbcopy='clip.exe'
      alias pbpaste="powershell.exe -NoProfile -Command Get-Clipboard | sed -e 's/\r\$//'"
    else
      alias pbcopy='xclip -selection clipboard'
      alias pbpaste='xclip -selection clipboard -o'
    fi
    os_logo="🐧"
      ;;
esac

# env
#
# timg をオプション無しで kitty graphics protocol 描画させる
export TIMG_PIXELATION=k

#aliases
#
alias f='fg'
alias v='vim'
alias m='make'
alias ls="ls -Gv"
#git aliases
if (( $+commands[hub] )) {
  eval "$(hub alias -s)"
}
alias g='git'
alias gf='git flow'
alias gs='git status -s -b'
alias gb='git branch --color'
alias gco='git checkout'
alias ga='git add'
alias gl='git log'
alias gls='git ls-files | grep'
alias gc='git commit -v'
alias gst='git stash'
alias gpull='git pull'
alias gpush='git push'
alias gpushf='git push --force-with-lease'
alias gdif='git diff --color=always'
alias gg='git grep'
alias ggn='git grep --name-only'
alias grb='git rebase'
alias gpr='git pull-request -p -o'

alias grm='git redmine'

alias ghqg='git get -p'

alias today="sumContribution 1.day"
alias week="sumContribution 1.week"

alias d="docker compose"
alias dr="docker compose exec server rails"

alias fl="flutter"

alias tp="tmux show-buffer |pbcopy"

alias pomoi='pomo incomplete last'
alias pomoc='pomo complete'
alias pomos='pomo start'
alias pomob='pomo break'
alias pomoa='pomo add'

alias json='python -m json.tool'

alias prs='ps aux | grep'

alias dl='gradle'

alias node='nodejs'

# comp
#
autoload -Uz compinit
compinit
HISTFILE=~/.histfile
HISTSIZE=1000000
SAVEHIST=1000000
autoload history-search-end
zle -N history-beginning-search-backward-end history-search-end
zle -N history-beginning-search-forward-end history-search-end
bindkey -e
bindkey "^P" history-beginning-search-backward-end
bindkey "^N" history-beginning-search-forward-end

# auto change directory
#
setopt auto_cd

# use #, ~, ^ as regexp in filename
#
setopt extended_glob

fpath=(~/.zsh $fpath)

# correct spell miss
#
setopt correct

# RSENSE
#
zstyle :compinstall filename '~/.zshrc'

# About ls command
#
zstyle ':completion:*' list-colors 'di=36' 'ln=35' 'ex=31' 'bd=37;46' 'cd=36;43'

# end About ls command

# z - jump around (zoxide)
#
# rupa/z の後継。`z foo` で frecency ジャンプ、`zi foo` で fzf による絞り込み。
# --cmd z で従来どおり `z` のコマンド名を維持する。
eval "$(zoxide init zsh --cmd z)"

# 引数なしの `z`、および query が当たらなかったときも fzf 絞り込みに落とす。
# zi (zoxide --interactive) は zoxide の非ファジーマッチで先に絞るためタイポに弱い。
# そこで no match 時は全リストを fzf に流し、タイポ文字列を fzf の --query に渡す。
# fzf はファジーなので入れ替わり程度のタイポでも候補に残り、--select-1 で一意なら即移動。
function z() {
  if [[ $# -eq 0 ]]; then
    __zoxide_zi
  else
    __zoxide_z "$@" 2>/dev/null || {
      local dir
      dir="$(zoxide query --list | fzf --height=40% --reverse --select-1 --query="$*")" \
        && __zoxide_cd "$dir"
    }
  fi
}

# fzf 自体は z()/zi が fzf バイナリを直接呼ぶので shell 統合 (fzf --zsh) は読み込まない。
# 読み込むと Ctrl-R が標準のインクリメンタル履歴検索を奪って fzf ファジー検索に化けるため。

# Prompt
#
local CYAN=$'%{\e[1;36m%}'
local YELLOW=$'%{\e[1;33m%}'
local DEFAULT=$'%{\e[1;32m%}'

autoload -Uz vcs_info
zstyle ':vcs_info:*' enable git
zstyle ':vcs_info:*' check-for-changes true
zstyle ':vcs_info:*' unstagedstr '%F{yellow}改'
precmd() {
  local format_string='%F{white}%b'$DEFAULT':'

  if [[ -n $(git ls-files --modified 2> /dev/null) ]] {
    format_string+=' %u'
  }

  if [[ -n $(git ls-files --other --exclude-standard 2> /dev/null) ]] {
    format_string+='%F{red}未'
  }
  format_string+=' '

  zstyle ':vcs_info:git*' formats $format_string
  vcs_info

  # set current dir as the name of tmux window
  if [[ -n $TMUX ]]; then
    tmux rename-window -t "$TMUX_PANE" "${PWD:t}" || echo "Failed to set tmux window name"
  fi
}

setopt prompt_subst

PROMPT='%n'$YELLOW'@%M$os_logo :'$CYAN'%~%$
${vcs_info_msg_0_}'$DEFAULT'$ '
PROMPT2="%_%% "

## Gcloud[[ `which kubectl` ]] && source <(kubectl completion zsh)
[[ `which kubectl` ]] && source <(kubectl completion zsh)

## Pet
# Register the previous command
function prev() {
  PREV=$(fc -lrn | head -n 1)
  sh -c "pet new `printf %q "$PREV"`"
}

# alias
alias pe='pet exec'

[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion


# rbenv
eval "$(rbenv init - zsh)"

# The next line enables shell command completion for gcloud.
if [ -f '/usr/local/lib/google-cloud-sdk/completion.zsh.inc' ]; then . '/usr/local/lib/google-cloud-sdk/completion.zsh.inc'; fi

# >>> grok installer >>>
export PATH="$HOME/.grok/bin:$PATH"
fpath=(~/.grok/completions/zsh $fpath)
autoload -Uz compinit && compinit -C
# <<< grok installer <<<

# Antigravity CLI
export PATH="$HOME/.local/bin:$PATH"
