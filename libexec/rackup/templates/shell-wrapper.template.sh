#lang scribble/text
rackup() {
  local _rackup_bin="${RACKUP_HOME:-$HOME/.rackup}/bin/rackup"
  if [ "$#" -gt 0 ]; then
    case "$1" in
      shell|switch)
        if [ "$#" -ge 2 ] && [ "$2" != "--help" ] && [ "$2" != "-h" ]; then
          local _rackup_cmd="$1"
          local _rackup_eval _rackup_status
          shift
          _rackup_eval="$("$_rackup_bin" "$_rackup_cmd" "$@")"
          _rackup_status=$?
          if [ "$_rackup_status" -ne 0 ]; then
            return "$_rackup_status"
          fi
          eval "$_rackup_eval"
          return
        fi
        ;;
    esac
  fi
  "$_rackup_bin" "$@"
}
