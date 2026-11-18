# Run inside the Windows VM from C:\ewin (expects C:\ewin\windows and C:\ewin\web).
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path   # ...\windows
$dotnet = "C:\Program Files\dotnet\dotnet.exe"
$iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe","C:\Program Files (x86)\Inno Setup 6\ISCC.exe","C:\Program Files\Inno Setup 6\ISCC.exe") | ? { Test-Path $_ } | select -First 1
if (-not $iscc) { throw "Inno Setup 6 not found" }
if (-not (Test-Path (Join-Path $root '..\web\index.html'))) { Write-Warning "web\index.html missing - installer will ship without the scene" }
Remove-Item -Recurse -Force "$root\publish" -ErrorAction SilentlyContinue
& $dotnet publish "$root\Elemental.csproj" -c Release -r win-x64 --self-contained true -o "$root\publish" /p:DebugType=None
if ($LASTEXITCODE) { throw "publish failed" }
& $iscc "$root\installer\Elemental.iss"
if ($LASTEXITCODE) { throw "ISCC failed" }
Get-Item "$root\dist\ElementalSetup-*.exe" | select FullName, Length
