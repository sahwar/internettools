{Copyright (C) 2006-9  Benito van der Zander

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
}

{** This unit contains a class which can check online for an update, download and install it

  @author(Benito van der Zander - benito@benibela.de)
}

unit autoupdate;

{$mode objfpc}{$H+}

interface
{$DEFINE showProgress}
uses
  Classes, SysUtils, internetaccess,bbutils,simplehtmlparser, simplexmlparser,  dialogs{$IFDEF showProgress},progressdialog{$ENDIF}
  ;

//**this is shown in the message notifying about a *failed* update as a alternative way to get the update
const homepageAlternative:string='www.benibela.de';

type

{ TAutoUpdater }

TVersionNumber=longint;

{**
@abstract(auto update class)

How to use it:
@unOrderedList(
  @item(create a new object with this options:
     @definitionList(
       @itemLabel(version)
       @item(Integer based incrementing version number

         for example 1, next version, 2.
         You cann't use 1.6, or 1.56, and 156>16)
       @itemLabel(installDir)
       @item(Directory to the program files which you want to update)
       @itemLabel(versionURL)
       @item(URL containing a file containing the most recent version number (see below for format))
       @itemLabel(changelogURL)
       @item(URL containing an xml file with details to the newest version. (see below))
     ))
  @item(call existsUpdate to compare the current version number with the one in the web

     YOU NEED ACCESS TO VERSIONURL (= INTERNET))
  @item(call hasDirectoryWriteAccess to check, if you are allowed to change the
     files in the program directory.

     If not, you can't call the install functions of step 4)
  @item(call downloadUpdate(tempDir) to download the file to tempDir.

      tempDir can be omitted.)
  @item(call installUpdate to execute the downloaded installer)
  @item(check needRestart to test if the program should be restarted.))

  Version format:

    @preformatted(#
    <?xml version="1.0" encoding="iso-8859-1"?>
    <versions>
      <stable value="an integer like describe above"/>
    </versions>
    #)



  Changelog format:

  @preformatted(#
  <?xml version="1.0" encoding="UTF-8"?>
  <?xml-stylesheet type="text/xsl" href="changelog.xsl"?>
  <changelog program="*Your program name here*">
  <build version="*version number*" date="e.g. 2008-11-07">
    <download url="*url to installer*" platform="..." execute="..." restart=".."/>
    <download url="*url to installer*" platform="..." execute="..." restart=".."/>
    ...
    <fix level="minor">minor fix</fix>
    <fix level="major">major fix</fix>
    <fix level="critical">critical fix</fix>
    ..
    <add level="minor">minor fix</add>
    ..
    <change level="minor">minor fix</change>
    ..
  </build>
   ...
  </changelog>
  #)

  The file need a <build> with the same version as the version given in the version file
  and this build need at least one <download> with a given url and the same platform
  this unit was compiled one.

  platform can be LINUX, WINDOWS, LINUX32, LINUX64, WIN32, WIN64, BSD, BSD32 or BSD6 4
  (if there are several downloads with a matching platform it is undefined which on will be
   downloaded)

  execute is the command line which should be executed after downloading the update (default '"$DOWNLOAD"').
  $INSTALLPATH and $OLDVERSION will be replaced by the values passed to the constructor, $OLDPATH and $OLDFILE will be replaced by
  the value of paramstr(0), $DOWNLOAD will be replaced by the file just downloaded@br
  Set execute to   '' if the downloaded file is not executable@br
  restart determines if the application   should restart after executing the installer (default true)

  You can have multiple build, download, fix, add, change tags in a file
  fix/add/change and the level-properties are only used to show details, but the
  xsl will highlight it correspondly

  Notice that these files will not be parsed with an xml parser, but with an html
  parser. (=>no validation and cdata tags are unknown)

  You have to set internetaccess.defaultInternetAccessClass to either TW32InternetAccess
  or TSynapseInternetAccess
}
TAutoUpdater=class
private
  finternet:TInternetAccess;
  //fUpdateStyle:(usInstaller);
  fcurrentVersion:TVersionNumber;
  fnewversionstr:string;
  finstallDir,fversionsURL,fchangelogURL: string;
  ftempDir:string;


  fnewversion:TVersionNumber;
  function getInstallerCommand: string;
  function GetInstallerDownloadedFileName: string;
  function loadNewVersionEnterTag(tagName: string; properties: TProperties):TParsingResult;
  procedure loadNewVersion(const url: string);

private
  finstallerurl,fallChanges,fallFixes,fallAdds:string;
  finstallerBaseName: string; //installer url without path (downloaded file)
  finstallerParameters: string; //parameter to pass to the installer
  finstallerNeedRestart: boolean; //if the programm have to be restarted after the installer is called (default: true)
  fbuildinfolastbuild: longint;
  fbuildinfolasttag:string;
  fupdatebuildversion:longint;
  function needBuildInfoEnterTag(tagName: string; properties: TProperties):TParsingResult;
  function needBuildInfoTextRead(text: string):TParsingResult;
  procedure needBuildInfo();//newversion,build

  procedure needInternet;inline;
  {** can every old file be replaced
     Result:
       true: yes, call installUpdate
       false: no, call installUpdate and RESTART program (you must restart)
  }
  function _needRestart:boolean;
public
  constructor create(currentVersion:TVersionNumber;installDir,versionsURL,changelogURL: string);
  {** check if the user can write in the application directory and is therefore able to install the update. }
  function hasDirectoryWriteAccess:boolean;
  {** check if the installer can be run (on linux it depends on write access, on windows it can always run) }
  function canRunInstaller: boolean;
  {** checks if an update exists }
  function existsUpdate:boolean;
  {** returns a list of the performed changes}
  function listChanges:string;
  {** download update to tempDir }
  procedure downloadUpdate(tempDir:string='');
  {** call installer }
  procedure installUpdate;
  
  destructor destroy;override;
  
  property newestVersion: TVersionNumber read fnewversion;
  property needRestart: boolean read _needRestart;
  property installerCmd: string read getInstallerCommand;
  property downloadedFileName: string read GetInstallerDownloadedFileName;
end;
implementation

uses FileUtil,process{$IFDEF FPC_HAS_CPSTRING},LazFileUtils{$ENDIF}{$IFDEF UNIX},BaseUnix{$ENDIF}{$IFDEF WINDOWS},windows,ShellApi{$endif};
function isOurPlatform(p: string):boolean;
begin
  p:=UpperCase(p);
  result:=false;
  {$IFDEF WIN32}
  result:=(p='WINDOWS')or(p='WIN32');
  {$ENDIF}
  {$IFDEF WIN64}
  result:=(p='WINDOWS')or(p='WIN64');
  {$ENDIF}

  {$IFDEF LINUX}
  if p='LINUX' then exit(true);
  {$IFDEF CPU32}
  result:=p='LINUX32';
  {$ENDIF}
  {$IFDEF CPU64}
  result:=p='LINUX64';
  {$ENDIF}
  {$ENDIF}

  {$IFDEF BSD}
  if p='BSD' then exit(true);
  {$IFDEF CPU32}
  result:=p='BSD32';
  {$ENDIF}
  {$IFDEF CPU64}
  result:=p='BSD64';
  {$ENDIF}
  {$ENDIF}
end;

{ TAutoUpdater }

function TAutoUpdater.hasDirectoryWriteAccess: boolean;
//var f:THandle;
const testFileName='BeNiBeLa_ThIs_Is_A_StRaNgE_FiLeNaMe_YoU_BeTtEr_NeVeR_UsE.okay';
var
  actualFileName: String;
begin
  //write a file to test it
  //TODO: Possible that this won't work on newer Windows, but I can't test it there (should work if asInvoker is set in requestedExecutionLevel in the manifest)
  if finstallDir='' then exit(false);
  try
    actualFileName:=finstallDir+testFileName;
    DeleteFileUTF8(actualFileName);
    if FileExistsUTF8(actualFileName) then exit(false);
    strSaveToFile(actualFileName,'test');
    if not FileExistsUTF8(actualFileName) then exit(false);
    DeleteFileUTF8(actualFileName);
    if FileExistsUTF8(actualFileName) then exit(false);
    exit(true);
  except
    result:=false;
  end;
end;

function TAutoUpdater.canRunInstaller: boolean;
begin
  if finstallerParameters='' then exit(false);
  if hasDirectoryWriteAccess then exit(true);
  {$IFDEF WINDOWS}
  if Win32MajorVersion >= 6 then exit(true); //use shellexecute runas there. TODO: does it also work in older versions?
  {$ENDIF}
  exit(false);
end;


function TAutoUpdater.loadNewVersionEnterTag(tagName: string;
  properties: TProperties): TParsingResult;
begin
  if striequal(tagName,'stable') then begin
    fnewversionstr:=getProperty('value',properties);
    fnewversion:=StrToIntDef(fnewversionstr,0);
    exit(prStop);
  end;
  Result:=prContinue;
end;

function TAutoUpdater.GetInstallerDownloadedFileName: string;
begin
  result:=ftempDir+finstallerBaseName;
end;

function TAutoUpdater.getInstallerCommand: string;
begin
  Result:=finstallerParameters;
  Result:=StringReplace(Result,'$DOWNLOAD',downloadedFileName,[rfReplaceAll,rfIgnoreCase]);
  Result:=StringReplace(Result,'$INSTALLPATH',finstallDir,[rfReplaceAll,rfIgnoreCase]);
  Result:=StringReplace(Result,'$OLDPATH',ExtractFilePath(ParamStr(0)),[rfReplaceAll,rfIgnoreCase]);
  Result:=StringReplace(Result,'$OLDFILE',ParamStr(0),[rfReplaceAll,rfIgnoreCase]);
  Result:=StringReplace(Result,'$OLDVERSION',INttostr(fcurrentVersion),[rfReplaceAll,rfIgnoreCase]);
end;

procedure TAutoUpdater.loadNewVersion(const url: string);
var versionXML:string;
begin
  needInternet;
  versionXML:=finternet.get(url);
  fnewversion:=0;
  fnewversionstr:='';
  fupdatebuildversion:=0;
  parseXML(versionXML,@loadNewVersionEnterTag,nil,nil,eUTF8);
end;

function TAutoUpdater.needBuildInfoEnterTag(tagName: string;
  properties: TProperties): TParsingResult;
begin
  if striequal(tagname,'build') then begin
    fbuildinfolastbuild:=StrToIntDef(getProperty('version',properties),0);
    if (fbuildinfolastbuild<=fnewversion) and (fbuildinfolastbuild>fupdatebuildversion) then
        fupdatebuildversion:=fbuildinfolastbuild;
  end else if striequal(tagname,'download') then
    if (fbuildinfolastbuild=fnewversion) and (isOurPlatform(getProperty('platform',properties))) then begin
      finstallerurl:=getProperty('url',properties);
      finstallerBaseName:=copy(finstallerurl,strrpos('/',finstallerurl)+1,length(finstallerurl));
      finstallerParameters:=getProperty('execute',properties);
      finstallerNeedRestart:=StrToBoolDef(getProperty('restart',properties),false);
    end;
  fbuildinfolasttag:=tagName;
  result:=prContinue;
end;

function TAutoUpdater.needBuildInfoTextRead(text: string): TParsingResult;
begin
  if (fbuildinfolastbuild<=fnewversion) and (fbuildinfolastbuild>fcurrentVersion) then begin
    if striequal(fbuildinfolasttag,'fix') then fallFixes+=text+LineEnding
    else if striequal(fbuildinfolasttag,'add') then fallAdds+=text+LineEnding
    else if striequal(fbuildinfolasttag,'change') then fallChanges+=text+LineEnding;
  end;
  fbuildinfolasttag:='';
  result:=prContinue;
end;

procedure TAutoUpdater.needBuildInfo();
var changelogXML:string;
begin
  if fupdatebuildversion=fnewversion then exit;
  needInternet;
  changelogXML:=finternet.get(fchangelogURL);
  fallAdds:='';
  fallChanges:='';
  fallFixes:='';
  finstallerurl:='';
  finstallerBaseName:='update';
  finstallerParameters:='"$DOWNLOAD"';
  finstallerNeedRestart:=true;

  fupdatebuildversion:=0;
  parseXML(changelogXML,@needBuildInfoEnterTag,nil,@needBuildInfoTextRead,eUTF8);
  if fupdatebuildversion<>fnewversion then
    raise Exception.Create('Die Informationen im ChangeLog sind anscheinend ungültig. Version '+fnewversionstr+' nicht gefunden, nur '+IntToStr(fupdatebuildversion)+'.');
end;



procedure TAutoUpdater.needInternet; inline;
begin
  if finternet=nil then
    finternet:=defaultInternetAccessClass.create;
end;

constructor TAutoUpdater.create(currentVersion: TVersionNumber; installDir,
  versionsURL,changelogURL: string);
begin
  fcurrentVersion:=currentVersion;
  finstallDir:=installDir;
  if finstallDir='' then
    finstallDir:=ExtractFilePath(paramstr(0));
  if finstallDir[length(finstallDir)]<>DirectorySeparator then
    finstallDir:=ExtractFilePath(ParamStr(0));
  if finstallDir[length(finstallDir)]<>DirectorySeparator then
    finstallDir:=finstallDir+DirectorySeparator;
  fversionsURL:=versionsURL;
  fchangelogURL:=changelogURL;
end;

function TAutoUpdater.existsUpdate: boolean;
begin
  result:=false;
  try
    loadNewVersion(fversionsURL);
    result:=fnewversion>fcurrentVersion;
  except
    on EInternetException do result:=false;
  end;
end;

function TAutoUpdater.listChanges: string;
begin
  needBuildInfo();
  Result:='';
  if fallChanges<>'' then result+=#13#10'==Änderungen=='#13#10+fallChanges;
  if fallAdds<>'' then result+=#13#10'==Hinzufügungen=='#13#10+fallAdds;
  if fallFixes<>'' then result+=#13#10'==Gelöste Fehler=='#13#10+fallFixes;
end;

procedure TAutoUpdater.downloadUpdate(tempDir: string);
var updateUrl:string;
    update:TFileStream;
    {$IFDEF showProgress}progress:TProgressBarDialog;{$ENDIF}
begin
  needBuildInfo();
  if finstallerurl='' then
    raise exception.Create('Die Internetadresse des Updates konnte leider nicht ermittelt werden.'#13#10+
                           'Bitte laden Sie es manuell von '+homepageAlternative+' herunter, oder versuchen es später nochmal.');

  updateUrl:=finstallerurl;

  ftempDir:=tempDir;
  if ftempDir='' then
    ftempDir:=GetTempDir();
  if ftempDir[length(ftempDir)]<>DirectorySeparator then
    ftempDir:=ftempDir+DirectorySeparator;
  try
    //RemoveDir(copy(ftempDir,1,length(ftempdir)-1));
    ForceDirectory(copy(ftempDir,1,length(ftempdir)-1));
  except
    if not DirectoryExists(copy(ftempDir,1,length(ftempdir)-1)) then
      raise exception.create('Temporäres Verzeichnis '+ftempDir+' konnte nicht erstellt werden');
  end;

  {$IFDEF showProgress}
    progress:=TProgressBarDialog.create('Update','Bitte warten Sie während das Update auf Version '+fnewversionstr+' geladen wird:');
  {$ENDIF}
  try
    update:=TFileStream.Create(ftempDir+finstallerBaseName,fmCreate);
    try
      {$IFDEF showProgress}
      finternet.OnProgress:=@progress.progressEvent;
      {$ENDIF}
      finternet.get(updateUrl,update);
      finternet.OnProgress:=nil;
      if update.Size=0 then Abort;
      update.free;
    except on e: Exception do
      raise EXCEPTION.Create('Das Update konnte nicht heruntergeladen werden:'#13#10+e.ClassName+':'+ e.Message);
    end;
    {$IFDEF UNIX}
    if finstallerParameters<>'' then begin
      //set file permissions             f
      FpChmod(Utf8ToAnsi(ftempDir+finstallerBaseName), S_IRWXU or S_IRGRP or S_IXGRP or S_IROTH or S_IXOTH);
    end;
    {$ENDIF}
  finally
  {$IFDEF showProgress}
    progress.free;
  {$ENDIF}
  end;
end;

function TAutoUpdater._needRestart: boolean;
begin
  result:=(finstallerParameters<>'') and finstallerNeedRestart;
end;



procedure TAutoUpdater.installUpdate;
  {$IFDEF WINDOWS}
    procedure runAsAdmin(cmdline: string);
    var
      prog: String;
    begin
      cmdline:=trim(cmdline);
      if length(cmdline) = 0 then exit;
      if cmdline[1] = '"' then begin
        delete(cmdline, 1, 1);
        prog := strSplitGet('"', cmdline)
      end else if cmdline[1] = '''' then begin
        delete(cmdline, 1, 1);
        prog := strSplitGet('''', cmdline)
      end else if cmdline[1] <> '"' then prog := strSplitGet(' ', cmdline);
      ShellExecute(0, 'runas', pchar(prog), pchar(cmdline), pchar(finstallDir), SW_SHOWNORMAL);
    end;
  {$ENDIF}
var realParameter: string;
    p:tprocess;
begin
  if finstallerParameters='' then begin
    ShowMessage('Sorry, I can''t install the update automatically.'#13#10'Please start the file '+downloadedFileName+' yourself.');
    raise Exception.Create('Can''t start installer');
  end;
  if hasDirectoryWriteAccess then begin
    p:=TProcess.Create(nil);
    try
      p.CommandLine:=getInstallerCommand;
      p.Execute;
    finally
      p.free;
    end;
    exit;
  end;

  {$IFDEF WINDOWS}
  if Win32MajorVersion >= 6 then begin
    runAsAdmin(getInstallerCommand);
    exit;
  end;
  {$ENDIF}

  raise Exception.Create('Could not start installer');
end;

destructor TAutoUpdater.destroy;
begin
  if finternet<>nil then
    finternet.free;
  inherited destroy;
end;

end.

