
# rackup bash completion
_rackup_toolchains() {
  local dir="${RACKUP_HOME:-$HOME/.rackup}/toolchains"
  if [ -d "$dir" ]; then
    local f
    for f in "$dir"/*/; do
      [ -d "$f" ] && basename "$f"
    done
  fi
}

_rackup() {
  local cur prev words cword
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  words=("${COMP_WORDS[@"@"]}")
  cword=$COMP_CWORD

  local commands="@commands-line"

  if [ "$cword" -eq 1 ]; then
    COMPREPLY=($(compgen -W "$commands" -- "$cur"))
    return
  fi

  # flag argument completion
  case "$prev" in
    --variant)        COMPREPLY=($(compgen -W "cs bc" -- "$cur")); return ;;
    --distribution)   COMPREPLY=($(compgen -W "full minimal" -- "$cur")); return ;;
    --snapshot-site)  COMPREPLY=($(compgen -W "auto utah northwestern" -- "$cur")); return ;;
    --arch)           COMPREPLY=($(compgen -W "x86_64 aarch64 i386 arm riscv64 ppc" -- "$cur")); return ;;
    --installer-ext)  COMPREPLY=($(compgen -W "sh tgz dmg" -- "$cur")); return ;;
    --shell)          COMPREPLY=($(compgen -W "bash zsh" -- "$cur")); return ;;
    --toolchain)      COMPREPLY=($(compgen -W "$(_rackup_toolchains)" -- "$cur")); return ;;
    --ref|--repo|--limit|--jobs|-j) return ;;
  esac

  local cmd="${words[1]}"
@bash-command-cases
}

complete -F _rackup rackup
