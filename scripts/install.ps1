# rackup installer for Windows (PowerShell 5.1 or later).
#
#   powershell -ExecutionPolicy Bypass -c "irm https://samth.github.io/rackup/install.ps1 | iex"
#
# Installs rackup into %LOCALAPPDATA%\rackup (or $env:RACKUP_HOME):
#   bin\rackup-core.exe  the prebuilt rackup (when one is published for this arch)
#   libexec\             rackup's Racket sources (source installs) and rackup-shim.exe
#   runtime\             a Minimal Racket that runs rackup itself (source installs)
#   shims\rackup.exe     copies of rackup-shim.exe; `rackup reshim` adds racket.exe, raco.exe, ...
# adds the shims folder to the user's PATH, and adds `rackup switch`
# support to the PowerShell profile.  Nothing needs administrator rights,
# and no symbolic links are used.
#
# `rackup self-upgrade` runs this script with -SelfUpgrade.  A running
# executable can be renamed but not overwritten, so files that are in use
# (the rackup.exe shim, rackup-core.exe) are renamed to .rackup-stale-*
# and deleted by a later run.
#
# The Pages build (pages/build-pages-site.rkt) fills in the @@...@@
# checksums.  -SourceDir, -ShimExe and -ExeArchive install from local
# files, for testing a checkout.

[CmdletBinding()]
param(
  [string]$RackupHome,
  # Install from source even when a prebuilt rackup-core.exe is published.
  [switch]$Source,
  # Require the prebuilt rackup-core.exe.
  [switch]$Exe,
  # Use rackup sources from this checkout instead of downloading them.
  [string]$SourceDir,
  # Use this rackup-shim.exe instead of downloading it.
  [string]$ShimExe,
  # Use this prebuilt rackup-<arch>-win32.tar.gz instead of downloading it.
  [string]$ExeArchive,
  # Install the sources of this git ref (branch, tag or commit) from GitHub.
  [string]$Ref,
  [string]$Repo = 'samth/rackup',
  # Leave the user's PATH and RACKUP_HOME alone.
  [switch]$NoModifyPath,
  # Leave the PowerShell profile alone.
  [switch]$NoInit,
  # Set by `rackup self-upgrade`.
  [switch]$SelfUpgrade
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # Invoke-WebRequest is very slow with the progress bar
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$PagesBase = if ($env:PAGES_BASE_URL) { $env:PAGES_BASE_URL.TrimEnd('/') } else { 'https://samth.github.io/rackup' }
$SrcSha256 = '@@RACKUP_SRC_SHA256@@'
$ShimSha256 = @{
  'x86_64'  = '@@RACKUP_SHIM_X86_64_SHA256@@'
  'aarch64' = '@@RACKUP_SHIM_AARCH64_SHA256@@'
}
# "filename:sha256" lines for the stable Minimal Racket installers.
$RuntimeChecksums = @'
@@RACKUP_RUNTIME_CHECKSUMS@@
'@

function Write-Step($msg) { Write-Host "rackup: $msg" }

function Test-Placeholder($s) { return $s.StartsWith('@@') }

function Get-Sha256($path) { return (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant() }

function Get-File($url, $dest, $sha256) {
  Write-Step "downloading $url"
  Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $dest
  if ($sha256 -and -not (Test-Placeholder $sha256)) {
    $actual = Get-Sha256 $dest
    if ($actual -ne $sha256.ToLowerInvariant()) {
      throw "checksum mismatch for $url (expected $sha256, got $actual)"
    }
  }
}

# Delete `path`, or, when it is in use (a running executable or a loaded
# DLL), rename it aside so its name is free.  Remove-StaleFiles deletes it
# later.
function Remove-OrRename($path) {
  if (-not (Test-Path -LiteralPath $path)) { return }
  try {
    Remove-Item -LiteralPath $path -Force -ErrorAction Stop
  } catch {
    $aside = Join-Path (Split-Path -Parent $path) (".rackup-stale-" + [Guid]::NewGuid().ToString('N') + "-" + (Split-Path -Leaf $path))
    Move-Item -LiteralPath $path -Destination $aside -Force
  }
}

function Remove-StaleFiles($dir) {
  if (-not (Test-Path -LiteralPath $dir)) { return }
  Get-ChildItem -LiteralPath $dir -Recurse -Force -Filter '.rackup-stale-*' -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
}

# Make directory `dest` hold exactly the files of `src`, file by file, so
# that files in use are renamed aside instead of failing the whole copy.
function Install-Tree($src, $dest) {
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  $src = (Resolve-Path -LiteralPath $src).Path.TrimEnd('\')
  $dest = (Resolve-Path -LiteralPath $dest).Path.TrimEnd('\')
  $wanted = @{}
  foreach ($f in Get-ChildItem -LiteralPath $src -Recurse -Force -File) {
    $rel = $f.FullName.Substring($src.Length + 1)
    $wanted[$rel.ToLowerInvariant()] = $true
    $target = Join-Path $dest $rel
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    Remove-OrRename $target
    Copy-Item -LiteralPath $f.FullName -Destination $target
  }
  foreach ($f in Get-ChildItem -LiteralPath $dest -Recurse -Force -File) {
    $rel = $f.FullName.Substring($dest.Length + 1)
    if (-not $wanted.ContainsKey($rel.ToLowerInvariant()) -and -not $f.Name.StartsWith('.rackup-stale-')) {
      Remove-OrRename $f.FullName
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

# The execution policy a new PowerShell session gets (ignoring the Process
# scope, which `powershell -ExecutionPolicy Bypass` sets for this one).
function Get-ProfileExecutionPolicy {
  $list = Get-ExecutionPolicy -List
  foreach ($scope in 'MachinePolicy', 'UserPolicy', 'CurrentUser', 'LocalMachine') {
    $p = "$(($list | Where-Object { "$($_.Scope)" -eq $scope }).ExecutionPolicy)"
    if ($p -and $p -ne 'Undefined') { return $p }
  }
  return 'Undefined'
}

# Racket's installer names: x86_64, arm64, i386.  rackup's own ids
# normalize arm64 to aarch64.
switch ($env:PROCESSOR_ARCHITECTURE) {
  'AMD64' { $InstallerArch = 'x86_64'; $Arch = 'x86_64' }
  'ARM64' { $InstallerArch = 'arm64'; $Arch = 'aarch64' }
  default { throw "unsupported processor architecture: $env:PROCESSOR_ARCHITECTURE" }
}

# For CI: `rackup self-upgrade` passes only its own options, so a test
# points the upgrade at local files through these variables.
if ($env:RACKUP_TESTING) {
  if (-not $ShimExe -and $env:RACKUP_TEST_SHIM_EXE) { $ShimExe = $env:RACKUP_TEST_SHIM_EXE }
  if (-not $ExeArchive -and $env:RACKUP_TEST_EXE_ARCHIVE) { $ExeArchive = $env:RACKUP_TEST_EXE_ARCHIVE }
  if (-not $SourceDir -and $env:RACKUP_TEST_SOURCE_DIR) { $SourceDir = $env:RACKUP_TEST_SOURCE_DIR }
}

if ($Source -and $Exe) { throw "-Source and -Exe are mutually exclusive" }
if ($Exe -and ($SourceDir -or $Ref)) { throw "-Exe cannot be combined with -SourceDir or -Ref" }

if (-not $RackupHome) {
  $RackupHome = if ($env:RACKUP_HOME) { $env:RACKUP_HOME } else { Join-Path $env:LOCALAPPDATA 'rackup' }
}
$RackupHome = [IO.Path]::GetFullPath($RackupHome)
$Bin = Join-Path $RackupHome 'bin'
$Libexec = Join-Path $RackupHome 'libexec'
$Shims = Join-Path $RackupHome 'shims'
$Runtime = Join-Path $RackupHome 'runtime'
foreach ($d in @($RackupHome, $Shims)) {
  New-Item -ItemType Directory -Force -Path $d | Out-Null
}
foreach ($d in @($Bin, $Libexec, $Shims)) { Remove-StaleFiles $d }

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("rackup-install-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Tmp | Out-Null
try {
  # --- prebuilt rackup-core.exe, unless installing from source --------------
  $ExeStage = $null
  $InstalledSha = $null
  if (-not ($Source -or $SourceDir -or $Ref)) {
    $exeName = "rackup-$Arch-win32.tar.gz"
    $archive = Join-Path $Tmp $exeName
    try {
      if ($ExeArchive) {
        Copy-Item -LiteralPath $ExeArchive -Destination $archive
        $InstalledSha = Get-Sha256 $archive
      } else {
        $shaFile = Join-Path $Tmp "$exeName.sha256"
        Invoke-WebRequest -UseBasicParsing -Uri "$PagesBase/$exeName.sha256" -OutFile $shaFile
        $InstalledSha = ((Get-Content -LiteralPath $shaFile -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
        if ($SelfUpgrade -and (Test-Path -LiteralPath (Join-Path $Bin 'rackup-core.exe')) -and
            (Test-Path -LiteralPath (Join-Path $RackupHome '.installed-sha256')) -and
            ((Get-Content -LiteralPath (Join-Path $RackupHome '.installed-sha256') -Raw).Trim() -eq $InstalledSha)) {
          Write-Step "rackup is up to date"
          return
        }
        Get-File "$PagesBase/$exeName" $archive $InstalledSha
      }
      $ExeStage = Join-Path $Tmp 'exe'
      New-Item -ItemType Directory -Path $ExeStage | Out-Null
      & tar.exe -xzf $archive -C $ExeStage
      if ($LASTEXITCODE -ne 0) { throw "failed to extract $exeName" }
      if (-not (Test-Path -LiteralPath (Join-Path $ExeStage 'rackup\bin\rackup-core.exe'))) {
        throw "$exeName has no rackup\bin\rackup-core.exe"
      }
    } catch {
      if ($Exe) { throw "no prebuilt rackup for $Arch Windows: $_" }
      Write-Step "no prebuilt rackup for $Arch Windows ($($_.Exception.Message)); installing from source"
      $ExeStage = $null
      $InstalledSha = $null
    }
  }

  # --- rackup sources (source installs) --------------------------------------
  $stage = Join-Path $Tmp 'libexec'
  if ($ExeStage) {
    New-Item -ItemType Directory -Path $stage | Out-Null
  } else {
    if ($SourceDir) {
      $SrcRoot = (Resolve-Path -LiteralPath $SourceDir).Path
    } elseif ($Ref) {
      $tarball = Join-Path $Tmp 'rackup-ref.tar.gz'
      Get-File "https://codeload.github.com/$Repo/tar.gz/$Ref" $tarball $null
      $refDir = Join-Path $Tmp 'ref'
      New-Item -ItemType Directory -Path $refDir | Out-Null
      & tar.exe -xzf $tarball -C $refDir
      if ($LASTEXITCODE -ne 0) { throw "failed to extract the sources of $Repo $Ref" }
      $SrcRoot = (Get-ChildItem -LiteralPath $refDir -Directory | Select-Object -First 1).FullName
    } else {
      $tarball = Join-Path $Tmp 'rackup-src.tar.gz'
      Get-File "$PagesBase/rackup-src.tar.gz" $tarball $SrcSha256
      if (-not (Test-Placeholder $SrcSha256)) { $InstalledSha = $SrcSha256 }
      # tar.exe ships with Windows 10 1803 and later.
      & tar.exe -xzf $tarball -C $Tmp
      if ($LASTEXITCODE -ne 0) { throw "failed to extract rackup-src.tar.gz" }
      $SrcRoot = Join-Path $Tmp 'rackup-src'
    }
    Copy-Item -Recurse -LiteralPath (Join-Path $SrcRoot 'libexec') -Destination $stage
    Get-ChildItem -LiteralPath $stage -Recurse -Directory -Filter compiled | Remove-Item -Recurse -Force
  }

  # --- shim dispatcher -------------------------------------------------------
  $shimStage = Join-Path $stage 'rackup-shim.exe'
  if ($ShimExe) {
    Copy-Item -LiteralPath $ShimExe -Destination $shimStage
  } else {
    Get-File "$PagesBase/rackup-shim-$Arch-win32.exe" $shimStage $ShimSha256[$Arch]
  }

  # --- put the files in place -------------------------------------------------
  Install-Tree $stage $Libexec
  if ($ExeStage) {
    Install-Tree (Join-Path $ExeStage 'rackup\bin') $Bin
  } else {
    Remove-OrRename (Join-Path $Bin 'rackup-core.exe')
  }
  $rackupShim = Join-Path $Shims 'rackup.exe'
  $newShim = Join-Path $Libexec 'rackup-shim.exe'
  if (-not (Test-Path -LiteralPath $rackupShim) -or (Get-Sha256 $rackupShim) -ne (Get-Sha256 $newShim)) {
    Remove-OrRename $rackupShim
    Copy-Item -LiteralPath $newShim -Destination $rackupShim
  }

  # --- hidden runtime (source installs) ---------------------------------------
  if (-not $ExeStage) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Runtime 'versions') | Out-Null
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
      $rbin = Join-Path $install 'racket'
      Set-DirPointer (Join-Path $versionDir 'bin') $rbin

      # rackup's shell helpers need scribble/text, which Minimal Racket lacks.
      Write-Step "installing scribble-text-lib into the hidden runtime"
      & (Join-Path $rbin 'raco.exe') pkg install --scope installation --no-docs --auto --skip-installed --batch scribble-text-lib
      if ($LASTEXITCODE -ne 0) { throw "failed to install scribble-text-lib into the hidden runtime" }
      Set-DirPointer $current $versionDir
    }
  }

  # --- let rackup finish: record the runtime, compile itself, make shims ---
  $env:RACKUP_HOME = $RackupHome
  if (-not $ExeStage) {
    & $rackupShim runtime install
    if ($LASTEXITCODE -ne 0) { throw "rackup runtime install failed" }
  }
  & $rackupShim reshim | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "rackup reshim failed" }
  $shaFile = Join-Path $RackupHome '.installed-sha256'
  if ($InstalledSha) {
    [IO.File]::WriteAllText($shaFile, "$InstalledSha`n")
  } elseif (Test-Path -LiteralPath $shaFile) {
    Remove-Item -LiteralPath $shaFile -Force
  }
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

# --- PowerShell profile ----------------------------------------------------
$initDone = $false
if (-not $NoInit) {
  $policy = Get-ProfileExecutionPolicy
  if ($policy -in 'Restricted', 'AllSigned', 'Undefined') {
    Write-Step "skipping the PowerShell profile: the execution policy ($policy) does not run profile scripts."
    Write-Step "To enable ``rackup switch``, run: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned; rackup init"
  } else {
    & (Join-Path $Shims 'rackup.exe') init --shell powershell
    if ($LASTEXITCODE -ne 0) { throw "rackup init failed" }
    $initDone = $true
  }
}

if ($SelfUpgrade) { return }

Write-Host ""
Write-Host "rackup is installed in $RackupHome."
if ($initDone) {
  Write-Host "Open a new terminal (or run: . `$PROFILE.CurrentUserAllHosts), then run:"
} else {
  Write-Host "Open a new terminal, then run:"
}
Write-Host "  rackup install stable"
Write-Host "The full distribution is unpacked with 7-Zip (winget install 7zip.7zip);"
Write-Host "without it, use: rackup install stable --distribution minimal"
