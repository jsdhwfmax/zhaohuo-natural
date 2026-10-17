#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$GamePath,
    [string]$PriorManagedPath,
    [string]$PriorGamePath,
    [string]$PackageRoot,
    [string]$ReportPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if (-not $PackageRoot) {$PackageRoot=Split-Path -Parent $PSScriptRoot}
. (Join-Path $PackageRoot 'installer\CompatibilityProbe.ps1')
$initial=Test-ZhaoHuoCompatibility -GamePath $GamePath -PackageRoot $PackageRoot
if(-not $initial.Compatible){throw ('Current source failed before fixture creation: '+($initial.Reasons -join '; '))}
$baseline=Get-Content -LiteralPath (Join-Path $PackageRoot $initial.MatchedBaselineFile) -Raw -Encoding UTF8 | ConvertFrom-Json
if(-not $ReportPath){$ReportPath=Join-Path $PackageRoot 'verification\compatibility-probe-tests-build25987745.json'}
$work=Join-Path $PSScriptRoot ('.work\probe-'+[guid]::NewGuid().ToString('N'))
$fixture=Join-Path $work 'Game'
$fixturePackage=Join-Path $work 'Package'
$results=New-Object 'System.Collections.Generic.List[object]'
$sourceHashes=@{}
foreach($name in @('Assembly-CSharp.dll','Mortal.Core.dll','Mortal.Story.dll','Fungus.dll')) {$sourceHashes[$name]=Get-ZHCPHash (Join-Path $GamePath ('Mortal_Data\Managed\'+$name))}
function Assert-Probe([string]$Name,[bool]$Expected,[string]$Root=$fixture,[string]$Package=$PackageRoot) {
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $result=Test-ZhaoHuoCompatibility -GamePath $Root -PackageRoot $Package
    $timer.Stop()
    if ($result.Compatible -ne $Expected) {throw ($Name+': unexpected Compatible='+$result.Compatible+'; '+($result.Reasons -join '; '))}
    if ($Expected -and (@($result.Checks | Where-Object {-not $_.Passed}).Count -or @($result.Checks).Count -lt 12 -or $result.FingerprintSet.Count -ne 4)) {throw ($Name+': incomplete evidence')}
    $results.Add([pscustomobject][ordered]@{Test=$Name;Passed=$true;ExpectedCompatible=$Expected;MatchedBaselineFile=$result.MatchedBaselineFile;BaselineBuildIds=@($result.BaselineBuildIds);Seconds=[Math]::Round($timer.Elapsed.TotalSeconds,2);Reasons=@($result.Reasons);Checks=@($result.Checks)})
    Write-Host ('PASS '+$Name+' ('+[Math]::Round($timer.Elapsed.TotalSeconds,1)+'s)')
}
function Copy-ToFixture([string]$SourceRoot,[string]$TargetRoot,[string]$Relative) {
    $source=Get-ZHCPChild $SourceRoot $Relative; $target=Get-ZHCPChild $TargetRoot $Relative
    [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
    Copy-Item -LiteralPath $source -Destination $target -Force
}
function Reset-Core {Copy-Item -LiteralPath (Join-Path $GamePath 'Mortal_Data\Managed\Mortal.Core.dll') -Destination (Join-Path $fixture 'Mortal_Data\Managed\Mortal.Core.dll') -Force}
function Rewrite-Core([scriptblock]$Change) {
    $managed=Join-Path $fixture 'Mortal_Data\Managed'
    $resolver=New-Object Mono.Cecil.DefaultAssemblyResolver; $resolver.AddSearchDirectory($managed)
    $reader=New-Object Mono.Cecil.ReaderParameters; $reader.AssemblyResolver=$resolver
    $module=[Mono.Cecil.ModuleDefinition]::ReadModule((Join-Path $managed 'Mortal.Core.dll'),$reader)
    $next=Join-Path $managed 'Mortal.Core.rewritten'
    try { & $Change $module; $module.Write($next) } finally {$module.Dispose();$resolver.Dispose()}
    Move-Item -LiteralPath $next -Destination (Join-Path $managed 'Mortal.Core.dll') -Force
}
function Add-Nop($Module,[string]$TypeName,[string]$MethodName) {
    $type=@(Get-ZHCPTypes $Module.Types | Where-Object {$_.FullName -ceq $TypeName})[0]
    $method=@($type.Methods | Where-Object {$_.Name -ceq $MethodName -and $_.HasBody})[0]
    $il=$method.Body.GetILProcessor(); $il.InsertBefore($method.Body.Instructions[0],$il.Create([Mono.Cecil.Cil.OpCodes]::Nop))
}
function Flip-FixtureByte([string]$Relative) {
    $path=Get-ZHCPChild $fixture $Relative
    $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {$value=$stream.ReadByte();$stream.Position=0;$stream.WriteByte([byte]($value -bxor 1))}finally{$stream.Dispose()}
}
Assert-Probe 'Current build 25987745, read only static inspection' $true $GamePath
if($PriorGamePath){Assert-Probe 'Prior authentic complete game snapshot still accepted' $true $PriorGamePath}
foreach($file in $baseline.FixedFiles) {Copy-ToFixture $GamePath $fixture $file.RelativePath}
Copy-ToFixture $GamePath $fixture $baseline.VersionMetadata.RelativePath
Reset-Core
if ($PriorManagedPath) {
    Copy-Item -LiteralPath (Join-Path $PriorManagedPath 'Mortal.Core.dll') -Destination (Join-Path $fixture 'Mortal_Data\Managed\Mortal.Core.dll') -Force
    Assert-Probe 'Prior authentic core with current validated resources' $true
    Reset-Core
}
Rewrite-Core {
    param($module)
    Add-Nop $module 'Mortal.Core.MartialPanel' 'UpdateStatRelation'
    $type=@($module.Types | Where-Object {$_.FullName -eq 'Mortal.Core.MartialPanel'})[0]
    $attrs=[Mono.Cecil.MethodAttributes]([int][Mono.Cecil.MethodAttributes]::Public -bor [int][Mono.Cecil.MethodAttributes]::Static)
    $extra=New-Object Mono.Cecil.MethodDefinition('OfflineProbeUnrelatedAddition',$attrs,$module.TypeSystem.Void)
    $extra.Body.Instructions.Add([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Ret));$type.Methods.Add($extra)
}
Assert-Probe 'Unrelated IL edit plus new method and metadata rewrite' $true
Reset-Core
Rewrite-Core {param($module) Add-Nop $module 'Mortal.Core.PlayerAvatarPanel' 'OnEnable'}
Assert-Probe 'Changed direct portrait hook rejected' $false
Reset-Core
if (-not @($baseline.CoreSurface.Methods | Where-Object {$_.Name -eq 'T Mortal.Core.AssetReferenceCache`1::LoadSync()'}).Count) {throw 'Transitive helper missing from baseline'}
Rewrite-Core {param($module) Add-Nop $module 'Mortal.Core.AssetReferenceCache`1' 'LoadSync'}
Assert-Probe 'Changed transitive asset loader helper rejected' $false
Reset-Core
Rewrite-Core {
    param($module)
    $type=@($module.Types | Where-Object {$_.FullName -eq 'Mortal.Core.PlayerAvatarPanel'})[0]
    $field=@($type.Fields | Where-Object {$_.Name -eq '_avatarImage'})[0];$field.Name='_changedAvatarImage'
}
Assert-Probe 'Changed portrait field layout rejected' $false
Reset-Core
$resource=@($baseline.FixedFiles | Where-Object {$_.RelativePath -like '*portrait_player_assets_all*.bundle'})[0]
Flip-FixtureByte $resource.RelativePath
Assert-Probe 'Changed portrait bundle with unchanged catalog rejected' $false
Copy-ToFixture $GamePath $fixture $resource.RelativePath
$catalog='Mortal_Data/StreamingAssets/aa/catalog.json'
Flip-FixtureByte $catalog
Assert-Probe 'Changed Addressables catalog rejected' $false
Copy-ToFixture $GamePath $fixture $catalog
$framework='Mortal_Data/Managed/Unity.Addressables.dll'
Flip-FixtureByte $framework
Assert-Probe 'Changed Addressables runtime rejected' $false
Copy-ToFixture $GamePath $fixture $framework
if($PriorGamePath){
    foreach($mixedPath in @('Mortal_Data/StreamingAssets/aa/catalog.json','Mortal_Data/globalgamemanagers.assets')){
        Copy-ToFixture $PriorGamePath $fixture $mixedPath
        Assert-Probe ('Old/new individually known snapshot files cannot be mixed: '+$mixedPath) $false
        Copy-ToFixture $GamePath $fixture $mixedPath
    }
}
$extraBundle=Get-ZHCPChild $fixture 'Mortal_Data/StreamingAssets/aa/StandaloneWindows64/offline-probe-extra.bundle'
[IO.File]::WriteAllBytes($extraBundle,[byte[]]@(1,2,3))
Assert-Probe 'Unexpected additional bundle rejected by exact inventory' $false
Remove-Item -LiteralPath $extraBundle
$extraScene=Get-ZHCPChild $fixture 'Mortal_Data/offline-probe-extra.assets'
[IO.File]::WriteAllBytes($extraScene,[byte[]]@(1,2,3))
Assert-Probe 'Unexpected additional serialized asset rejected' $false
Remove-Item -LiteralPath $extraScene
$versionPath=Get-ZHCPChild $fixture $baseline.VersionMetadata.RelativePath
$versionBytes=[IO.File]::ReadAllBytes($versionPath)
$latin=[Text.Encoding]::GetEncoding(28591)
$versionText=$latin.GetString($versionBytes)
$versionText=[regex]::Replace($versionText,'release_[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+','release_1.0.6000.4')
[IO.File]::WriteAllBytes($versionPath,$latin.GetBytes($versionText))
Assert-Probe 'Version label only change with unchanged protected behavior accepted' $true
[IO.File]::WriteAllBytes($versionPath,$versionBytes)
Flip-FixtureByte $baseline.VersionMetadata.RelativePath
Assert-Probe 'Non-version bootstrap metadata change rejected' $false
[IO.File]::WriteAllBytes($versionPath,$versionBytes)
$packageFiles=@((Get-ZHCompatibilityBaselineFiles|ForEach-Object RelativePath))+@('Dependencies/BepInEx/files/BepInEx/core/Mono.Cecil.dll','BepInEx/plugins/ZhaoHuoNatural/ZhaoHuoNatural.dll')
foreach($relative in $packageFiles) {Copy-ToFixture $PackageRoot $fixturePackage $relative}
[IO.File]::AppendAllText((Join-Path $fixturePackage 'installer\compatibility-baseline-25987745.json'),' ')
Assert-Probe 'Changed new baseline rejected' $false $fixture $fixturePackage
Copy-ToFixture $PackageRoot $fixturePackage 'installer/compatibility-baseline-25987745.json'
[IO.File]::AppendAllText((Join-Path $fixturePackage 'installer\compatibility-baseline.json'),' ')
Assert-Probe 'Changed prior baseline rejected even when current snapshot would match' $false $fixture $fixturePackage
Copy-ToFixture $PackageRoot $fixturePackage 'installer/compatibility-baseline.json'
Remove-Item -LiteralPath (Join-Path $fixturePackage 'installer\compatibility-baseline.json')
Assert-Probe 'Missing prior baseline rejects incomplete package' $false $fixture $fixturePackage
Copy-ToFixture $PackageRoot $fixturePackage 'installer/compatibility-baseline.json'
[IO.File]::AppendAllText((Join-Path $fixturePackage 'BepInEx\plugins\ZhaoHuoNatural\ZhaoHuoNatural.dll'),' ')
Assert-Probe 'Changed runtime plugin rejected' $false $fixture $fixturePackage
Copy-ToFixture $PackageRoot $fixturePackage 'BepInEx/plugins/ZhaoHuoNatural/ZhaoHuoNatural.dll'
[IO.File]::AppendAllText((Join-Path $fixturePackage 'Dependencies\BepInEx\files\BepInEx\core\Mono.Cecil.dll'),' ')
Assert-Probe 'Changed trusted metadata reader rejected' $false $fixture $fixturePackage
foreach($name in $sourceHashes.Keys) {if ((Get-ZHCPHash (Join-Path $GamePath ('Mortal_Data\Managed\'+$name))) -ne $sourceHashes[$name]) {throw 'Source game changed during test; results invalid'}}
$results.Add([pscustomobject]@{Test='Source game assembly fingerprints unchanged';Passed=$true})
$baselineRecords=@(foreach($spec in (Get-ZHCompatibilityBaselineFiles)){$b=Get-Content -LiteralPath (Join-Path $PackageRoot $spec.RelativePath) -Raw -Encoding UTF8|ConvertFrom-Json;[pscustomobject]@{Path=$spec.RelativePath;Sha256=$spec.Sha256;BuildIds=@($b.BaselineBuildIds);FixedFileCount=@($b.FixedFiles).Count;GameMemberReferenceCount=$b.GameMemberReferenceCount}})
$codePaths=@('installer/CompatibilityProbe.ps1','installer/compatibility-baseline.json','installer/compatibility-baseline-25987745.json','scripts/Generate-CompatibilityBaseline.ps1','tests/Test-CompatibilityProbe.ps1','Source/Plugin.cs','Source/CharacterPolicy.cs','Source/CharacterSupport.cs','Source/build.ps1')
$codeHashes=@(foreach($relative in $codePaths){$text=[IO.File]::ReadAllText((Join-Path $PackageRoot $relative)).TrimStart([char]0xFEFF).Replace("`r`n","`n");[pscustomobject]@{Path=$relative;Sha256=(Get-ZHCPTextHash $text)}})
$summary=[pscustomobject][ordered]@{Passed=$true;ActualGameRun=$false;Scope='Read-only source metadata/resource checks and isolated copied-file mutation tests. No game process launched; historical snapshots do not claim current runtime verification.';PowerShellVersion=$PSVersionTable.PSVersion.ToString();PluginSha256=$baseline.PluginSha256;BaselineSha256=$script:ZHCompatibilityBaselineHash;FixedFileCount=@($baseline.FixedFiles).Count;GameMemberReferenceCount=$baseline.GameMemberReferenceCount;Baselines=$baselineRecords;CodeHashAlgorithm='SHA256-UTF8-noBOM-LF-v1';CodeHashes=$codeHashes;TestCount=$results.Count;Tests=$results.ToArray()}
$summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
Write-Host ('All '+$results.Count+' focused compatibility checks passed. Only isolated fixture copies were modified.')
