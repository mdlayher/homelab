# Shortcuts and convenience.

alias mkdir='mkdir -p'

# git

alias ga='git add'
#compdef _git ga=git-add
alias gd='git diff'
#compdef _git gd=git-diff
alias gds='git diff --staged'
#compdef _git gds=git-diff
alias gcp='git cherry-pick'
#compdef _git gcp=git-cherry-pick
alias glg='git log --stat --color'
#compdef _git glg=git-log
alias gst='git status'
alias gs='git status'
#compdef _git gst=git-status
alias gp='git push'
#compdef _git gp=git-push
alias gl='git pull'
#compdef _git gl=git-pull
alias gc='git commit -s -v -S'
#compdef _git gc=git-commit
alias gco='git checkout'
#compdef _git gco=git-checkout
alias gb='git branch'
#compdef _git gb=git-branch
alias grhh='git reset HEAD --hard'
#compdef _git grhh=git-reset
alias grm='git rebase origin main'
#compdef _git grm=git-rebase
