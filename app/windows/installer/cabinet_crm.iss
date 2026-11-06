; Inno Setup script for the Cabinet CRM Windows installer.
;
; Built by CI (.github/workflows/build.yml). To build by hand on Windows:
;   flutter build windows --release
;   copy msvcp140.dll, vcruntime140.dll, vcruntime140_1.dll from C:\Windows\System32
;     into build\windows\x64\runner\Release
;   "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" /DAppVersion=1.0.0 windows\installer\cabinet_crm.iss
;
; What it does:
;   - installs to C:\Program Files\Cabinet CRM, with Start menu (and optional desktop) shortcuts
;   - allows the Wi-Fi sync service through Windows Firewall on PRIVATE networks only,
;     so phones can connect without the firewall pop-up
;   - upgrades in place (same AppId); closes the running app first
;   - uninstall removes the program but NEVER your data in Documents\Cabinet CRM

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define AppName "Cabinet CRM"
#define AppExe "cabinet_crm.exe"
#define BuildDir "..\..\build\windows\x64\runner\Release"

[Setup]
AppId={{D2E5F821-B75A-4A11-A78E-F5EF4EE0390D}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppName}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
SetupIconFile=..\runner\resources\app_icon.ico
OutputDir=..\..\build\installer
OutputBaseFilename=CabinetCRM-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
; Admin rights are needed to add the firewall rule and install to Program Files.
PrivilegesRequired=admin
CloseApplications=yes
RestartApplications=no
VersionInfoVersion={#AppVersion}
VersionInfoProductName={#AppName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "startup"; Description: "Start Cabinet CRM when Windows starts (recommended on the main office PC, so workstations and phones can always sync)"; GroupDescription: "Main office PC:"; Flags: unchecked

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon
Name: "{commonstartup}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: startup

[Run]
; Replace any old rule, then allow inbound sync connections on private (home/work) networks only.
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#AppName}"""; Flags: runhidden; StatusMsg: "Configuring Windows Firewall..."
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""{#AppName}"" dir=in action=allow program=""{app}\{#AppExe}"" enable=yes profile=private"; Flags: runhidden; StatusMsg: "Configuring Windows Firewall..."
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#AppName}"""; Flags: runhidden; RunOnceId: "RemoveFirewallRule"

[Messages]
FinishedLabel=Setup has installed [name] on your computer.%n%nYour data is kept in Documents\Cabinet CRM. Back up that folder regularly. Uninstalling never deletes it.
