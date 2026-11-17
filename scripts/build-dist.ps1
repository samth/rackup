# Build a prebuilt Windows distribution of rackup with raco exe and
# raco distribute (the Windows counterpart of scripts/build-dist.sh).
#
#   scripts/build-dist.ps1 -Output dist/rackup-x86_64-win32.tar.gz
#
# The tarball holds:
#   rackup/bin/rackup-core.exe   rackup, with its Racket runtime embedded
#   rackup/bin/lib/...           whatever raco distribute puts next to it
# install.ps1 unpacks rackup/bin into RACKUP_HOME\bin, where the rackup.exe
# shim looks for rackup-core.exe.

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Output,
  [string]$Raco = 'raco'
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("rackup-build-dist-" + [Guid]::NewGuid().ToString('N'))
$Build = Join-Path $Tmp 'build'
$Dist = Join-Path $Tmp 'dist'
$Stage = Join-Path $Tmp 'rackup'
New-Item -ItemType Directory -Force -Path $Build, $Dist, (Join-Path $Stage 'bin') | Out-Null
$VersionFile = Join-Path $Root 'build-version.txt'

function Invoke-Checked {
  & $args[0] @($args | Select-Object -Skip 1)
  if ($LASTEXITCODE -ne 0) { throw "command failed ($LASTEXITCODE): $($args -join ' ')" }
}

try {
  # Bake version info into the build, as build-dist.sh does.
  $commit = (& git -C $Root rev-parse --short HEAD 2>$null)
  $date = (& git -C $Root log -1 --format=%ci HEAD 2>$null)
  if ($commit) {
    $line = if ($date) { "rackup $commit ($date)" } else { "rackup $commit" }
    [IO.File]::WriteAllText($VersionFile, "$line`n")
    Write-Host "Baked version: $line"
  }

  $exe = Join-Path $Build 'rackup-core.exe'
  Invoke-Checked $Raco exe -o $exe (Join-Path $Root 'libexec\rackup-core.rkt')
  Invoke-Checked $Raco distribute $Dist $exe

  # raco distribute puts Windows executables at the top of the directory
  # and support files under lib\; keep that shape inside bin\.
  $built = Get-ChildItem -LiteralPath $Dist -Recurse -File -Filter 'rackup-core.exe' | Select-Object -First 1
  if (-not $built) { throw "raco distribute produced no rackup-core.exe" }
  if ($built.DirectoryName -ne $Dist) { throw "unexpected raco distribute layout: $($built.FullName)" }
  Copy-Item -Recurse -Path (Join-Path $Dist '*') -Destination (Join-Path $Stage 'bin')

  $outDir = Split-Path -Parent ([IO.Path]::GetFullPath($Output))
  New-Item -ItemType Directory -Force -Path $outDir | Out-Null
  Invoke-Checked tar.exe -C $Tmp -czf ([IO.Path]::GetFullPath($Output)) rackup
  Write-Host "Built: $Output"
} finally {
  Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $VersionFile -Force -ErrorAction SilentlyContinue
}
