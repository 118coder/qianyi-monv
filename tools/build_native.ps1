# build_native.ps1 -- build the GDExtension plugin and enable it.
#
# Requirements (Windows):
#   * CMake 3.18+
#   * MSVC (Visual Studio 2022, C++ workload) -- godot-cpp does not support MinGW officially
#   * godot-cpp submodule (branch must match the engine minor version)
#   * optional: Microsoft.Web.WebView2 native SDK (NuGet) for the UI host
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tools\build_native.ps1 -Config debug
#   powershell -ExecutionPolicy Bypass -File tools\build_native.ps1 -Config release `
#       -WebView2Root "C:\nuget\Microsoft.Web.WebView2.1.0.2592.51\build\native"

param(
    [ValidateSet('debug', 'release')]
    [string]$Config = 'debug',
    [string]$WebView2Root = ''
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$nativeDir = Join-Path $repo 'native'
$buildDir = Join-Path $nativeDir 'build'
$target = if ($Config -eq 'debug') { 'template_debug' } else { 'template_release' }
$cfgName = if ($Config -eq 'debug') { 'Debug' } else { 'Release' }

function Require-Command($name, $hint) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "missing '$name'. $hint"
    }
}

Require-Command 'cmake' 'Install CMake 3.18+ and add it to PATH.'
Require-Command 'git'   'Install Git for Windows.'

if (-not (Test-Path (Join-Path $nativeDir 'godot-cpp\CMakeLists.txt'))) {
    throw "godot-cpp is missing. Run: git submodule update --init --recursive"
}

$cmakeArgs = @(
    '-S', $nativeDir,
    '-B', $buildDir,
    '-G', 'Visual Studio 17 2022',
    '-A', 'x64',
    "-DGODOTCPP_TARGET=$target"
)
if ($WebView2Root -ne '') {
    $cmakeArgs += "-DWEBVIEW2_ROOT=$WebView2Root"
}

Write-Host "== configure ==" -ForegroundColor Cyan
& cmake @cmakeArgs
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed" }

Write-Host "== build ($cfgName) ==" -ForegroundColor Cyan
& cmake --build $buildDir --config $cfgName
if ($LASTEXITCODE -ne 0) { throw "cmake build failed" }

# The .gdextension descriptor is generated only after a successful build,
# so a fresh clone never spams "can't open dynamic library" on every launch.
$tpl = Join-Path $nativeDir 'qy_native.gdextension.template'
$dst = Join-Path $nativeDir 'qy_native.gdextension'
if (Test-Path $tpl) {
    Copy-Item $tpl $dst -Force
    Write-Host "enabled plugin: native/qy_native.gdextension" -ForegroundColor Green
}

$dll = Join-Path $nativeDir "bin\qy_native.windows.$target.x86_64.dll"
if (Test-Path $dll) {
    $size = [math]::Round((Get-Item $dll).Length / 1KB)
    Write-Host "built: $dll ($size KB)" -ForegroundColor Green
} else {
    Write-Warning "DLL not found at $dll -- check the OUTPUT_NAME in CMakeLists.txt"
}
