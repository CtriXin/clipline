# Builds Clipline.exe into .\build with the C# compiler that ships with
# Windows (.NET Framework 4.8). No SDK, Visual Studio or download needed.
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$fw  = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319"
$csc = Join-Path $fw "csc.exe"
$wpf = Join-Path $fw "WPF"
if (-not (Test-Path $csc)) { throw ".NET Framework 4.x not found at $fw" }

New-Item -ItemType Directory -Force build | Out-Null
$refs = @(
  "/r:$wpf\PresentationCore.dll", "/r:$wpf\PresentationFramework.dll", "/r:$wpf\WindowsBase.dll",
  "/r:$fw\System.Xaml.dll", "/r:System.Windows.Forms.dll", "/r:System.Drawing.dll",
  "/r:Microsoft.VisualBasic.dll", "/r:System.dll", "/r:System.Core.dll",
  "/r:System.Security.dll", "/r:System.Web.Extensions.dll"
)

# 1. The icon, drawn by the same code the tray uses.
& $csc /nologo /target:exe /out:build\MakeIcon.exe /r:System.Drawing.dll tools\MakeIcon.cs src\AppIcon.cs
if ($LASTEXITCODE) { throw "MakeIcon failed" }
& build\MakeIcon.exe build\Clipline.ico build\icon.png
Remove-Item build\MakeIcon.exe

# 2. The app.
& $csc /nologo /target:winexe /optimize+ /out:build\Clipline.exe /win32icon:build\Clipline.ico /win32manifest:src\app.manifest $refs (Get-ChildItem src\*.cs).FullName
if ($LASTEXITCODE) { throw "Build failed" }
Write-Host "Built $(Resolve-Path build\Clipline.exe)"
