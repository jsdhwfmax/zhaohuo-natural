#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$GamePath,
    [string]$PriorManagedPath,
    [string]$PackageRoot
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if (-not $PackageRoot) {$PackageRoot=Split-Path -Parent $PSScriptRoot}
. (Join-Path $PackageRoot 'installer\CompatibilityProbe.ps1')
$baseline=Get-Content -LiteralPath (Join-Path $PackageRoot 'installer\compatibility-baseline.json') -Raw -Encoding UTF8 | ConvertFrom-Json
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
    $results.Add([pscustomobject][ordered]@{Test=$Name;Passed=$true;ExpectedCompatible=$Expected;Seconds=[Math]::Round($timer.Elapsed.TotalSeconds,2);Reasons=@($result.Reasons);Checks=@($result.Checks)})
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
Assert-Probe 'Current validated game, read only' $true $GamePath
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
foreach($relative in @('installer/compatibility-baseline.json','Dependencies/BepInEx/files/BepInEx/core/Mono.Cecil.dll','BepInEx/plugins/ZhaoHuoNatural/ZhaoHuoNatural.dll')) {Copy-ToFixture $PackageRoot $fixturePackage $relative}
[IO.File]::AppendAllText((Join-Path $fixturePackage 'installer\compatibility-baseline.json'),' ')
Assert-Probe 'Changed baseline rejected' $false $fixture $fixturePackage
Copy-ToFixture $PackageRoot $fixturePackage 'installer/compatibility-baseline.json'
[IO.File]::AppendAllText((Join-Path $fixturePackage 'Dependencies\BepInEx\files\BepInEx\core\Mono.Cecil.dll'),' ')
Assert-Probe 'Changed trusted metadata reader rejected' $false $fixture $fixturePackage
foreach($name in $sourceHashes.Keys) {if ((Get-ZHCPHash (Join-Path $GamePath ('Mortal_Data\Managed\'+$name))) -ne $sourceHashes[$name]) {throw 'Source game changed during test; results invalid'}}
$results.Add([pscustomobject]@{Test='Source game assembly fingerprints unchanged';Passed=$true})
$summary=[pscustomobject][ordered]@{Passed=$true;PowerShellVersion=$PSVersionTable.PSVersion.ToString();BaselineSha256=(Get-ZHCPHash (Join-Path $PackageRoot 'installer\compatibility-baseline.json'));TestCount=$results.Count;Tests=$results.ToArray()}
$summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'results-compatibility.json') -Encoding UTF8
Write-Host ('All '+$results.Count+' focused compatibility checks passed. Only isolated fixture copies were modified.')
