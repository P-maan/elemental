#!/bin/bash
# Mac-side: sync windows/ + web/ to the VM exchange folder, build the installer in the VM, copy it back.
# Needs the Parallels VM "Windows 11" running with .NET 8 SDK + Inno Setup 6 installed (see build-installer.ps1).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
STAGE="$HOME/Downloads/ewin-stage"; VM="Windows 11"
vm() { # run a PowerShell command in the VM, retrying the occasional prlctl transport error
  local out i
  for i in 1 2 3 4; do
    out=$(prlctl exec "$VM" --current-user powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$1" 2>&1)
    if echo "$out" | grep -q 'PrlJob_Get'; then sleep 3; continue; fi
    echo "$out"; return 0
  done
  echo "$out"; return 1
}
mkdir -p "$STAGE/windows" "$STAGE/web"
rsync -a --delete --exclude bin --exclude obj --exclude dist --exclude publish "$HERE/" "$STAGE/windows/"
if [ -f "$REPO/web/index.html" ]; then rsync -a --delete "$REPO/web/" "$STAGE/web/"
else echo "WARNING: $REPO/web/index.html missing - using the test stub scene"; rsync -a --delete "$HERE/test-stub/web/" "$STAGE/web/"; fi
vm 'robocopy "\\Mac\Home\Downloads\ewin-stage\windows" "C:\ewin\windows" /MIR /XD bin obj dist publish /NFL /NDL /NJH /NJS | Out-Null; robocopy "\\Mac\Home\Downloads\ewin-stage\web" "C:\ewin\web" /MIR /NFL /NDL /NJH /NJS | Out-Null; Write-Host synced'
vm '& powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ewin\windows\build-installer.ps1' || exit 1
vm 'Copy-Item C:\ewin\windows\dist\ElementalSetup-0.1.exe \\Mac\Home\Downloads\ewin-stage\ElementalSetup-0.1.exe -Force; Write-Host copied'
mkdir -p "$HERE/dist"
cp "$STAGE/ElementalSetup-0.1.exe" "$HERE/dist/"
ls -l "$HERE/dist/ElementalSetup-0.1.exe"
