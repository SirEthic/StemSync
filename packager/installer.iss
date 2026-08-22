[Setup]
AppName=StemSync Packager
AppVersion=1.0.0
DefaultDirName={autopf}\StemSync Packager
DefaultGroupName=StemSync Packager
UninstallDisplayIcon={app}\StemSync Packager.exe
Compression=lzma2
SolidCompression=yes
OutputDir=dist
OutputBaseFilename=StemSync_Packager_Setup
SetupIconFile=icon.ico

[Files]
Source: "dist\StemSync Packager\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "icon.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\StemSync Packager"; Filename: "{app}\StemSync Packager.exe"; IconFilename: "{app}\icon.ico"
Name: "{autodesktop}\StemSync Packager"; Filename: "{app}\StemSync Packager.exe"; IconFilename: "{app}\icon.ico"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional icons:"
