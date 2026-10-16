#requires -Version 5.1
[CmdletBinding()]
param(
 [string]$Repository,
 [string]$InstalledConfiguration,
 [Parameter(Mandatory=$true)][string]$ReportPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if (-not $Repository) { $Repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..')) }
$policy=Get-Content -LiteralPath (Join-Path $Repository 'Source/CharacterPolicy.cs') -Raw -Encoding UTF8
$parser=Get-Content -LiteralPath (Join-Path $Repository 'Source/CharacterConfigurationJson.cs') -Raw -Encoding UTF8
$wrapper=@'
namespace ZhaoHuoNatural {
 public static class ConfigurationJsonProbe {
  public static string Read(string json) {
   var parsed=CharacterConfigurationJson.Parse(json);
   var roles=CharacterPolicy.EnabledRoles(parsed);
   return string.Join(",",System.Linq.Enumerable.OrderBy(roles,x=>x,System.StringComparer.Ordinal).ToArray());
  }
 }
}
'@
Add-Type -TypeDefinition ($policy+"`n"+$parser+"`n"+$wrapper) -Language CSharp
$tests=New-Object 'System.Collections.Generic.List[object]'
function Check([string]$Name,[bool]$Passed){$tests.Add([pscustomobject]@{Name=$Name;Passed=$Passed})}
function Reject([string]$Name,[AllowNull()][string]$Json){$rejected=$false;try{[ZhaoHuoNatural.ConfigurationJsonProbe]::Read($Json)|Out-Null}catch{$rejected=$true};Check $Name $rejected}
$ids=@('player','tang-buyi','xiahou-lan')
$valid='{"SchemaVersion":1,"Characters":[{"Id":"player","Enabled":true},{"Id":"tang-buyi","Enabled":true},{"Id":"xiahou-lan","Enabled":true}]}'
for($mask=0;$mask-lt 8;$mask++){
 $entries=@(for($index=0;$index-lt 3;$index++){[ordered]@{Id=$ids[$index];Enabled=[bool]($mask-band(1-shl$index))}})
 $json=[ordered]@{SchemaVersion=1;Characters=$entries}|ConvertTo-Json -Depth 4
 $expected=(@($entries|Where-Object Enabled|ForEach-Object Id)-join ',')
 Check ('Installer JSON independent switch combination '+$mask) ([ZhaoHuoNatural.ConfigurationJsonProbe]::Read($json)-ceq $expected)
}
Check 'Compact installer schema' ([ZhaoHuoNatural.ConfigurationJsonProbe]::Read($valid)-ceq ($ids-join ','))
Check 'UTF8 BOM character and JSON whitespace accepted' ([ZhaoHuoNatural.ConfigurationJsonProbe]::Read(([char]0xFEFF)+" `r`n`t"+$valid+"`r`n")-ceq($ids-join ','))
$reordered='{"Characters":[{"Enabled":true,"Id":"xiahou-lan"},{"Enabled":false,"Id":"player"},{"Enabled":true,"Id":"tang-buyi"}],"SchemaVersion":1}'
Check 'Property and role order independent' ([ZhaoHuoNatural.ConfigurationJsonProbe]::Read($reordered)-ceq 'tang-buyi,xiahou-lan')
Check 'JSON Unicode escapes accepted' ([ZhaoHuoNatural.ConfigurationJsonProbe]::Read($valid.Replace('SchemaVersion','\u0053chemaVersion').Replace('player','\u0070layer'))-ceq($ids-join ','))
$expandedIds=@('player','tang-buyi','xiahou-lan','tang-moling','long-xiang','yu-xiaomei','tang-zheng')
$expandedValid=[ordered]@{SchemaVersion=2;Characters=@($expandedIds|ForEach-Object{[ordered]@{Id=$_;Enabled=$true}})}|ConvertTo-Json -Depth 4 -Compress
for($mask=0;$mask-lt 128;$mask++){
 $entries=@(for($index=0;$index-lt 7;$index++){[ordered]@{Id=$expandedIds[$index];Enabled=[bool]($mask-band(1-shl$index))}})
 $json=[ordered]@{SchemaVersion=2;Characters=$entries}|ConvertTo-Json -Depth 4
 $expected=(@($entries|Where-Object Enabled|ForEach-Object Id|Sort-Object)-join ',')
 Check ('Schema 2 independent switch combination '+$mask) ([ZhaoHuoNatural.ConfigurationJsonProbe]::Read($json)-ceq $expected)
}
$reverse=@($expandedIds);[array]::Reverse($reverse)
$expandedReordered=[ordered]@{Characters=@($reverse|ForEach-Object{[ordered]@{Enabled=$true;Id=$_}});SchemaVersion=2}|ConvertTo-Json -Depth 4 -Compress
Check 'Schema 2 property and role order independent' ([ZhaoHuoNatural.ConfigurationJsonProbe]::Read($expandedReordered)-ceq(@($expandedIds|Sort-Object)-join ','))
Check 'Legacy schema does not enable any new role' ([ZhaoHuoNatural.ConfigurationJsonProbe]::Read($valid)-ceq 'player,tang-buyi,xiahou-lan')
foreach($omitted in $expandedIds){
 $incomplete=[ordered]@{SchemaVersion=2;Characters=@($expandedIds|Where-Object{$_-cne$omitted}|ForEach-Object{[ordered]@{Id=$_;Enabled=$true}})}|ConvertTo-Json -Depth 4 -Compress
 Reject ('Schema 2 missing '+$omitted) $incomplete
}
Reject 'Schema 1 rejects seven-role configuration' ($expandedValid.Replace('"SchemaVersion":2','"SchemaVersion":1'))
Reject 'Schema 2 rejects three-role configuration' ($valid.Replace('"SchemaVersion":1','"SchemaVersion":2'))
Reject 'Schema 2 rejects duplicate character' ($expandedValid.Replace('yu-xiaomei','long-xiang'))
Reject 'Schema 2 rejects unknown character' ($expandedValid.Replace('yu-xiaomei','unknown'))
Reject 'Schema 2 rejects eighth entry' ($expandedValid.Replace(']}',',{"Id":"player","Enabled":false}]}'))
Reject 'Schema 2 rejects decimal version' ($expandedValid.Replace('"SchemaVersion":2','"SchemaVersion":2.0'))
Reject 'Schema 2 rejects concatenated version' ($expandedValid.Replace('"SchemaVersion":2','"SchemaVersion":21'))
$bad=@(
 @('Empty document',''),@('Null document','null'),@('Array root','[]'),@('Empty root','{}'),
 @('Missing schema',$valid.Replace('"SchemaVersion":1,','')),
 @('Unknown schema',$valid.Replace('"SchemaVersion":1','"SchemaVersion":3')),
 @('String schema',$valid.Replace('"SchemaVersion":1','"SchemaVersion":"1"')),
 @('Floating schema',$valid.Replace('"SchemaVersion":1','"SchemaVersion":1.0')),
 @('Leading zero schema',$valid.Replace('"SchemaVersion":1','"SchemaVersion":01')),
 @('Duplicate schema',$valid.Replace('"SchemaVersion":1','"SchemaVersion":1,"SchemaVersion":1')),
 @('Unknown root property',$valid.Replace('"SchemaVersion":1','"SchemaVersion":1,"Untrusted":true')),
 @('Missing characters','{"SchemaVersion":1}'),@('Null characters','{"SchemaVersion":1,"Characters":null}'),
 @('Empty characters','{"SchemaVersion":1,"Characters":[]}'),
 @('Missing one character',$valid.Replace(',{"Id":"xiahou-lan","Enabled":true}','')),
 @('Fourth entry',$valid.Replace(']}',',{"Id":"player","Enabled":true}]}')),
 @('Unknown ID',$valid.Replace('tang-buyi','brother2')),
 @('Duplicate ID',$valid.Replace('xiahou-lan','player')),
 @('Wrong case ID',$valid.Replace('player','PLAYER')),
 @('Missing enabled',$valid.Replace('"Id":"player","Enabled":true','"Id":"player"')),
 @('Duplicate enabled',$valid.Replace('"Id":"player","Enabled":true','"Id":"player","Enabled":true,"Enabled":false')),
 @('String boolean',$valid.Replace('true','"true"')),@('Integer boolean',$valid.Replace('true','1')),
 @('Null boolean',$valid.Replace('true','null')),@('Capitalized boolean',$valid.Replace('true','True')),
 @('Missing ID',$valid.Replace('"Id":"player",','')),
 @('Duplicate ID field',$valid.Replace('"Id":"player"','"Id":"player","Id":"player"')),
 @('Unknown character property',$valid.Replace('"Id":"player"','"Id":"player","Other":false')),
 @('Extra document',($valid+'{}')),@('Trailing comment',($valid+'// comment')),
 @('Array trailing comma',$valid.Replace(']}',',]}')),
 @('Object trailing comma',($valid.Substring(0,$valid.Length-1)+',}')),
 @('Wrong property case',$valid.Replace('Characters','characters')),
 @('Invalid JSON escape',$valid.Replace('player','pla\qyer')),
 @('Invalid unicode escape',$valid.Replace('player','\u0ZZZplayer')),
 @('Incomplete unicode escape',$valid.Replace('player','\u0')),
 @('Unescaped control character',$valid.Replace('player',"pla`nyer")),
 @('Truncated JSON',$valid.Substring(0,$valid.Length-1)),
 @('Oversized input',(' '*65537))
)
foreach($case in $bad){Reject $case[0] $case[1]}
$actual=$null
if($InstalledConfiguration){
 $sample=[IO.File]::ReadAllText((Resolve-Path -LiteralPath $InstalledConfiguration).Path,[Text.Encoding]::UTF8)
 $expectedObject=$sample|ConvertFrom-Json
 $expected=(@($expectedObject.Characters|Where-Object Enabled|ForEach-Object Id|Sort-Object)-join ',')
 Check 'Actual installed JSON parsed through production parser' ([ZhaoHuoNatural.ConfigurationJsonProbe]::Read($sample)-ceq $expected)
 $actual=[ordered]@{ReadOnly=$true;SHA256=(Get-FileHash -LiteralPath $InstalledConfiguration).Hash;EnabledRoles=$expected}
}
function NormalizedHash([string]$Path){$text=[IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF).Replace("`r`n","`n").Replace("`r","`n");$sha=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','')}finally{$sha.Dispose()}}
$failed=@($tests|Where-Object{-not $_.Passed})
$report=[ordered]@{Passed=($failed.Count-eq 0);TestCount=$tests.Count;PassedCount=$tests.Count-$failed.Count;PowerShellVersion=$PSVersionTable.PSVersion.ToString();ActualGameRun=$false;Scope='Production managed JSON parser compiled unchanged with character policy; real installed JSON read only when supplied. No Unity/game assembly executed or game file modified.';ActualConfiguration=$actual;CodeHashAlgorithm='SHA256-UTF8-noBOM-LF-v1';CodeHashes=@(foreach($path in @('Source/CharacterPolicy.cs','Source/CharacterConfigurationJson.cs','Source/CharacterSupport.cs','Source/build.ps1','Source/Tests/Test-CharacterConfiguration.ps1')){[pscustomobject]@{Path=$path;Sha256=NormalizedHash (Join-Path $Repository $path)}});Tests=$tests.ToArray()}
[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($false)))
[pscustomobject]$report|Select-Object Passed,TestCount,PassedCount,PowerShellVersion|ConvertTo-Json
if($failed.Count){$failed|ConvertTo-Json;throw 'Configuration parser regression failed.'}
