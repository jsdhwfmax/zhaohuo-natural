#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$GamePath,[string]$PackageRoot,[string]$ReportPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if(-not $PackageRoot){$PackageRoot=Split-Path -Parent $PSScriptRoot}
if(-not $ReportPath){$ReportPath=Join-Path $PackageRoot 'verification/build26021712-validation-tests.json'}
$module=Import-Module (Join-Path $PackageRoot 'installer/ZhaoHuoInstaller.psm1') -Force -PassThru
$work=Join-Path $PSScriptRoot ('.work/build26021712-'+[guid]::NewGuid().ToString('N'))
$fixture=Join-Path $work 'steamapps/common/Game'
$acf=Join-Path $work 'steamapps/appmanifest_1859910.acf'
$results=New-Object 'System.Collections.Generic.List[object]'
$names=@('Assembly-CSharp.dll','Mortal.Core.dll','Mortal.Story.dll','Fungus.dll')
$sourceHashes=[ordered]@{}
foreach($relative in @('Mortal.exe','UnityPlayer.dll')+@($names|ForEach-Object{'Mortal_Data/Managed/'+$_})){
    $source=Join-Path $GamePath $relative;$destination=Join-Path $fixture $relative
    [IO.Directory]::CreateDirectory((Split-Path -Parent $destination))|Out-Null
    Copy-Item -LiteralPath $source -Destination $destination
    $sourceHashes[$relative]=(Get-FileHash -LiteralPath $source).Hash
}
function Check([string]$Name,[bool]$Condition){if(-not $Condition){throw $Name};$results.Add([pscustomobject]@{Test=$Name;Passed=$true});Write-Host ('PASS '+$Name)}
function Set-FixtureBuild([string]$Build){[IO.File]::WriteAllText($acf,('"AppState" { "appid" "1859910" "buildid" "'+$Build+'" }'))}
$supported=@(& $module {$script:SupportedGameBuilds})
Check 'All previously supported build groups are retained' ((@($supported.BuildId)-join ',') -ceq '25953419,25957922,25987745,26021712')
$current=@($supported|Where-Object BuildId -eq '26021712')[0]
foreach($name in $names){Check ('Current declared fingerprint matches the observed game: '+$name) ($current.Hashes[$name] -eq $sourceHashes['Mortal_Data/Managed/'+$name])}
# A rejecting stub detects routing without changing any game file or executing game code.
& $module {
    $script:BuildRoutingProbeCalls=0
    function script:Invoke-ZHCompatibilityProbe([string]$GamePath,[string]$PackageRoot){
        $script:BuildRoutingProbeCalls++
        [pscustomobject]@{Compatible=$false;Method='OfflineCompatibilityProbe';Reasons=@('routing-test-rejection');Checks=@();BaselineBuildIds=@();FingerprintSet=@{}}
    }
}
Set-FixtureBuild '26021712'
$validation=& $module {param($game,$package) Get-ZHGameValidation $game $package} $fixture $PackageRoot
Check 'Exact current build and all four fingerprints use the verified group' ($validation.CompatibilityMode -eq 'VerifiedFingerprint' -and $validation.MatchedBuildId -eq '26021712' -and $validation.DetectedBuild -eq '26021712')
Check 'Exact current group does not invoke the unknown-build probe' ((& $module {$script:BuildRoutingProbeCalls}) -eq 0)
function Expect-ProbeReject([string]$Name){
    $before=& $module {$script:BuildRoutingProbeCalls};$rejected=$false
    try{$null=& $module {param($game,$package) Get-ZHGameValidation $game $package} $fixture $PackageRoot}catch{$rejected=$_.Exception.Message.Contains('routing-test-rejection')}
    Check $Name ($rejected -and (& $module {$script:BuildRoutingProbeCalls}) -eq ($before+1))
}
Set-FixtureBuild '99999999'
Expect-ProbeReject 'Same four DLLs with a future build require the offline probe'
Remove-Item -LiteralPath $acf
Expect-ProbeReject 'Missing Steam manifest cannot claim the known build'
Set-FixtureBuild '25987745'
Expect-ProbeReject 'Current DLLs cannot claim the prior verified build'
Set-FixtureBuild '26021712'
$core=Join-Path $fixture 'Mortal_Data/Managed/Mortal.Core.dll'
[IO.File]::AppendAllText($core,'isolated fixture mutation')
Expect-ProbeReject 'One modified DLL disables the current build fast path'
foreach($relative in $sourceHashes.Keys){Check ('Read-only source preserved: '+$relative) ((Get-FileHash -LiteralPath (Join-Path $GamePath $relative)).Hash -eq $sourceHashes[$relative])}
function CodeHash([string]$Relative){$text=[IO.File]::ReadAllText((Join-Path $PackageRoot $Relative)).TrimStart([char]0xFEFF).Replace("`r`n","`n");$sha=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','')}finally{$sha.Dispose()}}
$codePaths=@('installer/ZhaoHuoInstaller.psm1','tests/Test-Build26021712Validation.ps1')
$report=[pscustomobject]@{Passed=$true;ActualGameRun=$false;Scope='Known fingerprint group and fallback routing in isolated copied-file fixtures; no install/uninstall and no game process execution.';PowerShellVersion=$PSVersionTable.PSVersion.ToString();GameBuildId='26021712';TestCount=$results.Count;Tests=$results.ToArray();CodeHashAlgorithm='SHA256-UTF8-noBOM-LF-v1';CodeHashes=@(foreach($relative in $codePaths){[pscustomobject]@{Path=$relative;Sha256=(CodeHash $relative)}})}
$report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $ReportPath -Encoding UTF8
Write-Host ('All '+$results.Count+' build routing checks passed.')
