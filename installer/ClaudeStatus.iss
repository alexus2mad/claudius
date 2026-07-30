; Inno Setup script for Claudius I.
;
; This wraps the existing setup.ps1 / uninstall.ps1 flow in a normal Windows
; installer: a double-clickable .exe with Start Menu / Add-Remove-Programs
; entries, instead of "right-click setup.ps1 -> Run with PowerShell". The
; actual install logic (driver check, avrdude flash, browser wizard, hook
; registration) is untouched -- this just packages the payload and launches
; setup.ps1 for it, since that wizard already works well as-is.
;
; Build with: iscc ClaudeStatus.iss  (produces installer\Output\ClaudeStatusSetup.exe)

#define MyAppName "Claudius I"
#define MyAppVersion "1.0"
#define MyAppPublisher "Alex Maksiutenko"
#define MyAppURL "https://github.com/alexus2mad/claudius"
#define PayloadDir "..\ClaudeStatus"

[Setup]
AppId={{317A691A-0863-4075-8355-83084DB64843}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
; Per-user install under %LOCALAPPDATA% -- matches how setup.ps1 already
; writes everything (runtime app dir, scheduled task, hooks) without
; needing admin rights. The bundled setup.ps1 self-elevates on its own,
; just-in-time, only for the one step that needs it (CH340 driver install).
DefaultDirName={localappdata}\Programs\ClaudeStatus
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=Output
OutputBaseFilename=ClaudeStatusSetup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName={#MyAppName}
ArchitecturesAllowed=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#PayloadDir}\setup.ps1";     DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\uninstall.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\README.md";     DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\app\*";    DestDir: "{app}\app";    Flags: ignoreversion recursesubdirs
Source: "{#PayloadDir}\driver\*"; DestDir: "{app}\driver"; Flags: ignoreversion recursesubdirs
Source: "{#PayloadDir}\hex\*";    DestDir: "{app}\hex";    Flags: ignoreversion recursesubdirs
Source: "{#PayloadDir}\tools\*";  DestDir: "{app}\tools";  Flags: ignoreversion recursesubdirs

[Icons]
Name: "{group}\{#MyAppName} Setup"; Filename: "powershell.exe"; \
    Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\setup.ps1"""; \
    WorkingDir: "{app}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"

[Run]
Filename: "powershell.exe"; \
    Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\setup.ps1"""; \
    WorkingDir: "{app}"; Description: "Launch the {#MyAppName} setup wizard"; \
    Flags: postinstall nowait skipifsilent

[UninstallRun]
; Runs before Inno removes the {app} payload files -- stops the daemon,
; unregisters the Task Scheduler entry, restores settings.json, and deletes
; the separate %LOCALAPPDATA%\ClaudeStatus runtime dir that setup.ps1 owns
; (a different path from {app}, so there's no file-lock conflict with the
; delete-{app} step that follows).
Filename: "powershell.exe"; \
    Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\uninstall.ps1"""; \
    WorkingDir: "{app}"; RunOnceId: "UninstallClaudeStatus"; Flags: waituntilterminated
