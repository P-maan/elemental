; Elemental per-user installer. Build with windows\build-installer.ps1 (publishes first).
#define MyAppName "Elemental"
#define MyAppVersion "0.1"
#define MyAppExe "Elemental.exe"

[Setup]
AppId={{6F1C2B8E-4D1A-4E55-9B7B-3C0F5A1E0A01}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher=Elemental
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=ElementalSetup-{#MyAppVersion}
SetupIconFile=..\Elemental.ico
UninstallDisplayIcon={app}\{#MyAppExe}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=no

[Tasks]
Name: "startwithwin"; Description: "Start Elemental when I sign in to Windows"; GroupDescription: "Options:"; Flags: unchecked

[Files]
Source: "..\publish\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExe}"

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Elemental"; ValueData: """{app}\{#MyAppExe}"""; Flags: uninsdeletevalue; Tasks: startwithwin

[Run]
Filename: "{app}\{#MyAppExe}"; Description: "Launch Elemental"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{app}\{#MyAppExe}"; Parameters: "--quit"; Flags: runhidden waituntilterminated; RunOnceId: "QuitElemental"

[UninstallDelete]
Type: filesandordirs; Name: "{localappdata}\Elemental\WebView2"

[Code]
const
  WV2Guid = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';

function WebView2Present: Boolean;
var v: String;
begin
  Result :=
    (RegQueryStringValue(HKLM, 'SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\' + WV2Guid, 'pv', v) and (v <> '') and (v <> '0.0.0.0')) or
    (RegQueryStringValue(HKLM, 'SOFTWARE\Microsoft\EdgeUpdate\Clients\' + WV2Guid, 'pv', v) and (v <> '') and (v <> '0.0.0.0')) or
    (RegQueryStringValue(HKCU, 'Software\Microsoft\EdgeUpdate\Clients\' + WV2Guid, 'pv', v) and (v <> '') and (v <> '0.0.0.0'));
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var rc: Integer; exe: String;
begin
  Result := '';
  exe := ExpandConstant('{app}\{#MyAppExe}');
  if FileExists(exe) then
    Exec(exe, '--quit', '', SW_HIDE, ewWaitUntilTerminated, rc);
  if not WebView2Present then
  begin
    try
      DownloadTemporaryFile('https://go.microsoft.com/fwlink/p/?LinkId=2124703', 'MicrosoftEdgeWebview2Setup.exe', '', nil);
      Exec(ExpandConstant('{tmp}\MicrosoftEdgeWebview2Setup.exe'), '/silent /install', '', SW_HIDE, ewWaitUntilTerminated, rc);
    except
      Log('WebView2 bootstrapper failed: ' + GetExceptionMessage);
    end;
    if not WebView2Present then
      MsgBox('The Microsoft WebView2 runtime could not be installed. Elemental needs it; install it from https://developer.microsoft.com/microsoft-edge/webview2/ and run Elemental again.', mbInformation, MB_OK);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'Elemental');
end;
