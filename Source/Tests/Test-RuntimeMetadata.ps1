#requires -Version 5.1
param([string]$Repository,[Parameter(Mandatory=$true)][string]$GamePath,[Parameter(Mandatory=$true)][string]$NewPlugin,[Parameter(Mandatory=$true)][string]$ReportPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if (-not $Repository) { $Repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..')) }
$cecil=Join-Path $Repository 'Dependencies\BepInEx\files\BepInEx\core\Mono.Cecil.dll'
if((Get-FileHash -LiteralPath $cecil).Hash -ne '7AE470288FFF4A402899C254D0A76CEFEF55877F5C54F96E83C797CC5BB6E2F6'){throw 'Unexpected Mono.Cecil'}
Add-Type -Path $cecil
$resolver=New-Object Mono.Cecil.DefaultAssemblyResolver
$resolver.AddSearchDirectory((Join-Path $GamePath 'Mortal_Data\Managed'))
$resolver.AddSearchDirectory((Join-Path $Repository 'Dependencies\BepInEx\files\BepInEx\core'))
$reader=New-Object Mono.Cecil.ReaderParameters; $reader.AssemblyResolver=$resolver
$old=$null;$new=$null;$story=$null;$core=$null
try {
 $old=[Mono.Cecil.ModuleDefinition]::ReadModule((Join-Path $Repository 'BepInEx\plugins\ZhaoHuoNatural\ZhaoHuoNatural.dll'),$reader)
 $new=[Mono.Cecil.ModuleDefinition]::ReadModule($NewPlugin,$reader)
 $story=[Mono.Cecil.ModuleDefinition]::ReadModule((Join-Path $GamePath 'Mortal_Data\Managed\Mortal.Story.dll'),$reader)
 $core=[Mono.Cecil.ModuleDefinition]::ReadModule((Join-Path $GamePath 'Mortal_Data\Managed\Mortal.Core.dll'),$reader)
 $scopes=@('Mortal.Core','Mortal.Story','Fungus','OBB.Framework')
 $oldRefs=@($old.GetMemberReferences()|Where-Object {$_.DeclaringType.Scope.Name -in $scopes})
 $newRefs=@($new.GetMemberReferences()|Where-Object {$_.DeclaringType.Scope.Name -in $scopes})
 $unresolved=@($newRefs|Where-Object {$null -eq $_.Resolve()}|ForEach-Object FullName)
 $fields=@(
  @($story,'Mortal.Story.StoryCharacterController','_operationList','System.Collections.Generic.List`1<UnityEngine.ResourceManagement.AsyncOperations.AsyncOperationHandle`1<UnityEngine.Sprite>>'),
  @($core,'Mortal.Core.PlayerAvatarPanel','_avatarImage','UnityEngine.UI.Image'),
  @($core,'Mortal.Core.SocialStatPanel','_currentData','Mortal.Core.RelationshipStat'),
  @($core,'Mortal.Core.CharacterIntroPanel','_avatarImageBack2','UnityEngine.UI.Image')
 )
 $fieldChecks=@(foreach($row in $fields){$t=$row[0].Types|Where-Object FullName -eq $row[1];$f=$t.Fields|Where-Object Name -eq $row[2];[pscustomobject]@{Field=$row[1]+'::'+$row[2];Passed=($null -ne $f -and $f.FieldType.FullName -ceq $row[3]);Type=$f.FieldType.FullName}})
 $controller=$story.Types|Where-Object FullName -eq 'Mortal.Story.StoryCharacterController'
 $methods=@(foreach($name in @('LoadPortrait','LoadPortraitSync','LoadPortraitAssetByAddressable')){$method=@($controller.Methods|Where-Object Name -eq $name);[pscustomobject]@{Name=$name;Passed=($method.Count -eq 1);Signature=$method[0].FullName}})
 $baseline=Get-Content -LiteralPath (Join-Path $Repository 'installer\compatibility-baseline.json') -Raw -Encoding UTF8|ConvertFrom-Json
 $counts=@($baseline.FixedFiles|Group-Object Category|ForEach-Object {[pscustomobject]@{Category=$_.Name;Count=$_.Count}})
 $added=@($newRefs.FullName|Where-Object {$_ -notin $oldRefs.FullName}|Sort-Object)
 $unchangedRefs=$newRefs.Count-eq$oldRefs.Count -and $added.Count-eq 0
 $passed=$unchangedRefs -and $unresolved.Count -eq 0 -and @($fieldChecks|Where-Object {-not $_.Passed}).Count -eq 0 -and @($methods|Where-Object {-not $_.Passed}).Count -eq 0
 function NormalizedHash([string]$Path){$text=[IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF).Replace("`r`n","`n").Replace("`r","`n");$sha=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','')}finally{$sha.Dispose()}}
 $report=[pscustomobject]@{Passed=$passed;ActualGameRun=$false;Scope='Static Mono.Cecil metadata inspection only; game assemblies not executed.';NewPluginSha256=(Get-FileHash -LiteralPath $NewPlugin).Hash;OldGameMemberReferenceCount=$oldRefs.Count;NewGameMemberReferenceCount=$newRefs.Count;UnchangedGameMemberReferences=$unchangedRefs;AddedGameMemberReferences=$added;UnresolvedGameMemberReferences=$unresolved;ReflectedFields=$fieldChecks;HookMethods=$methods;ExistingBaselineResourceCoverage=$counts;ExistingCoreMethods=$baseline.CoreSurface.Methods.Count;ExistingCoreTypes=$baseline.CoreSurface.Types.Count;CodeHashAlgorithm='SHA256-UTF8-noBOM-LF-v1';CodeHashes=@(foreach($path in @('Source/Plugin.cs','Source/CharacterPolicy.cs','Source/CharacterSupport.cs','Source/CharacterConfigurationJson.cs','Source/build.ps1','Source/Tests/Test-RuntimeMetadata.ps1')){[pscustomobject]@{Path=$path;Sha256=NormalizedHash (Join-Path $Repository $path)}});NecessaryBaselineChanges=@('Pin the final rebuilt plugin hash; member reference count remains 23.','Re-pin the baseline bytes in CompatibilityProbe.ps1 after coordinated regeneration.','Mortal.Story.dll (including _operationList and all portrait method bodies) remains fixed by the existing dependency hash.','Retain all 395 fixed files and all exact resource checks; do not weaken unknown-build validation.','Regenerate offline probe evidence and run real multi-character diagnostics before release.')}
 $report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $ReportPath -Encoding UTF8
 $report|Select-Object Passed,OldGameMemberReferenceCount,NewGameMemberReferenceCount,NewPluginSha256|ConvertTo-Json -Compress
 if(-not $passed){throw 'Runtime metadata validation failed.'}
} finally {foreach($module in @($old,$new,$story,$core)){if($module){$module.Dispose()}};$resolver.Dispose()}
