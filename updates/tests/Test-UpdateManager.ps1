#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputPath,[Parameter(Mandatory=$true)][string]$WorkRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
$ProgressPreference='SilentlyContinue'
$source=Join-Path (Split-Path -Parent $PSScriptRoot) 'Update-Manager.ps1'
$template=[IO.File]::ReadAllText($source)
$root=Join-Path ([IO.Path]::GetFullPath($WorkRoot)) ('updater-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
$checks=New-Object 'System.Collections.Generic.List[string]';$started=[DateTime]::UtcNow
function Put([string]$Path,[string]$Text){[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))|Out-Null;[IO.File]::WriteAllText($Path,$Text,(New-Object Text.UTF8Encoding($false)))}
function Save([string]$Path,[object]$Data){Put $Path ($Data|ConvertTo-Json -Depth 12)}
function FixtureHash([string]$Path){(Get-FileHash -LiteralPath $Path).Hash}
function Check([bool]$Condition,[string]$Name){if(-not $Condition){throw ('FAIL '+$Name)};$checks.Add($Name);Write-Host ('PASS '+$Name)}
function Reject([scriptblock]$Body,[string]$Pattern,[string]$Name){$failed=$false;try{& $Body|Out-Null}catch{if($_.Exception.Message-notlike $Pattern){throw};$failed=$true};Check $failed $Name}
function Snapshot([string]$Path){$result=@{};foreach($f in @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force)){$result[$f.FullName.Substring($Path.Length+1)]=FixtureHash $f.FullName};return $result}
function Same([hashtable]$Before,[hashtable]$After){if($Before.Count-ne $After.Count){return $false};foreach($k in $Before.Keys){if(-not $After.ContainsKey($k)-or $Before[$k]-ne $After[$k]){return $false}};return $true}
function Pin([object]$Case){
    Save (Join-Path $Case.Patch 'UpdateManifest.json') $Case.Manifest
    $code=$template.Replace('__UPDATE_MANIFEST_SHA256__',(FixtureHash (Join-Path $Case.Patch 'UpdateManifest.json')))
    [IO.File]::WriteAllText($Case.Runner,$code,(New-Object Text.UTF8Encoding($true)))
}
function New-Case([string]$Name,[string]$Version='2.2.3'){
    $dir=Join-Path $root $Name;$base=Join-Path $dir '旧 管理器';$patch=Join-Path $dir '小 更新';$parent=Join-Path $dir '输出'
    foreach($p in @($base,$patch,$parent)){[IO.Directory]::CreateDirectory($p)|Out-Null}
    $target=[ordered]@{
        'VariantCatalog.json'='{"PackageVersion":"2.2.4"}'
        'Install.cmd'='@echo SCRIPT EXECUTED>"%~dp0executed.txt"'
        'installer/Gui.ps1'='Set-Content -LiteralPath (Join-Path $PSScriptRoot executed.txt) -Value executed; throw "Old script must never execute"'
        'Portraits/normal.png'='INERT PORTRAIT TEST BYTES'
        'Loader/winhttp.dll'='INERT DLL TEST BYTES'
        'README.md'='NEW DOCUMENTATION'
    }
    $entries=@();$all=@()
    foreach($name in $target.Keys){
        $old=if($name-eq 'VariantCatalog.json'){'{"PackageVersion":"'+$Version+'"}'}elseif($name-eq 'README.md'){'OLD DOCUMENTATION'}else{$target[$name]}
        Put (Join-Path $base $name) $old
        $type=if($name-in @('VariantCatalog.json','README.md')){'Payload'}else{'Reuse'}
        $p=if($type-eq 'Payload'){Join-Path $patch ('Payload/'+$name)}else{Join-Path $base $name}
        if($type-eq 'Payload'){Put $p $target[$name]}
        $entry=[pscustomobject]@{Path=$name;SHA256=(FixtureHash $p);Bytes=(Get-Item -LiteralPath $p).Length}
        $entries+=$entry;$all+=[pscustomobject]@{Path=$name;SHA256=$entry.SHA256;Bytes=$entry.Bytes;Source=$type}
    }
    Save (Join-Path $base ReleaseManifest.json) @{Version=$Version}
    Put (Join-Path $base '用户便签.txt') 'PRESERVE THIS EXTRA FILE'
    Put (Join-Path $base 'Install.ps1') 'throw "Unexpected script execution"'
    $release=Join-Path $patch Payload/ReleaseManifest.json;Save $release @{Version='2.2.4';Files=$entries}
    $all+=[pscustomobject]@{Path='ReleaseManifest.json';SHA256=(FixtureHash $release);Bytes=(Get-Item -LiteralPath $release).Length;Source='Payload'}
    $sums=Join-Path $patch Payload/SHA256SUMS.txt;Put $sums ((@($all|ForEach-Object{$_.SHA256+'  '+$_.Path})-join "`n")+"`n")
    $all+=[pscustomobject]@{Path='SHA256SUMS.txt';SHA256=(FixtureHash $sums);Bytes=(Get-Item -LiteralPath $sums).Length;Source='Payload'}
    $manifest=[pscustomobject]@{SchemaVersion=1;TargetVersion='2.2.4';TargetFolderName='ZhaoHuoPortraitManager-v2.2.4-win-x64';TargetManifestSHA256=(FixtureHash $release);TargetSumsSHA256=(FixtureHash $sums);SupportedBaseVersions=@('2.2.1','2.2.2','2.2.3');Files=$all}
    $case=[pscustomobject]@{Dir=$dir;Base=$base;Patch=$patch;Parent=$parent;Output=(Join-Path $parent $manifest.TargetFolderName);Runner=(Join-Path $patch 'Update-Manager.ps1');Manifest=$manifest}
    Pin $case;return $case
}
foreach($version in @('2.2.1','2.2.2','2.2.3')){
    $c=New-Case ('happy-'+$version) $version;. $c.Runner
    $before=Snapshot $c.Base;$patchBefore=Snapshot $c.Patch
    $checked=Invoke-UMUpdate $c.Base $c.Output -InspectOnly
    Check ($checked.Status-eq 'Checked'-and $checked.FilesWritten-eq 0-and-not(Test-Path -LiteralPath $c.Output)-and(Same $before (Snapshot $c.Base))) ('Read-only check preserves source '+$version)
    $result=Invoke-UMUpdate $c.Base $c.Output
    $same=$result.Status-eq 'Created';foreach($e in $c.Manifest.Files){$p=Join-Path $c.Output $e.Path;$same=$same-and(Test-Path -LiteralPath $p -PathType Leaf)-and(FixtureHash $p)-eq $e.SHA256-and(Get-Item -LiteralPath $p).Length-eq $e.Bytes}
    Check ($same-and @(Get-ChildItem -LiteralPath $c.Output -Recurse -File).Count-eq $c.Manifest.Files.Count) ('Exact reconstructed target inventory and bytes '+$version)
    Check ((Same $before (Snapshot $c.Base))-and(Same $patchBefore (Snapshot $c.Patch))-and-not(Test-Path -LiteralPath (Join-Path $c.Output '用户便签.txt'))-and-not(Test-Path -LiteralPath (Join-Path $c.Base executed.txt))-and-not(Test-Path -LiteralPath (Join-Path $c.Output installer/executed.txt))) ('Original directory, extra notes and scripts remain untouched '+$version)
    $done=Snapshot $c.Output
    Reject {Invoke-UMUpdate $c.Base $c.Output} '*目标目录已存在*' ('Repeated destination is never overwritten '+$version)
    Check (Same $done (Snapshot $c.Output)) ('Repeated attempt preserves existing target '+$version)
}
$c=New-Case 'unsupported' '2.2.0';. $c.Runner
Reject {Invoke-UMUpdate $c.Base $c.Output} '*仅支持*' 'Unsupported v2.2.0 gets complete-package guidance'
$c=New-Case 'already' '2.2.4';. $c.Runner
Check ((Invoke-UMUpdate $c.Base $c.Output).Status-eq 'AlreadyCurrent'-and-not(Test-Path -LiteralPath $c.Output)) 'Already-current package creates no new directory'
$c=New-Case 'version-disagreement';Put (Join-Path $c.Base ReleaseManifest.json) '{"Version":"2.2.1"}';. $c.Runner
Reject {Invoke-UMUpdate $c.Base $c.Output} '*版本记录不一致*' 'Disagreeing old JSON versions are rejected'
$c=New-Case 'missing-reuse';Remove-Item -LiteralPath (Join-Path $c.Base Portraits/normal.png);. $c.Runner
Reject {Invoke-UMUpdate $c.Base $c.Output} '*文件缺失*' 'Missing reused portrait is rejected before creating target'
$c=New-Case 'modified-dll';Put (Join-Path $c.Base Loader/winhttp.dll) 'MODIFIED';. $c.Runner
Reject {Invoke-UMUpdate $c.Base $c.Output} '*文件与正式版不一致*' 'Changed reused binary is rejected without execution'
$c=New-Case 'manifest-tamper';[IO.File]::AppendAllText((Join-Path $c.Patch UpdateManifest.json),' ');. $c.Runner
Reject {Invoke-UMUpdate $c.Base $c.Output} '*清单校验失败*' 'Pinned update manifest tampering is rejected'
$c=New-Case 'payload-tamper';Put (Join-Path $c.Patch Payload/README.md) 'TAMPER';. $c.Runner
Reject {Invoke-UMUpdate $c.Base $c.Output} '*文件与正式版不一致*' 'Changed payload is rejected'
foreach($bad in @('../escape.txt','C:/escape.txt','notes.txt:stream','CON.txt','bad./name','two\\parts')){
    $c=New-Case ('unsafe-'+[Guid]::NewGuid().ToString('N'));$c.Manifest.Files[0].Path=$bad;Pin $c;. $c.Runner
    Reject {Invoke-UMUpdate $c.Base $c.Output} '*不安全*' ('Unsafe manifest path rejected: '+$bad)
}
$c=New-Case 'duplicate';$c.Manifest.Files+= $c.Manifest.Files[0];Pin $c;. $c.Runner
Reject {Invoke-UMUpdate $c.Base $c.Output} '*重复文件*' 'Duplicate manifest entries are rejected'
$c=New-Case 'target-binding';$c.Manifest.TargetManifestSHA256=('0'*64);Pin $c;. $c.Runner
Reject {Invoke-UMUpdate $c.Base $c.Output} '*固定校验值不一致*' 'Target manifest fixed hash cannot disagree with inventory'
$c=New-Case 'overlap';. $c.Runner
Reject {Invoke-UMUpdate $c.Base (Join-Path $c.Base $c.Manifest.TargetFolderName)} '*不能重叠*' 'Destination inside old source is rejected'
Reject {Invoke-UMUpdate $c.Base (Join-Path $c.Patch $c.Manifest.TargetFolderName)} '*不能重叠*' 'Destination inside small package is rejected'
$c=New-Case 'game-source';Put (Join-Path $c.Dir Mortal.exe) 'INERT GAME MARKER';. $c.Runner
Reject {Invoke-UMUpdate $c.Base $c.Output} '*游戏目录*' 'Game ancestor prevents writes'
$c=New-Case 'reparse-source';$outside=Join-Path $c.Dir Outside;[IO.Directory]::CreateDirectory($outside)|Out-Null;Put (Join-Path $outside normal.png) 'INERT PORTRAIT TEST BYTES'
$portraits=Join-Path $c.Base Portraits;Remove-Item -LiteralPath (Join-Path $portraits normal.png);[IO.Directory]::Delete($portraits)
$null=New-Item -ItemType Junction -Path $portraits -Target $outside;. $c.Runner
Reject {Invoke-UMUpdate $c.Base $c.Output} '*目录联接*' 'Reused file through a junction is rejected'
Check ((Get-Content -LiteralPath (Join-Path $outside normal.png) -Raw)-eq 'INERT PORTRAIT TEST BYTES') 'Junction rejection does not touch its target'
[IO.Directory]::Delete($portraits)
$c=New-Case 'reparse-output';$real=Join-Path $c.Dir RealOutput;[IO.Directory]::CreateDirectory($real)|Out-Null;$link=Join-Path $c.Dir LinkOutput;$null=New-Item -ItemType Junction -Path $link -Target $real;. $c.Runner
Reject {Invoke-UMUpdate $c.Base (Join-Path $link $c.Manifest.TargetFolderName)} '*目录联接*' 'Output ancestor junction is rejected'
[IO.Directory]::Delete($link)
$c=New-Case 'failure';. $c.Runner
$readOnlySource=Join-Path $c.Base Install.cmd;[IO.File]::SetAttributes($readOnlySource,[IO.FileAttributes]::ReadOnly)
$before=Snapshot $c.Base;$keep=Join-Path $c.Parent '.zhaohuo-update-unrelated';Put (Join-Path $keep note.txt) 'KEEP'
$script:RealCopy=${function:Copy-UMFile};$script:Copies=0
function Copy-UMFile([string]$Source,[string]$Destination,[object]$Entry){& $script:RealCopy $Source $Destination $Entry;$script:Copies++;if($script:Copies-eq 2){throw 'INJECTED_COPY_FAILURE'}}
Reject {Invoke-UMUpdate $c.Base $c.Output} '*INJECTED_COPY_FAILURE*' 'Mid-copy failure is injected after verified writes'
Check ((Same $before (Snapshot $c.Base))-and-not(Test-Path -LiteralPath $c.Output)-and @(Get-ChildItem -LiteralPath $c.Parent -Directory).Count-eq 1-and(Get-Content -LiteralPath (Join-Path $keep note.txt) -Raw)-eq 'KEEP') 'Failure removes only its own new staging directory'
Check (([IO.File]::GetAttributes($readOnlySource)-band [IO.FileAttributes]::ReadOnly)-ne 0) 'Failure cleanup preserves read-only attributes of the original source'
$c=New-Case 'publish-race';. $c.Runner
$script:RealCopy=${function:Copy-UMFile};$script:Copies=0;$script:RaceTarget=$c.Output;$script:ExpectedCopies=$c.Manifest.Files.Count
function Copy-UMFile([string]$Source,[string]$Destination,[object]$Entry){& $script:RealCopy $Source $Destination $Entry;$script:Copies++;if($script:Copies-eq $script:ExpectedCopies){Put (Join-Path $script:RaceTarget keep.txt) 'OTHER PROCESS'}}
Reject {Invoke-UMUpdate $c.Base $c.Output} '*' 'Concurrent target creation is refused at atomic publish'
Check ((Get-Content -LiteralPath (Join-Path $c.Output keep.txt) -Raw)-eq 'OTHER PROCESS'-and @(Get-ChildItem -LiteralPath $c.Parent -Directory).Count-eq 1) 'Publish race preserves competing target and cleans only staging'
$c=New-Case 'cli';
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $c.Runner -BasePackagePath $c.Base -OutputDirectory $c.Output -CheckOnly *> (Join-Path $c.Dir cli-check.txt)
Check ($LASTEXITCODE-eq 0-and-not(Test-Path -LiteralPath $c.Output)) 'Windows PowerShell CLI CheckOnly returns success without writing target'
Put (Join-Path $c.Base Loader/winhttp.dll) 'INVALID'
try{$ErrorActionPreference='Continue';& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $c.Runner -BasePackagePath $c.Base -OutputDirectory $c.Output *> (Join-Path $c.Dir cli-fail.txt);$cliExit=$LASTEXITCODE}finally{$ErrorActionPreference='Stop'}
Check ($cliExit-ne 0-and-not(Test-Path -LiteralPath $c.Output)) 'Windows PowerShell CLI failure returns a nonzero exit code'
function CodeHash([string]$Path){$text=[IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF).Replace("`r`n","`n").Replace("`r","`n");$sha=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','')}finally{$sha.Dispose()}}
$repo=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$report=[ordered]@{Passed=$true;ActualGameRun=$false;RealGameFilesModified=$false;PowerShell=$PSVersionTable.PSVersion.ToString();AssertionCount=$checks.Count;Checks=$checks.ToArray();DurationSeconds=[Math]::Round(([DateTime]::UtcNow-$started).TotalSeconds,2);CodeHashAlgorithm='SHA256-UTF8-noBOM-LF-v1';CodeHashes=@(@('updates/Update-Manager.ps1','updates/双击更新管理器.cmd','updates/tests/Test-UpdateManager.ps1')|ForEach-Object{[pscustomobject]@{Path=$_;Sha256=(CodeHash (Join-Path $repo $_))}});Scope='Isolated inert package fixtures under Windows PowerShell 5.1. No official game, real user installation, GUI interaction or network access. Source and target manifests are synthetic, with pinned hashes derived separately for each fixture. Actual published package reconstruction is a separate acceptance.'}
Save ([IO.Path]::GetFullPath($OutputPath)) $report
Write-Host ('ALL '+$checks.Count+' SMALL UPDATE ASSERTIONS PASSED')
