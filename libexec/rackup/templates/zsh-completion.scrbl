
# rackup zsh completion
_rackup_toolchains() {
  local dir="${RACKUP_HOME:-$HOME/.rackup}/toolchains"
  if [ -d "$dir" ]; then
    local f
    for f in "$dir"/*/; do
      [ -d "$f" ] && basename "$f"
    done
  fi
}

# Emit toolchain id:description pairs for zsh _describe.
_rackup_toolchains_described() {
  local dir="${RACKUP_HOME:-$HOME/.rackup}/toolchains"
  [ -d "$dir" ] || return
  local f id meta version variant dist desc
  for f in "$dir"/*/; do
    [ -d "$f" ] || continue
    id=$(basename "$f")
    meta="$f/meta.rktd"
    desc="toolchain"
    if [ -f "$meta" ]; then
      version=$(sed -n "s/.*'resolved-version[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$meta" 2>/dev/null | head -n1)
      variant=$(sed -n "s/.*'variant[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$meta" 2>/dev/null | head -n1)
      dist=$(sed -n "s/.*'distribution[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$meta" 2>/dev/null | head -n1)
      if [ -n "$version" ]; then
        desc="$version${variant:+, $variant}${dist:+, $dist}"
      fi
    fi
    print -- "${id}:${desc}"
  done
}

_rackup() {
  local -a commands
  commands=(
@command-describe-list  )

  if (( CURRENT == 2 )); then
    _describe 'command' commands
    return
  fi

  local cmd="${words[2]}"
  case "$cmd" in
    available)
      _arguments \
        '--all[Show all versions]' \
        '--limit[Maximum versions to show]:n'
      ;;
    install)
      _arguments \
        '::spec:(stable pre-release snapshot snapshot\:utah snapshot\:northwestern)' \
        '--variant[VM variant]:variant:(cs bc)' \
        '--distribution[Distribution type]:distribution:(full minimal)' \
        '--snapshot-site[Snapshot mirror]:site:(auto utah northwestern)' \
        '--arch[Target architecture]:arch:(x86_64 aarch64 i386 arm riscv64 ppc)' \
        '--installer-ext[Force installer extension]:ext:(sh tgz dmg)' \
        '--set-default[Set as default]' \
        '--force[Force reinstall]' \
        '--no-cache[Skip download cache]' \
        '--short-aliases[Install short aliases r/dr]' \
        '--quiet[Quiet output]' \
        '--verbose[Verbose output]'
      ;;
    link)
      _arguments '1:name:' '2:path:_directories' '*:option:(--set-default --force)'
      ;;
    rebuild)
      local -a tcs
      tcs=(${(f)"$(_rackup_toolchains_described)"})
      _arguments \
        '--pull[Run git pull --ff-only first]' \
        '--jobs[Parallel jobs for make]:jobs' \
        '-j[Parallel jobs for make]:jobs' \
        '--dry-run[Print planned commands only]' \
        '--no-update-meta[Skip metadata refresh]' \
        "::toolchain:((${tcs}))"
      ;;
    list)
      _arguments '--ids[Print only toolchain IDs]'
      ;;
    default)
      local -a tcs
      tcs=(${(f)"$(_rackup_toolchains_described)"})
      _arguments \
        '--unset[Clear the default toolchain]' \
        "*::action:((id\:'show id' status\:'show set/unset' set\:'set default' clear\:'clear default' ${tcs}))"
      ;;
    current)
      _arguments "1:subcommand:((id\:'show id' source\:'show source' line\:'id and source'))"
      ;;
    which)
      local -a tcs
      tcs=(${(f)"$(_rackup_toolchains_described)"})
      _arguments \
        "--toolchain[Use specific toolchain]:toolchain:((${tcs}))" \
        '1:command:_command_names'
      ;;
    switch)
      local -a tcs
      tcs=(${(f)"$(_rackup_toolchains_described)"})
      _arguments \
        '--unset[Deactivate shell toolchain]' \
        "1:toolchain:((${tcs}))"
      ;;
    shell)
      local -a tcs
      tcs=(${(f)"$(_rackup_toolchains_described)"})
      _arguments \
        '--deactivate[Deactivate shell toolchain]' \
        "1:toolchain:((${tcs}))"
      ;;
    run)
      local -a tcs
      tcs=(${(f)"$(_rackup_toolchains_described)"})
      _arguments \
        "1:toolchain:((${tcs}))" \
        '*:command:_command_names'
      ;;
    prompt)
      _arguments \
        '--long[Long format: \[rk:<id>\]]' \
        '--short[Short format (default)]' \
        '--raw[Raw toolchain ID]' \
        '--source[ID and source]'
      ;;
    remove)
      local -a tcs
      tcs=(${(f)"$(_rackup_toolchains_described)"})
      _arguments \
        '--clean-compiled[Remove version-specific compiled directories]' \
        "1:toolchain:((${tcs}))"
      ;;
    reshim)
      _arguments \
        '(--no-short-aliases)--short-aliases[Enable short aliases r/dr]' \
        '(--short-aliases)--no-short-aliases[Remove short aliases]'
      ;;
    init)
      _arguments '--shell[Shell type]:shell:(bash zsh)'
      ;;
    uninstall)
      _arguments '--dangerously-delete-without-prompting[Skip confirmation prompt]'
      ;;
    self-upgrade)
      _arguments \
        '--with-init[Also update shell init]' \
        '(--source)--exe[Require prebuilt binary]' \
        '(--exe)--source[Install from source]' \
        '--ref[Git ref]:ref' \
        '--repo[GitHub repository]:owner/repo'
      ;;
    upgrade)
      _arguments \
        '--force[Reinstall even if up to date]' \
        '--no-cache[Re-download installer]' \
        '1:version:'
      ;;
    runtime)
      _arguments "1:subcommand:((status\:'show runtime status' install\:'install runtime' upgrade\:'upgrade runtime'))"
      ;;
    help)
      _arguments "1:command:(@|commands-line|)"
      ;;
  esac
}

if (( $+functions[compdef] )); then compdef _rackup rackup; fi
