  case "$cmd" in
    available)
      COMPREPLY=($(compgen -W "--all --limit" -- "$cur"))
      ;;
    install)
      COMPREPLY=($(compgen -W "stable pre-release snapshot snapshot:utah snapshot:northwestern --variant --distribution --snapshot-site --arch --installer-ext --set-default --force --no-cache --short-aliases --quiet --verbose" -- "$cur"))
      ;;
    link)
      if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "--set-default --force" -- "$cur"))
      elif [ "$cword" -ge 3 ]; then
        COMPREPLY=($(compgen -d -- "$cur"))
      else
        COMPREPLY=($(compgen -W "--set-default --force" -- "$cur"))
      fi
      ;;
    rebuild)
      COMPREPLY=($(compgen -W "--pull --jobs -j --dry-run --no-update-meta $(_rackup_toolchains)" -- "$cur"))
      ;;
    list)
      COMPREPLY=($(compgen -W "--ids" -- "$cur"))
      ;;
    default)
      COMPREPLY=($(compgen -W "id status set clear --unset $(_rackup_toolchains)" -- "$cur"))
      ;;
    current)
      COMPREPLY=($(compgen -W "id source line" -- "$cur"))
      ;;
    which)
      if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "--toolchain" -- "$cur"))
      else
        COMPREPLY=($(compgen -c -- "$cur"))
      fi
      ;;
    switch)
      COMPREPLY=($(compgen -W "--unset $(_rackup_toolchains)" -- "$cur"))
      ;;
    shell)
      COMPREPLY=($(compgen -W "--deactivate $(_rackup_toolchains)" -- "$cur"))
      ;;
    run)
      if [ "$cword" -eq 2 ]; then
        COMPREPLY=($(compgen -W "$(_rackup_toolchains)" -- "$cur"))
      else
        COMPREPLY=($(compgen -c -- "$cur"))
      fi
      ;;
    prompt)
      COMPREPLY=($(compgen -W "--long --short --raw --source" -- "$cur"))
      ;;
    remove)
      COMPREPLY=($(compgen -W "--clean-compiled $(_rackup_toolchains)" -- "$cur"))
      ;;
    reshim)
      COMPREPLY=($(compgen -W "--short-aliases --no-short-aliases" -- "$cur"))
      ;;
    init)
      COMPREPLY=($(compgen -W "--shell" -- "$cur"))
      ;;
    uninstall)
      COMPREPLY=($(compgen -W "--dangerously-delete-without-prompting" -- "$cur"))
      ;;
    self-upgrade)
      COMPREPLY=($(compgen -W "--with-init --exe --source --ref --repo" -- "$cur"))
      ;;
    upgrade)
      COMPREPLY=($(compgen -W "--force --no-cache" -- "$cur"))
      ;;
    runtime)
      COMPREPLY=($(compgen -W "status install upgrade" -- "$cur"))
      ;;
    help)
      COMPREPLY=($(compgen -W "$commands" -- "$cur"))
      ;;
  esac
