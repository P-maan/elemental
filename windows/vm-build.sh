#!/bin/bash
# Mac-side: sync windows/ + web/ to the VM exchange folder, build the installer in the VM, copy it back.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
STAGE="$HOME/Downloads/ewin-stage"; VM="Windows 11"
mkdir -p "$STAGE/windows" "$STAGE/web"
rsync -a --delete --exclude bin --exclude obj --exclude dist --exclude publish "$HERE/" "$STAGE/windows/"
[ -d "$REPO/web" ] && rsync -a --delete "$REPO/web/" "$STAGE/web/"
prlctl exec "$VM" --current-user powershell.exe -NoProfile -Command "robocopy '\\\\Mac\\Home\\Downloads\\ewin-stage\\windows' 'C:\\ewin\\windows' /MIR /XD bin obj dist publish /NFL /NDL /NJH /NJS | Out-Null; robocopy '\\\\Mac\\Home\\Downloads\\ewin-stage\\web' 'C:\\ewin\\web' /MIR /NFL /NDL /NJH /NJS | Out-Null; & 'C:\\ewin\\windows\\build-installer.ps1'"
mkdir -p "$HERE/dist"
prlctl exec "$VM" --current-user powershell.exe -NoProfile -Command "Copy-Item 'C:\\ewin\\windows\\dist\\ElementalSetup-0.1.exe' '\\\\Mac\\Home\\Downloads\\ewin-stage\\ElementalSetup-0.1.exe' -Force"
cp "$STAGE/ElementalSetup-0.1.exe" "$HERE/dist/"
ls -l "$HERE/dist/ElementalSetup-0.1.exe"
