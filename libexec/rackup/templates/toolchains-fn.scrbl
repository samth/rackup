_rackup_toolchains() {
  local dir="${RACKUP_HOME:-$HOME/.rackup}/toolchains"
  if [ -d "$dir" ]; then
    local f
    for f in "$dir"/*/; do
      [ -d "$f" ] && basename "$f"
    done
  fi
}
