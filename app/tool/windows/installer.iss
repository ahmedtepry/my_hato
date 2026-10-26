; Installer for the My Hato team app (Windows). Built in CI; the Release folder comes from `flutter build windows --release`.
[Setup]
AppName=My Hato Team
AppVersion=1.0
AppPublisher=My Hato
DefaultDirName={autopf}\MyHatoTeam
DefaultGroupName=My Hato Team
OutputBaseFilename=MyHatoTeam-Setup
OutputDir=out
Compression=lzma2
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\myhato.exe

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\My Hato Team"; Filename: "{app}\myhato.exe"
Name: "{autodesktop}\My Hato Team"; Filename: "{app}\myhato.exe"

[Run]
Filename: "{app}\myhato.exe"; Description: "Open My Hato Team"; Flags: nowait postinstall skipifsilent
