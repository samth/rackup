# rackup installer for Windows (PowerShell 5.1 or later).
#
#   powershell -ExecutionPolicy Bypass -c "irm https://samth.github.io/rackup/install.ps1 | iex"
#
# Installs rackup into %LOCALAPPDATA%\rackup (or $env:RACKUP_HOME):
#   libexec\            rackup's Racket sources and rackup-shim.exe
#   runtime\            a Minimal Racket that runs rackup itself
#   shims\rackup.exe    copies of rackup-shim.exe; `rackup reshim` adds racket.exe, raco.exe, ...
# and adds the shims folder to the user's PATH.  Nothing needs
# administrator rights, and no symbolic links are used.
#
# The Pages build (pages/build-pages-site.rkt) fills in the @@...@@
# checksums.  Parameters exist for testing a checkout without the site.

[CmdletBinding()]
param(
  [string]$RackupHome,
  # Use rackup sources from this checkout instead of downloading them.
  [string]$SourceDir,
  # Use this rackup-shim.exe instead of downloading it.
  [string]$ShimExe,
  # Leave the user's PATH alone.
  [switch]$NoModifyPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # Invoke-WebRequest is very slow with the progress bar
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$PagesBase = if ($env:PAGES_BASE_URL) { $env:PAGES_BASE_URL.TrimEnd('/') } else { 'https://samth.github.io/rackup' }
$SrcSha256 = '@@RACKUP_SRC_SHA256@@'
$ShimSha256 = '@@RACKUP_SHIM_SHA256@@'
# "filename:sha256" lines for the stable Minimal Racket installers.
$RuntimeChecksums = @'
@@RACKUP_RUNTIME_CHECKSUMS@@
'@

function Write-Step($msg) { Write-Host "rackup: $msg" }

function Test-Placeholder($s) { return $s.StartsWith('@@') }

function Get-File($url, $dest, $sha256) {
  Write-Step "downloading $url"
  Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $dest
  if ($sha256 -and -not (Test-Placeholder $sha256)) {
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $dest).Hash.ToLowerInvariant()
    if ($actual -ne $sha256.ToLowerInvariant()) {
      throw "checksum mismatch for $url (expected $sha256, got $actual)"
    }
  }
}

# A directory pointer: a file holding the target directory's path
# (rackup's stand-in for a symlink on Windows; see fs.rkt).
function Set-DirPointer($path, $target) {
  if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
  [IO.File]::WriteAllText($path, "$target`n")
}

function Get-DirPointer($path) {
  if (Test-Path -LiteralPath $path -PathType Leaf) { return (Get-Content -LiteralPath $path -Raw).Trim() }
  return $path
}

# Racket's installer names: x86_64, arm64, i386.  rackup's own ids
# normalize arm64 to aarch64.
switch ($env:PROCESSOR_ARCHITECTURE) {
  'AMD64' { $InstallerArch = 'x86_64'; $Arch = 'x86_64' }
  'ARM64' { $InstallerArch = 'arm64'; $Arch = 'aarch64' }
  'x86'   { $InstallerArch = 'i386'; $Arch = 'i386' }
  default { throw "unsupported processor architecture: $env:PROCESSOR_ARCHITECTURE" }
}

if (-not $RackupHome) {
  $RackupHome = if ($env:RACKUP_HOME) { $env:RACKUP_HOME } else { Join-Path $env:LOCALAPPDATA 'rackup' }
}
$RackupHome = [IO.Path]::GetFullPath($RackupHome)
$Libexec = Join-Path $RackupHome 'libexec'
$Shims = Join-Path $RackupHome 'shims'
$Runtime = Join-Path $RackupHome 'runtime'
foreach ($d in @($RackupHome, $Shims, (Join-Path $Runtime 'versions'))) {
  New-Item -ItemType Directory -Force -Path $d | Out-Null
}

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("rackup-install-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Tmp | Out-Null
try {
  # --- rackup sources ------------------------------------------------------
  if ($SourceDir) {
    $SrcRoot = (Resolve-Path -LiteralPath $SourceDir).Path
  } else {
    $tarball = Join-Path $Tmp 'rackup-src.tar.gz'
    Get-File "$PagesBase/rackup-src.tar.gz" $tarball $SrcSha256
    # tar.exe ships with Windows 10 1803 and later.
    & tar.exe -xzf $tarball -C $Tmp
    if ($LASTEXITCODE -ne 0) { throw "failed to extract rackup-src.tar.gz" }
    $SrcRoot = Join-Path $Tmp 'rackup-src'
  }
  $stage = Join-Path $Tmp 'libexec'
  Copy-Item -Recurse -LiteralPath (Join-Path $SrcRoot 'libexec') -Destination $stage
  Get-ChildItem -LiteralPath $stage -Recurse -Directory -Filter compiled | Remove-Item -Recurse -Force

  # --- shim dispatcher -----------------------------------------------------
  $shimStage = Join-Path $stage 'rackup-shim.exe'
  if ($ShimExe) {
    Copy-Item -LiteralPath $ShimExe -Destination $shimStage
  } else {
    # One x86_64 build serves every arch: ARM64 Windows runs it emulated.
    Get-File "$PagesBase/rackup-shim-x86_64-win32.exe" $shimStage $ShimSha256
  }

  if (Test-Path -LiteralPath $Libexec) { Remove-Item -LiteralPath $Libexec -Recurse -Force }
  Move-Item -LiteralPath $stage -Destination $Libexec
  Copy-Item -Force -LiteralPath (Join-Path $Libexec 'rackup-shim.exe') -Destination (Join-Path $Shims 'rackup.exe')

  # --- hidden runtime (Minimal Racket) -------------------------------------
  $current = Join-Path $Runtime 'current'
  $currentRacket = Join-Path (Get-DirPointer (Join-Path (Get-DirPointer $current) 'bin')) 'racket.exe'
  if (Test-Path -LiteralPath $currentRacket) {
    Write-Step "hidden runtime already present"
  } else {
    $versionTxt = (Invoke-WebRequest -UseBasicParsing -Uri 'https://download.racket-lang.org/version.txt').Content
    if ($versionTxt -notmatch '\(stable "([^"]+)"\)') { throw "could not read the stable Racket version" }
    $ver = $Matches[1]
    $file = "racket-minimal-$ver-$InstallerArch-win32-cs.tgz"
    $sha = $null
    foreach ($line in ($RuntimeChecksums -split "`r?`n")) {
      $parts = $line.Trim() -split ':', 2
      if ($parts.Count -eq 2 -and $parts[0] -eq $file) { $sha = $parts[1] }
    }
    $archive = Join-Path $Tmp $file
    Get-File "https://download.racket-lang.org/installers/$ver/$file" $archive $sha

    $id = "runtime-$ver-cs-$Arch-win32-minimal"
    $versionDir = Join-Path $Runtime "versions\$id"
    $install = Join-Path $versionDir 'install'
    if (Test-Path -LiteralPath $versionDir) { Remove-Item -LiteralPath $versionDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $install | Out-Null
    Write-Step "extracting Minimal Racket $ver"
    & tar.exe -xzf $archive -C $install
    if ($LASTEXITCODE -ne 0) { throw "failed to extract $file" }
    $bin = Join-Path $install 'racket'
    Set-DirPointer (Join-Path $versionDir 'bin') $bin

    # rackup's shell helpers need scribble/text, which Minimal Racket lacks.
    Write-Step "installing scribble-text-lib into the hidden runtime"
    & (Join-Path $bin 'raco.exe') pkg install --scope installation --no-docs --auto --skip-installed --batch scribble-text-lib
    if ($LASTEXITCODE -ne 0) { throw "failed to install scribble-text-lib into the hidden runtime" }
    Set-DirPointer $current $versionDir
  }

  # --- let rackup finish: record the runtime, compile itself, make shims ---
  $env:RACKUP_HOME = $RackupHome
  $rackup = Join-Path $Shims 'rackup.exe'
  & $rackup runtime install
  if ($LASTEXITCODE -ne 0) { throw "rackup runtime install failed" }
  & $rackup reshim | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "rackup reshim failed" }
} finally {
  Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# --- PATH ----------------------------------------------------------------
if (-not $NoModifyPath) {
  # Edit HKCU\Environment directly so an existing REG_EXPAND_SZ Path keeps
  # its %VAR% references ([Environment]::SetEnvironmentVariable would
  # expand them and store REG_SZ).
  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
  try {
    $old = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $entries = @($old -split ';' | Where-Object { $_ -ne '' })
    if (-not ($entries | Where-Object { $_.TrimEnd('\') -ieq $Shims.TrimEnd('\') })) {
      $key.SetValue('Path', (@($Shims) + $entries) -join ';', [Microsoft.Win32.RegistryValueKind]::ExpandString)
      Write-Step "added $Shims to your user PATH"
    }
  } finally {
    $key.Close()
  }
  # Setting a user variable through .NET broadcasts WM_SETTINGCHANGE, so
  # newly started terminals see the PATH change too.
  [Environment]::SetEnvironmentVariable('RACKUP_HOME', $RackupHome, 'User')
}
if (-not (($env:Path -split ';') -contains $Shims)) { $env:Path = "$Shims;$env:Path" }

Write-Host ""
Write-Host "rackup is installed in $RackupHome."
Write-Host "Open a new terminal, then run:"
Write-Host "  rackup install stable"
Write-Host "The full distribution is unpacked with 7-Zip (winget install 7zip.7zip);"
Write-Host "without it, use: rackup install stable --distribution minimal"
