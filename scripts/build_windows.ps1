#Requires -Version 5.1
<#
.SYNOPSIS
Prepare a Windows LLVM plugin toolchain and build Amice with MSVC.
.EXAMPLE
powershell -ExecutionPolicy Bypass -File scripts/build_windows.ps1 -Setup -SmokeTest
.EXAMPLE
.\scripts\build_windows.ps1 -LlvmPrefix C:\llvm20 -LinkHost opt -SmokeTest
#>
[CmdletBinding()]
param(
    [ValidateSet(18, 19, 20)][int]$LlvmMajor = 20,
    [string]$LlvmPrefix,
    [string]$ClangPrefix,
    [ValidateSet('opt', 'lld')][string]$LinkHost = 'opt',
    [string]$TargetDir,
    [switch]$Setup,
    [switch]$SmokeTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'This script requires Windows x64.' }
if ($SmokeTest -and $LinkHost -ne 'opt') {
    throw '-SmokeTest requires -LinkHost opt. An lld-linked DLL must be loaded by LLD during LTO.'
}
$Workspace = Split-Path -Parent $PSScriptRoot
$PrefixVariable = "LLVM_SYS_${LlvmMajor}1_PREFIX"
if (-not $LlvmPrefix) { $LlvmPrefix = [Environment]::GetEnvironmentVariable($PrefixVariable) }
if (-not $LlvmPrefix) { $LlvmPrefix = Join-Path $Workspace ".local\toolchains\llvm$LlvmMajor-windows-x86_64\llvm" }
$LlvmPrefix = [IO.Path]::GetFullPath($LlvmPrefix)
if (-not $ClangPrefix) {
    if (Test-Path "$LlvmPrefix\bin\clang.exe") { $ClangPrefix = $LlvmPrefix }
    else { $ClangPrefix = Join-Path $Workspace ".local\toolchains\clang$LlvmMajor-windows-x86_64" }
}
$ClangPrefix = [IO.Path]::GetFullPath($ClangPrefix)

if ($Setup -and -not (Test-Path "$LlvmPrefix\bin\llvm-config.exe")) {
    $Versions = @{ 18 = '18.1.2-rust-1.78'; 19 = '19.1.5-rust-1.84'; 20 = '20.1.1-rust-1.87' }
    $Version = $Versions[$LlvmMajor]
    $ArchiveName = "llvm-lld-$Version-windows-x86_64.7z"
    $DownloadDir = Join-Path $Workspace '.local\downloads'
    New-Item -ItemType Directory -Force $DownloadDir | Out-Null
    $Archive = Join-Path $DownloadDir $ArchiveName
    if (-not (Test-Path $Archive)) {
        $Download = "$Archive.part"
        Write-Host "Downloading LLVM $Version plugin development toolchain..."
        & curl.exe --fail --location --retry 3 --speed-limit 102400 --speed-time 30 --continue-at - --connect-timeout 30 --output $Download "https://github.com/jamesmth/llvm-project/releases/download/v$Version/$ArchiveName"
        if ($LASTEXITCODE -ne 0) { throw 'LLVM download failed; rerun with -Setup to retry.' }
        Move-Item -LiteralPath $Download -Destination $Archive -Force
    }
    # The upstream archive has a top-level llvm/ directory. Never merge a
    # partially extracted installation into an existing prefix.
    $Stage = Join-Path $DownloadDir ("extract-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $Stage | Out-Null
    try {
        & tar.exe -xf $Archive -C $Stage
        if ($LASTEXITCODE -ne 0) { throw "Cannot extract $Archive; remove a corrupt cached archive and retry." }
        $Extracted = Join-Path $Stage 'llvm'
        if (-not (Test-Path "$Extracted\bin\llvm-config.exe")) { throw 'Unexpected LLVM archive layout.' }
        if (Test-Path $LlvmPrefix) { throw "Refusing to overwrite incomplete LLVM prefix: $LlvmPrefix" }
        New-Item -ItemType Directory -Force (Split-Path -Parent $LlvmPrefix) | Out-Null
        Move-Item -LiteralPath $Extracted -Destination $LlvmPrefix
    } finally {
        Remove-Item -LiteralPath $Stage -Recurse -Force
    }
}

foreach ($File in @('bin\llvm-config.exe', 'bin\LLVM-C.dll', "bin\$LinkHost.exe",
                     'lib\LLVM-C.lib', "lib\$LinkHost.lib", 'include\llvm\Config\llvm-config.h')) {
    if (-not (Test-Path (Join-Path $LlvmPrefix $File))) {
        throw "Missing $LlvmPrefix\$File. Use -Setup or provide a compatible -LlvmPrefix; the ordinary LLVM installer is insufficient."
    }
}
$VersionOutput = & "$LlvmPrefix\bin\llvm-config.exe" --version
if ($LASTEXITCODE -ne 0 -or $VersionOutput -notmatch "^$LlvmMajor\.1\.") {
    throw "Expected LLVM $LlvmMajor.1, found '$VersionOutput' in $LlvmPrefix"
}

# The plugin development archive intentionally contains opt/LLD but no clang.
# Fetch a matching official compiler only when executable smoke tests need it.
if ($Setup -and $SmokeTest -and -not (Test-Path "$ClangPrefix\bin\clang.exe")) {
    $ClangVersion = @{ 18 = '18.1.2'; 19 = '19.1.5'; 20 = '20.1.1' }[$LlvmMajor]
    $ClangPackage = "clang+llvm-$ClangVersion-x86_64-pc-windows-msvc"
    $DownloadDir = Join-Path $Workspace '.local\downloads'
    New-Item -ItemType Directory -Force $DownloadDir | Out-Null
    $ClangArchive = Join-Path $DownloadDir "$ClangPackage.tar.xz"
    if (-not (Test-Path $ClangArchive)) {
        Write-Host "Downloading matching Clang $ClangVersion for smoke tests..."
        & curl.exe --fail --location --retry 3 --speed-limit 102400 --speed-time 30 --continue-at - --connect-timeout 30 --output "$ClangArchive.part" "https://github.com/llvm/llvm-project/releases/download/llvmorg-$ClangVersion/$ClangPackage.tar.xz"
        if ($LASTEXITCODE -ne 0) { throw 'Clang download failed.' }
        Move-Item -LiteralPath "$ClangArchive.part" -Destination $ClangArchive -Force
    }
    $ClangStage = Join-Path $DownloadDir ("extract-clang-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $ClangStage | Out-Null
    try {
        Write-Host 'Extracting Clang compiler and resource headers...'
        & tar.exe -xf $ClangArchive -C $ClangStage --strip-components 1 "$ClangPackage/bin/clang.exe" "$ClangPackage/lib/clang"
        if ($LASTEXITCODE -ne 0) { throw 'Clang extraction failed.' }
        if (Test-Path $ClangPrefix) { throw "Refusing to overwrite incomplete Clang prefix: $ClangPrefix" }
        New-Item -ItemType Directory -Force (Split-Path -Parent $ClangPrefix) | Out-Null
        Move-Item -LiteralPath $ClangStage -Destination $ClangPrefix
    } finally {
        if (Test-Path $ClangStage) { Remove-Item -LiteralPath $ClangStage -Recurse -Force }
    }
}
if ($SmokeTest) {
    if (-not (Test-Path "$ClangPrefix\bin\clang.exe")) { throw 'Missing matching clang.exe. Use -Setup or provide -ClangPrefix.' }
    $ClangVersionOutput = & "$ClangPrefix\bin\clang.exe" --version
    if ($LASTEXITCODE -ne 0 -or ($ClangVersionOutput -join ' ') -notmatch "clang version $LlvmMajor\.") {
        throw "Clang must match LLVM $LlvmMajor; found $ClangVersionOutput"
    }
}

# Discover VS rather than requiring a Developer PowerShell or global PATH edit.
$VsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $VsWhere)) { throw 'Install Visual Studio Build Tools with Desktop development with C++ and a Windows SDK.' }
$VsPath = & $VsWhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $VsPath) { throw 'No MSVC x64 tools found. Install Desktop development with C++ and a Windows SDK.' }
Import-Module (Join-Path $VsPath 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll')
Enter-VsDevShell -VsInstallPath $VsPath -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64' | Out-Null
if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue) -or -not $env:WindowsSdkDir) {
    throw 'MSVC or Windows SDK initialization failed.'
}
if (-not (Get-Command cargo.exe -ErrorAction SilentlyContinue)) { throw 'Install Rust with rustup and the x86_64-pc-windows-msvc toolchain.' }

[Environment]::SetEnvironmentVariable($PrefixVariable, $LlvmPrefix, 'Process')
$env:PATH = "$LlvmPrefix\bin;$env:PATH"
# Do not inherit an Android/Linux cross compiler for the native C++ shims.
$env:CC_x86_64_pc_windows_msvc = 'cl.exe'
$env:CXX_x86_64_pc_windows_msvc = 'cl.exe'
if (-not $TargetDir) { $TargetDir = Join-Path $Workspace "target\windows-llvm$LlvmMajor-$LinkHost" }
$TargetDir = [IO.Path]::GetFullPath($TargetDir)
Push-Location $Workspace
try {
    Write-Host "Building LLVM $VersionOutput / $LinkHost with MSVC x64..."
    & cargo.exe build --locked --release -p amice --target x86_64-pc-windows-msvc --target-dir $TargetDir --no-default-features --features "llvm$LlvmMajor-1,win-link-$LinkHost"
    if ($LASTEXITCODE -ne 0) { throw 'Amice build failed.' }
    $Plugin = Join-Path $TargetDir 'x86_64-pc-windows-msvc\release\amice.dll'
    if (-not (Test-Path $Plugin)) { throw "Build did not produce $Plugin" }
    Write-Host "Built: $Plugin"
    if ($SmokeTest) {
        & (Join-Path $PSScriptRoot 'test_windows.ps1') -LlvmPrefix $LlvmPrefix -ClangPrefix $ClangPrefix -Plugin $Plugin
    }
} finally {
    Pop-Location
}
