#Requires -Version 5.1
<#
.SYNOPSIS
Verify an opt-linked Windows Amice plugin using C/C++ executables.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$LlvmPrefix,
    [Parameter(Mandatory = $true)][string]$Plugin,
    [string]$ClangPrefix,
    [string]$OutputDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'target\windows-smoke')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$LlvmPrefix = (Resolve-Path $LlvmPrefix).Path
$Plugin = (Resolve-Path $Plugin).Path
if (-not $ClangPrefix) { $ClangPrefix = $LlvmPrefix }
$Clang = Join-Path (Resolve-Path $ClangPrefix).Path 'bin\clang.exe'
$Opt = Join-Path $LlvmPrefix 'bin\opt.exe'
foreach ($Tool in @($Clang, $Opt)) { if (-not (Test-Path $Tool)) { throw "Missing $Tool" } }
New-Item -ItemType Directory -Force $OutputDir | Out-Null
$OutputDir = (Resolve-Path $OutputDir).Path
$SavedEnvironment = @{}
Get-ChildItem Env: | Where-Object { $_.Name -like 'AMICE_*' -or $_.Name -eq 'RUST_LOG' -or $_.Name -eq 'PATH' } | ForEach-Object {
    $SavedEnvironment[$_.Name] = $_.Value
}
Push-Location $OutputDir
try {
    Get-ChildItem Env: | Where-Object { $_.Name -like 'AMICE_*' } | ForEach-Object { Remove-Item "Env:$($_.Name)" }
    $env:PATH = "$LlvmPrefix\bin;$env:PATH"
    $env:RUST_LOG = 'amice=info'
    $env:AMICE_PANIC_POLICY = 'abort'
    $Source = @'
extern int puts(const char *);
__attribute__((noinline)) int calculate(int x) {
    int sum = 0;
    for (int i = 0; i < x; ++i) sum += (i * 3) ^ 7;
    return sum;
}
int main(void) {
    if (calculate(10) != 143) return 2;
    return puts("AMICE_WINDOWS_STRING_TEST") < 0;
}
'@
    foreach ($Language in @('c', 'cpp')) {
        $InputFile = Join-Path $OutputDir "smoke.$Language"
        $Text = $Source
        if ($Language -eq 'cpp') { $Text = $Text.Replace('extern int puts', 'extern "C" int puts') }
        Set-Content -LiteralPath $InputFile -Value $Text -Encoding ascii
        $Plain = Join-Path $OutputDir "plain-$Language.exe"
        & $Clang -O0 $InputFile -o $Plain
        if ($LASTEXITCODE -ne 0) { throw "$Language baseline compile failed" }
        $Baseline = @(& $Plain)
        if ($LASTEXITCODE -ne 0 -or ($Baseline -join [Environment]::NewLine) -ne 'AMICE_WINDOWS_STRING_TEST') { throw "$Language baseline execution failed" }
        foreach ($Case in @('string', 'simd_string', 'flatten', 'vmp')) {
            # Strong transforms apply to a supported integer function; main
            # exercises string encryption and the native Windows CRT.
            $CaseText = $Text
            if ($Case -in @('flatten', 'vmp')) { $CaseText = $Text.Replace('noinline))', ('noinline, annotate("+' + $Case + '")))')) }
            Set-Content -LiteralPath $InputFile -Value $CaseText -Encoding ascii
            $Ir = Join-Path $OutputDir "input-$Case-$Language.ll"
            & $Clang -O0 -S -emit-llvm $InputFile -o $Ir
            if ($LASTEXITCODE -ne 0) { throw "$Language/$Case IR generation failed" }
            $env:AMICE_STRING_ENCRYPTION = 'true'
            $env:AMICE_STRING_ALGORITHM = if ($Case -eq 'simd_string') { 'simd_xor' } else { 'xor' }
            $env:AMICE_VM_EMIT_MARKERS = 'true'
            $Transformed = Join-Path $OutputDir "$Case-$Language.ll"
            $Executable = Join-Path $OutputDir "$Case-$Language.exe"
            & $Opt "--load-pass-plugin=$Plugin" '-passes=default<O0>' -verify-each -S $Ir -o $Transformed
            if ($LASTEXITCODE -ne 0) { throw "$Language/$Case plugin execution failed" }
            $TransformedText = Get-Content -LiteralPath $Transformed -Raw
            if ($Case -eq 'flatten' -and -not $TransformedText.Contains('dispatcher')) { throw "$Language flatten did not emit a dispatcher" }
            if ($Case -eq 'vmp' -and -not $TransformedText.Contains('AMICE_VMP_RUNTIME_BYTECODE')) { throw "$Language VMP did not emit a runtime marker" }
            & $Clang $Transformed -o $Executable
            if ($LASTEXITCODE -ne 0) { throw "$Language/$Case transformed compile failed" }
            $Actual = @(& $Executable)
            if ($LASTEXITCODE -ne 0 -or ($Actual -join [Environment]::NewLine) -ne ($Baseline -join [Environment]::NewLine)) { throw "$Language/$Case output mismatch" }
            $PlainBytes = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($Plain))
            $HiddenBytes = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($Executable))
            if (-not $PlainBytes.Contains('AMICE_WINDOWS_STRING_TEST') -or $HiddenBytes.Contains('AMICE_WINDOWS_STRING_TEST')) {
                throw "$Language/$Case plaintext marker check failed"
            }
            Write-Host "PASS: $Language/$Case output matches baseline; plaintext marker hidden"
        }
    }
} finally {
    Pop-Location
    Get-ChildItem Env: | Where-Object { $_.Name -like 'AMICE_*' } | ForEach-Object { Remove-Item "Env:$($_.Name)" }
    [Environment]::SetEnvironmentVariable('RUST_LOG', $null, 'Process')
    foreach ($Name in $SavedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($Name, $SavedEnvironment[$Name], 'Process') }
}
