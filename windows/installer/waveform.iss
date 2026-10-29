; inno setup script for the per-user windows installer.
;
;   iscc /DAppVersion=0.4.0 /DSourceDir=..\..\build\windows\x64\runner\Release ^
;        /DOutputName=waveform-windows-v0.4.0-setup waveform.iss
;
; no admin rights: installs under %LOCALAPPDATA%\Programs\Waveform, adds a
; start menu shortcut and an uninstaller. winsparkle runs this same setup
; silently for updates (see sparkle:installerArguments in the appcast).

#ifndef AppVersion
  #error AppVersion is required (/DAppVersion=x.y.z)
#endif
#ifndef SourceDir
  #error SourceDir is required (/DSourceDir=<flutter windows release dir>)
#endif
#ifndef OutputName
  #define OutputName "waveform-windows-setup"
#endif

[Setup]
; stable id: lets a new setup replace the previous install in place
AppId={{6F1B8E52-3C0D-4B1A-9E57-2A7D4C9B0F31}
AppName=Waveform
AppVersion={#AppVersion}
AppPublisher=Waveform
AppPublisherURL=https://github.com/mollykitten/waveform
DefaultDirName={autopf}\Waveform
DefaultGroupName=Waveform
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=.
OutputBaseFilename={#OutputName}
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\waveform_app.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; close a running Waveform during an update and start it again afterwards
CloseApplications=yes
RestartApplications=yes

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{autoprograms}\Waveform"; Filename: "{app}\waveform_app.exe"

[Run]
Filename: "{app}\waveform_app.exe"; Description: "Launch Waveform"; Flags: nowait postinstall skipifsilent
