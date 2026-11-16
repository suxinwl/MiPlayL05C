#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

#ifndef AppBuild
  #define AppBuild "0"
#endif

#ifndef ReleaseDir
  #error ReleaseDir must point to the Flutter Windows Release directory
#endif

#ifndef OutputDir
  #define OutputDir "."
#endif

#ifndef SetupIcon
  #define SetupIcon "..\runner\resources\app_icon.ico"
#endif

[Setup]
AppId={{3c5ec7dc-26f9-4229-9b44-fdc7a7b52421}
AppName=oo music
AppVersion={#AppVersion}
AppVerName=oo music {#AppVersion} ({#AppBuild})
AppPublisher=oo music
AppPublisherURL=https://github.com/Rankgice/oo-music
AppSupportURL=https://github.com/Rankgice/oo-music
AppUpdatesURL=https://github.com/Rankgice/oo-music
DefaultDirName={localappdata}\Programs\oo music
DefaultGroupName=oo music
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=oo-music-{#AppVersion}-windows-x64-setup
SetupIconFile={#SetupIcon}
UninstallDisplayIcon={app}\oo_music.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
SetupLogging=yes
VersionInfoVersion={#AppVersion}.{#AppBuild}
VersionInfoCompany=oo music
VersionInfoDescription=oo music Windows installer
VersionInfoProductName=oo music
VersionInfoProductVersion={#AppVersion}

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional tasks:"; Flags: unchecked

[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "*.pdb,*.lib,*.exp,*.ilk,*.log,zlib.dll"

[Icons]
Name: "{group}\oo music"; Filename: "{app}\oo_music.exe"; WorkingDir: "{app}"
Name: "{group}\Uninstall oo music"; Filename: "{uninstallexe}"
Name: "{autodesktop}\oo music"; Filename: "{app}\oo_music.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\oo_music.exe"; Description: "Launch oo music"; Flags: nowait postinstall skipifsilent
