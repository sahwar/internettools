unit xquery_module_file;

{**
 This unit implements the file module of http://expath.org/spec/file .

 {not implemented:
 file:last-modified($path as xs:string) as xs:dateTime
 5 Paths
 6 System Properties
 }

 not much tested
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, xquery, simplehtmltreeparser, FileUtil, LazUTF8, LazFileUtils, bbutils, strutils, bigdecimalmath, base64, math, Masks;

type rawbytestring = string;

procedure registerModuleFile;

const XMLNamespaceURL_Expath_File = 'http://expath.org/ns/file';
var XMLNamespace_Expath_File: INamespace;
implementation

const Error_NoDir = 'no-dir';
      Error_Exists = 'exists';
      Error_Io_Error = 'io-error';
      Error_Not_Found =  'not-found';
      Error_Out_Of_Range = 'out-of-range';
      error_unknown_encoding = 'unknown-encoding';

var module: TXQNativeModule = nil;

procedure raiseFileError(code, message: string; const item: IXQValue = nil);
begin
  if item <> nil then message += '("'+item.toJoinedString()+'")';
  raise EXQEvaluationException.create(code, message, XMLNamespace_Expath_File, item);
end;

function xqToInt64(const v: IXQValue; out res: int64): boolean;
var
  temp: BigDecimal;
begin
  result := true;
  case v.kind of
    pvkInt64: res := v.toInt64;
    pvkFloat: begin
      if IsNan(v.toFloat) or (IsInfinite(v.toFloat) and (v.toFloat < 0)) then begin
        exit(false);
      end else if IsInfinite(v.toFloat) then begin
        res := high(res);
      end else res := round(v.toFloat);
    end;
    {pvkBigDecimal:}else begin
      temp := round(v.toDecimal);
      if not isInt64(temp) then exit(false);
      res := BigDecimalToInt64(temp);
    end;
  end;
end;

function xqToUInt64(const v: IXQValue; out res: int64): boolean;
begin
  result := xqToInt64(v, res);
  if res < 0 then result := false;
end;

function normalizePath(const path: IXQValue): UTF8String;
begin
  result := path.toString;
end;

function normalizePathToSys(const path: IXQValue): UTF8String;
begin
  result := UTF8ToSys(normalizePath(path));
end;

function FileExistsAsTrueFileUTF8(const Filename: string): boolean;
begin
  result := FileExistsUTF8(Filename) and not DirectoryExistsUTF8(Filename); //does this work?
end;

function exists(const args: TXQVArray): IXQValue;
begin
  result := xqvalue(FileExistsUTF8(normalizePath(args[0])));
end;

function is_dir(const args: TXQVArray): IXQValue;
begin
  result := xqvalue(DirectoryExistsUTF8(normalizePath(args[0])));
end;

function is_file(const args: TXQVArray): IXQValue;
begin
  result := xqvalue(FileExistsAsTrueFileUTF8(args[0].toString));
end;

function size(const args: TXQVArray): IXQValue;
var
  s: Int64;
  code: String;
  path: UTF8String;
begin
  path := normalizePath(args[0]);
  if DirectoryExistsUTF8(path) then exit(xqvalue(0));
  s := FileSizeUtf8(path);
  if s < 0 then begin
    if FileExistsUTF8(path) then code := Error_Io_Error
    else code := Error_Not_Found;
    raiseFileError(code, 'Failed to get size', args[0]);
  end;
  result := xqvalue(s);
end;

function writeOrAppendSomething(const filename: IXQValue; append: boolean; data: rawbytestring; offset: int64 = -1): IXQValue;
var f: TFileStream;
    mode: word;
    path: AnsiString;
begin
  path := normalizePathToSys(filename);
  if append then if not FileExistsUTF8(path) then append := false;
  if append then mode := fmOpenReadWrite
  else mode := fmCreate;
  f := TFileStream.Create(path, mode);
  if offset >= 0 then f.Position := offset
  else if append then f.position := f.size;
  try
    if length(data) > 0 then
      f.WriteBuffer(data[1], length(data));
  finally                                               //todo errors
    f.free;
  end;
  result := xqvalue();
end;

function writeOrAppendSerialized(const args: TXQVArray; append: boolean): IXQValue;
var
  temp: TXQueryEngine;
  data: IXQValue;
begin
  requiredArgCount(args, 2, 3);
  temp := TXQueryEngine.create;
  temp.VariableChangelog.add('data', args[1]);
  if length(args) = 3 then temp.VariableChangelog.add('args', args[2])
  else temp.VariableChangelog.add('args', xqvalue());
  data := temp.evaluateXQuery3('serialize($data, $args)'); //todo call serialization directly, handle encoding
  temp.free;
  result := writeOrAppendSomething(args[0], append, data.toString);
end;

function writeOrAppendText(const args: TXQVArray; append: boolean; text: string): IXQValue;
var
  data: String;
  enc: TEncoding;
begin
  data := text;
  if length(args) = 3 then begin
    enc := strEncodingFromName(args[2].toString);
    if enc = eUnknown then raise EXQEvaluationException.create(error_unknown_encoding, 'Unknown encoding: '+args[2].toString, XMLNamespace_Expath_File, args[2]);
    data := strChangeEncoding(data, eUTF8, enc);
  end;
  result := writeOrAppendSomething(args[0], append, data);
end;

function append(const args: TXQVArray): IXQValue;
begin
  result := writeOrAppendSerialized(args, true);
end;
function append_Binary(const args: TXQVArray): IXQValue;
begin
  result := writeOrAppendSomething(args[0], true, (args[1] as TXQValueString).toRawBinary);
end;
function append_Text(const args: TXQVArray): IXQValue;
begin
  result := writeOrAppendText(args, true, args[1].toString);
end;
function append_Text_Lines(const args: TXQVArray): IXQValue;
begin
  result := writeOrAppendText(args, true, args[1].toJoinedString(LineEnding) + LineEnding);
end;

function write(const args: TXQVArray): IXQValue;
begin
  result := writeOrAppendSerialized(args, false);
end;
function write_Binary(const args: TXQVArray): IXQValue;
var
  offset: int64;
begin
  offset := -1;
  if length(args) >= 3 then if not xqToUInt64(args[2], offset) then raiseFileError(Error_Out_Of_Range, Error_Out_Of_Range, args[2]);
  result := writeOrAppendSomething(args[0], length(args) >= 3, (args[1] as TXQValueString).toRawBinary, offset);
end;
function write_Text(const args: TXQVArray): IXQValue;
begin
  result := writeOrAppendText(args, false, args[1].toString);
end;
function write_Text_Lines(const args: TXQVArray): IXQValue;
begin
  result := writeOrAppendText(args, false, args[1].toJoinedString(LineEnding) + LineEnding);
end;

function copy(const args: TXQVArray): IXQValue;
var
  source: UTF8String;
  dest: UTF8String;
  ok: Boolean;
begin
  requiredArgCount(args,1,2);
  source := normalizePath(args[0]);
  dest := normalizePath(args[1]);
  if DirectoryExistsUTF8(source) then begin
    if FileExistsUTF8(dest) and not DirectoryExistsUTF8(dest) then raiseFileError(Error_Exists, 'Target cannot be overriden', args[1]);
    ok := CopyDirTree(source, dest, [cffCreateDestDirectory, cffOverwriteFile]);
  end else begin
    if not FileExistsUTF8(source) then raiseFileError(Error_Not_Found, 'No source', args[0]);
    ok := CopyFile(source, dest);
  end;
  if not ok then raiseFileError(Error_Io_Error, 'Copying failed', args[0]);
  result := xqvalue();
end;

function create_dir(const args: TXQVArray): IXQValue;
var
  dir: UTF8String;
begin
  dir := normalizePath(args[0]);
  if not ForceDirectoriesUTF8(dir) then
    raiseFileError( IfThen(FileExistsAsTrueFileUTF8(dir), Error_Exists, Error_Io_Error), 'Failed to create directories', args[0] );
  result := xqvalue();
end;

function create_temp_dir(const args: TXQVArray): IXQValue;
var
  dir: String;
begin
  requiredArgCount(args, 2, 3);
  if length(args) = 3 then begin
    dir := normalizePath(args[2]);
    if not DirectoryExistsUTF8(dir) then raiseFileError(Error_NoDir, 'Invalid directory', args[2]);
  end
  else dir := GetTempDir();
  dir := dir + DirectorySeparator + args[0].toString + IntToHex(Random($FFFFFFFF),8) + args[1].toString;
  if not ForceDirectoriesUTF8(dir) then raiseFileError(Error_Io_Error, 'Failed');
  result := xqvalue(dir);
end;

function create_temp_file(const args: TXQVArray): IXQValue;
var
  dir: String;
begin
  requiredArgCount(args, 2, 3);
  if length(args) = 3 then begin
    dir := normalizePath(args[2]);
    if not DirectoryExistsUTF8(dir) then raiseFileError(Error_NoDir, 'Invalid directory', args[2]);
  end
  else dir := GetTempDir();
  dir := dir + DirectorySeparator + args[0].toString + IntToHex(Random($FFFFFFFF),8) + args[1].toString;
  if not ForceDirectoriesUTF8(strResolveURI('/', dir)) then raiseFileError(Error_Io_Error, 'Failed');
  strSaveToFileUTF8(dir, '');
  result := xqvalue(dir);
end;

function delete(const args: TXQVArray): IXQValue;
var
  path: UTF8String;
  recursive: Boolean;
begin
  path := normalizePath(args[0]);
  recursive := (length(args) = 2) and args[1].toBoolean;
  if not FileExistsUTF8(path) then raiseFileError(Error_Not_Found, 'Cannot delete something not existing', args[0]);
  if not DirectoryExistsUTF8(path) then begin
    DeleteFileUTF8(path);
  end else if recursive then DeleteDirectory(path, false)
  else RemoveDirUTF8(path);
  result := xqvalue();
end;


type TListFilesAndDirs = class(TFileSearcher)
  res: TXQValueSequence;
private
  pathOffset: integer;
  masks: tmasklist;
protected
  procedure DoFileFound; override;
  procedure DoDirectoryFound; override;
  procedure addIt;
end;

procedure TListFilesAndDirs.DoFileFound;
begin
  addIt;
end;

procedure TListFilesAndDirs.DoDirectoryFound;
begin
  addIt;
end;

procedure TListFilesAndDirs.addIt;
var
  l: Integer;
  i: Integer;
begin
  if (masks <> nil) and not (masks.{$ifdef windows}MatchesWindowsMask{$else}Matches{$endif}(FileInfo.Name)) then exit;
  if pathOffset = 0 then begin
    l := level;
    for i := length(Path) downto 1 do begin
      if path[i] in AllowDirectorySeparators then begin
        if l <= 0 then begin
          pathOffset := i + 1;
          break;
        end;
        dec(l);
      end;
    end;
  end;
  res.add(xqvalue(strCopyFrom(path, pathOffset) + FileInfo.Name));
end;

function list(const args: TXQVArray): IXQValue;
var
  dir: UTF8String;
  recurse: Boolean;
  lister: TListFilesAndDirs;
begin
  requiredArgCount(args,1,3);
  dir := normalizePath(args[0]);
  recurse := (length(args) >= 2) and args[1].toBoolean;

  lister := TListFilesAndDirs.Create;
  if Length(args) >= 3 then begin
    lister.masks := TMaskList.Create(args[2].toString, '|', {$ifdef windows}false{$else}true{$endif});
    if lister.masks.Count = 0 then
      FreeAndNil(lister.masks);
  end;
  lister.res := TXQValueSequence.create();
  lister.Search(dir, '', recurse);
  result := lister.res;
  xqvalueSeqSqueeze(result);
  FreeAndNil(lister.masks);
  FreeAndNil(lister);
end;

function move(const args: TXQVArray): IXQValue;
var
  source: UTF8String;
  dest: UTF8String;
begin
  requiredArgCount(args,1,2);
  source := normalizePath(args[0]);
  dest := normalizePath(args[1]);

  if DirectoryExistsUTF8(source) then begin
    if FileExistsUTF8(dest) and not DirectoryExistsUTF8(dest) then raiseFileError(Error_Exists, 'Target cannot be overriden', args[1]);
  end else if not FileExistsUTF8(source) then raiseFileError(Error_Not_Found, 'No source', args[0]);

  if not RenameFileUTF8(source, dest) then raiseFileError(Error_Io_Error, 'Moving failed', args[0]);
  result := xqvalue();
end;


function readFromFile(const fn: String; from: int64 = 0; length: int64 = -1): rawbytestring;
var
  stream: TFileStream;
begin
  stream := TFileStream.Create(fn, fmOpenRead);
  try
    if from < 0 then raiseFileError(Error_Out_Of_Range, IntToStr(from) + ' < 0');
    if length = -1 then length := stream.Size - from;
    if length + from > stream.Size then raiseFileError(Error_Out_Of_Range, IntToStr(from)+' + ' +IntToStr(length) + ' > ' + IntToStr(stream.Size));
    SetLength(result, length);
    stream.Position := from;
    if length > 0 then
      stream.ReadBuffer(result[1], length);
  finally
    stream.free;
  end;
end;



function read_binary(const args: TXQVArray): IXQValue;
var
  from: int64;
  len: int64;
  rangeErr: Boolean;
begin
  from := 0;
  len := -1;
  rangeErr := false;
  if length(args) >= 2 then rangeErr := rangeErr or not xqToUInt64(args[1], from);
  if length(args) >= 3 then rangeErr := rangeErr or not xqToUInt64(args[2], len);
  if rangeErr then raiseFileError(Error_Out_Of_Range, Error_Out_Of_Range, args[2]);
  result := TXQValueString.create(baseSchema.base64Binary, base64.EncodeStringBase64(readFromFile(normalizePath(args[0]), from, len)));
end;

function read_text(const args: TXQVArray): IXQValue;
var
  data: rawbytestring;
  enc: TEncoding;
begin
  data := readFromFile(normalizePath(args[0]));
  if length(args) = 1 then result := xqvalue(data)
  else begin
    enc := strEncodingFromName(args[1].toString);
    if enc = eUnknown then raiseFileError(error_unknown_encoding, error_unknown_encoding, args[1]);
    result := xqvalue(strChangeEncoding(data,  enc, eUTF8));
  end;
end;                                         {

function is_file(const args: TXQVArray): IXQValue;
begin
  result := normalizePath(args[0]);
end;

function is_file(const args: TXQVArray): IXQValue;
begin
  result := normalizePath(args[0]);
end;

function is_file(const args: TXQVArray): IXQValue;
begin
  result := normalizePath(args[0]);
end;

function is_file(const args: TXQVArray): IXQValue;
begin
  result := normalizePath(args[0]);
end;

function is_file(const args: TXQVArray): IXQValue;
begin
  result := normalizePath(args[0]);
end;

function is_file(const args: TXQVArray): IXQValue;
begin
  result := normalizePath(args[0]);
end;

function is_file(const args: TXQVArray): IXQValue;
begin
  result := normalizePath(args[0]);
end;

function is_file(const args: TXQVArray): IXQValue;
begin
  result := normalizePath(args[0]);
end;

function is_file(const args: TXQVArray): IXQValue;
begin
  result := normalizePath(args[0]);
end;
                                          }


procedure registerModuleFile;
begin
  if Assigned(module) then exit;

  module := TXQNativeModule.create(XMLNamespace_Expath_File);
  module.registerFunction('exists', @exists, ['($path as xs:string) as xs:boolean']);
  module.registerFunction('is-dir', @is_dir, ['($path as xs:string) as xs:boolean']);
  module.registerFunction('is-file', @is_file, ['($path as xs:string) as xs:boolean']);
  module.registerFunction('size', @size, ['($file as xs:string) as xs:integer']);
  module.registerFunction('append', @append, ['($file as xs:string, $items as item()*) as empty-sequence()', '($file as xs:string, $items as item()*, $params as element(output:serialization-parameters)) as empty-sequence()']);
  module.registerFunction('append-binary', @append_binary, ['($file as xs:string, $value as xs:base64Binary) as empty-sequence()']);
  module.registerFunction('append-text', @append_text, ['($file as xs:string, $value as xs:string) as empty-sequence()','($file as xs:string, $value as xs:string, $encoding as xs:string) as empty-sequence()']);
  module.registerFunction('append-text-lines', @append_text_lines, ['($file as xs:string, $values as xs:string*) as empty-sequence()', '($file as xs:string, $lines as xs:string*, $encoding as xs:string) as empty-sequence()']);
  module.registerFunction('copy', @copy, ['($source as xs:string, $target as xs:string) as empty-sequence()']);
  module.registerFunction('create-dir', @create_dir, ['($dir as xs:string) as empty-sequence()']);
  module.registerFunction('create-temp-dir', @create_temp_dir, ['($prefix as xs:string, $suffix as xs:string) as xs:string', '($prefix as xs:string, $suffix as xs:string, $dir as xs:string) as xs:string']);
  module.registerFunction('create-temp-file', @create_temp_file, ['($prefix as xs:string, $suffix as xs:string) as xs:string', '($prefix as xs:string, $suffix as xs:string, $dir as xs:string) as xs:string']);
  module.registerFunction('delete', @delete, ['($path as xs:string) as empty-sequence()', '($path as xs:string, $recursive as xs:boolean) as empty-sequence()']);
  module.registerFunction('list', @list, ['($dir as xs:string) as xs:string*', '($dir as xs:string, $recursive as xs:boolean) as xs:string*', '($dir as xs:string, $recursive as xs:boolean, $pattern as xs:string) as xs:string*']);
  module.registerFunction('move', @move, ['($source as xs:string, $target as xs:string) as empty-sequence()']);
  module.registerFunction('read-binary', @read_binary, ['($file as xs:string) as xs:base64Binary', '($file as xs:string, $offset as xs:integer) as xs:base64Binary', '($file as xs:string, $offset as xs:integer, $length as xs:integer) as xs:base64Binary']);
  module.registerFunction('read-text', @read_text, ['($file as xs:string) as xs:string', '($file as xs:string, $encoding as xs:string) as xs:string']);
  module.registerInterpretedFunction('read-text-lines', '($file as xs:string) as xs:string*',                          'fn:tokenize(file:read-text($file           ), "\r\n|\r|\n")[not(position()=last() and .="")]');
  module.registerInterpretedFunction('read-text-lines', '($file as xs:string, $encoding as xs:string) as xs:string*',  'fn:tokenize(file:read-text($file, $encoding), "\r\n|\r|\n")[not(position()=last() and .="")]');
  module.registerFunction('write', @write, ['($file as xs:string, $items as item()*) as empty-sequence()', '($file as xs:string, $items as item()*, $params as element(output:serialization-parameters)) as empty-sequence()']);
  module.registerFunction('write-binary', @write_binary, ['($file as xs:string, $value as xs:base64Binary) as empty-sequence()', '($file as xs:string, $value as xs:base64Binary, $offset as xs:integer) as empty-sequence()']);
  module.registerFunction('write-text', @write_text, ['($file as xs:string, $value as xs:string) as empty-sequence()', '($file as xs:string, $value as xs:string, $encoding as xs:string) as empty-sequence()']);
  module.registerFunction('write-text-lines', @write_text_lines, ['($file as xs:string, $values as xs:string*) as empty-sequence()', '($file as xs:string, $values as xs:string*, $encoding as xs:string) as empty-sequence()']);



  TXQueryEngine.registerNativeModule(module);
end;


initialization
  XMLNamespace_Expath_File := TNamespace.create('http://expath.org/ns/file', 'file');

finalization
  module.free;

end.
