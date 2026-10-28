#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$BasePackagePath,
    [string]$OutputDirectory,
    [switch]$CheckOnly
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$script:UMRoot=$PSScriptRoot
$script:UMManifestHash='__UPDATE_MANIFEST_SHA256__'

function Get-UMHash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
function Get-UMFullPath([string]$Path){
    if([string]::IsNullOrWhiteSpace($Path)){throw '路径为空。'}
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    if($full-notmatch '^[A-Za-z]:\\' -or $full.Substring(2).Contains(':')){throw '请选择本机磁盘上的完整文件夹路径。'}
    return $full
}
function Assert-UMNoReparse([string]$Path){
    $current=[IO.Path]::GetFullPath($Path)
    while($current){
        if(Test-Path -LiteralPath $current){
            $item=Get-Item -LiteralPath $current -Force
            if(($item.Attributes-band [IO.FileAttributes]::ReparsePoint)-ne 0){throw ('不支持符号链接或目录联接：'+$current)}
        }
        $parent=[IO.Path]::GetDirectoryName($current.TrimEnd('\','/'))
        if(-not $parent-or $parent-eq $current){break};$current=$parent
    }
}
function Assert-UMOutsideGame([string]$Path){
    $current=$Path
    while($current){
        if((Test-Path -LiteralPath (Join-Path $current 'Mortal.exe')) -or (Test-Path -LiteralPath (Join-Path $current 'Mortal_Data') -PathType Container)){
            throw '请先把管理器完整解压到游戏目录外。小更新工具不能在游戏目录内生成或修补文件。'
        }
        $parent=[IO.Path]::GetDirectoryName($current.TrimEnd('\','/'))
        if(-not $parent-or $parent-eq $current){break};$current=$parent
    }
}
function Test-UMOverlap([string]$A,[string]$B){
    return $A.Equals($B,[StringComparison]::OrdinalIgnoreCase)-or $A.StartsWith($B+'\',[StringComparison]::OrdinalIgnoreCase)-or $B.StartsWith($A+'\',[StringComparison]::OrdinalIgnoreCase)
}
function Assert-UMRelative([string]$Relative){
    if([string]::IsNullOrWhiteSpace($Relative)-or [IO.Path]::IsPathRooted($Relative)-or $Relative.Contains('\')-or $Relative.Contains(':')){throw ('更新包含不安全路径：'+$Relative)}
    foreach($part in @($Relative-split '/')){
        if([string]::IsNullOrWhiteSpace($part)-or $part-in @('.','..')-or $part-match '[<>:"|?*\x00-\x1f]'-or $part-match '[. ]$'-or $part-match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'){throw ('更新包含不安全文件名：'+$Relative)}
    }
}
function Get-UMChild([string]$Root,[string]$Relative){
    Assert-UMRelative $Relative
    $path=[IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if(-not $path.StartsWith($Root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw '文件路径超出指定目录。'}
    Assert-UMNoReparse $path
    return $path
}
function Read-UMJson([string]$Path){
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw ('找不到所需文件：'+$Path)}
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json
}
function Read-UMPinnedText([string]$Path,[string]$Expected){
    Assert-UMNoReparse $Path
    $bytes=[IO.File]::ReadAllBytes($Path);$sha=[Security.Cryptography.SHA256]::Create()
    try{$actual=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','')}finally{$sha.Dispose()}
    if($actual-ne $Expected){throw '小更新包清单校验失败，请重新下载并完整解压。'}
    return (New-Object Text.UTF8Encoding($false,$true)).GetString($bytes).TrimStart([char]0xFEFF)
}
function Assert-UMEntry([object]$Entry){
    Assert-UMRelative ([string]$Entry.Path)
    if($Entry.SHA256-isnot [string]-or $Entry.SHA256-notmatch '^[0-9A-Fa-f]{64}$'-or $Entry.Bytes-is [bool]-or $Entry.Bytes-is [string]-or $Entry.Bytes-lt 0-or [decimal]$Entry.Bytes-ne [long]$Entry.Bytes){throw ('更新清单格式无效：'+$Entry.Path)}
}
function Assert-UMFile([string]$Path,[object]$Entry){
    Assert-UMNoReparse $Path
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw ('文件缺失，请重新完整解压对应安装包：'+$Entry.Path)}
    if((Get-Item -LiteralPath $Path).Length-ne $Entry.Bytes-or (Get-UMHash $Path)-ne $Entry.SHA256){throw ('文件与正式版不一致，不能安全复用，请改用完整包：'+$Entry.Path)}
}
function Read-UMPackage{
    Write-Progress -Id 1 -Activity '小更新：校验更新包' -Status '检查固定清单与增量文件' -PercentComplete 0
    $root=Get-UMFullPath $script:UMRoot;Assert-UMNoReparse $root;Assert-UMOutsideGame $root
    if($script:UMManifestHash-notmatch '^[0-9A-Fa-f]{64}$'){throw '这是未打包的更新器源码，请下载正式小更新包后完整解压。'}
    $path=Get-UMChild $root 'UpdateManifest.json'
    $manifest=(Read-UMPinnedText $path $script:UMManifestHash)|ConvertFrom-Json
    if($manifest.SchemaVersion-ne 1-or $manifest.TargetVersion-ne '2.2.4'-or $manifest.TargetFolderName-ne 'ZhaoHuoPortraitManager-v2.2.4-win-x64'-or (@($manifest.SupportedBaseVersions)-join ',')-cne '2.2.1,2.2.2,2.2.3'-or $manifest.TargetManifestSHA256-notmatch '^[0-9A-Fa-f]{64}$'-or $manifest.TargetSumsSHA256-notmatch '^[0-9A-Fa-f]{64}$'){throw '小更新包版本或协议不受支持。'}
    $files=@($manifest.Files);$byPath=@{}
    foreach($entry in $files){
        Assert-UMEntry $entry
        if($byPath.ContainsKey($entry.Path)-or $entry.Source-cnotin @('Reuse','Payload')){throw ('重复文件或未知来源：'+$entry.Path)}
        $byPath[$entry.Path]=$entry
    }
    foreach($name in @('ReleaseManifest.json','SHA256SUMS.txt','VariantCatalog.json','Install.cmd','installer/Gui.ps1')){if(-not $byPath.ContainsKey($name)){throw ('更新清单缺少必要文件：'+$name)}}
    foreach($name in @('ReleaseManifest.json','SHA256SUMS.txt')){if($byPath[$name].Source-cne 'Payload'){throw '目标校验清单必须随小更新包提供。'}}
    if($byPath['ReleaseManifest.json'].SHA256-ne $manifest.TargetManifestSHA256-or $byPath['SHA256SUMS.txt'].SHA256-ne $manifest.TargetSumsSHA256){throw '目标清单的固定校验值不一致。'}
    foreach($entry in $files){if($entry.Source-ceq 'Payload'){Assert-UMFile (Get-UMChild $root ('Payload/'+$entry.Path)) $entry}}
    $target=(Read-UMPinnedText (Get-UMChild $root 'Payload/ReleaseManifest.json') $manifest.TargetManifestSHA256)|ConvertFrom-Json
    if($target.Version-ne $manifest.TargetVersion-or @($target.Files).Count-ne $files.Count-2){throw '目标完整包文件清单不一致。'}
    $targetSeen=@{}
    foreach($entry in @($target.Files)){
        Assert-UMEntry $entry
        if($entry.Path-in @('ReleaseManifest.json','SHA256SUMS.txt')-or $targetSeen.ContainsKey($entry.Path)-or-not $byPath.ContainsKey($entry.Path)-or $byPath[$entry.Path].Path-cne $entry.Path-or $byPath[$entry.Path].SHA256-ne $entry.SHA256-or $byPath[$entry.Path].Bytes-ne $entry.Bytes){throw ('目标文件与正式清单不一致：'+$entry.Path)}
        $targetSeen[$entry.Path]=$true
    }
    $sumSeen=@{};$sumPath=Get-UMChild $root 'Payload/SHA256SUMS.txt'
    $sumText=Read-UMPinnedText $sumPath $manifest.TargetSumsSHA256
    foreach($line in @($sumText-split '\r?\n')){
        if($line-eq ''){continue}
        if($line-notmatch '^([0-9A-Fa-f]{64})  (.+)$'){throw 'SHA256SUMS.txt 格式不正确。'}
        $hash=$Matches[1];$name=$Matches[2];Assert-UMRelative $name
        if($name-eq 'SHA256SUMS.txt'-or $sumSeen.ContainsKey($name)-or-not $byPath.ContainsKey($name)-or $byPath[$name].Path-cne $name-or $byPath[$name].SHA256-ne $hash){throw ('SHA256SUMS.txt 内容不一致：'+$name)}
        $sumSeen[$name]=$true
    }
    if($sumSeen.Count-ne $files.Count-1){throw 'SHA256SUMS.txt 未覆盖全部目标文件。'}
    return [pscustomobject]@{Root=$root;Manifest=$manifest;Files=$files;ByPath=$byPath}
}
function Get-UMPlan([string]$Base,[string]$Output){
    $package=Read-UMPackage
    $baseRoot=Get-UMFullPath $Base;Assert-UMNoReparse $baseRoot;Assert-UMOutsideGame $baseRoot
    if(-not(Test-Path -LiteralPath $baseRoot -PathType Container)){throw '请选择旧管理器解压目录，不是 ZIP 文件。'}
    if(Test-UMOverlap $baseRoot $package.Root){throw '旧管理器与小更新包必须放在互不包含的独立文件夹。'}
    $catalog=Read-UMJson (Get-UMChild $baseRoot 'VariantCatalog.json')
    $release=Read-UMJson (Get-UMChild $baseRoot 'ReleaseManifest.json')
    if($catalog.PackageVersion-ne $release.Version){throw '旧管理器版本记录不一致，请选择完整的正式安装包目录。'}
    if($catalog.PackageVersion-eq $package.Manifest.TargetVersion){return [pscustomobject]@{AlreadyCurrent=$true;Base=$baseRoot;Package=$package}}
    if($catalog.PackageVersion-cnotin @($package.Manifest.SupportedBaseVersions)){throw '本小更新包仅支持 v2.2.1、v2.2.2、v2.2.3。v2.2.0 及更早版本请下载完整安装包。'}
    if(-not $Output){$Output=Join-Path ([IO.Path]::GetDirectoryName($baseRoot)) $package.Manifest.TargetFolderName}
    $destination=Get-UMFullPath $Output;Assert-UMNoReparse $destination;Assert-UMOutsideGame $destination
    if([IO.Path]::GetFileName($destination)-cne $package.Manifest.TargetFolderName){throw ('目标文件夹名称必须为 '+$package.Manifest.TargetFolderName)}
    if((Test-UMOverlap $destination $baseRoot)-or(Test-UMOverlap $destination $package.Root)){throw '新旧管理器及小更新包目录不能重叠或互相包含。'}
    if(Test-Path -LiteralPath $destination){throw ('目标目录已存在，本工具不会覆盖它：'+$destination)}
    $parent=[IO.Path]::GetDirectoryName($destination)
    if(-not(Test-Path -LiteralPath $parent -PathType Container)){throw '目标的父文件夹不存在，请先创建或选择已有位置。'}
    $total=[long]0;$reuse=0;$checked=0
    foreach($entry in $package.Files){
        $total+=[long]$entry.Bytes
        if($entry.Source-ceq 'Reuse'){Assert-UMFile (Get-UMChild $baseRoot $entry.Path) $entry;$reuse++}
        $checked++;if($checked%20-eq 0-or $checked-eq $package.Files.Count){Write-Progress -Id 1 -Activity '小更新：核对旧素材' -Status ($checked.ToString()+'/'+$package.Files.Count) -PercentComplete ([int](100*$checked/$package.Files.Count))}
    }
    $drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($destination))
    if($drive.AvailableFreeSpace-lt ($total+16MB)){throw ('剩余磁盘空间不足，需要约 '+[Math]::Ceiling(($total+16MB)/1MB)+' MB 空闲空间。')}
    return [pscustomobject]@{AlreadyCurrent=$false;Base=$baseRoot;BaseVersion=$catalog.PackageVersion;Destination=$destination;Parent=$parent;Package=$package;RequiredBytes=$total;ReusedFiles=$reuse}
}
function Copy-UMFile([string]$Source,[string]$Destination,[object]$Entry){
    Assert-UMFile $Source $Entry
    Assert-UMNoReparse $Destination
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Destination))|Out-Null
    [IO.File]::Copy($Source,$Destination,$false)
    Assert-UMFile $Destination $Entry
}
function Get-UMTreeFiles([string]$Root){
    Assert-UMNoReparse $Root
    $queue=New-Object 'System.Collections.Generic.Queue[string]';$queue.Enqueue($Root)
    while($queue.Count){
        $directory=$queue.Dequeue();Assert-UMNoReparse $directory
        foreach($item in @(Get-ChildItem -LiteralPath $directory -Force)){
            if(($item.Attributes-band [IO.FileAttributes]::ReparsePoint)-ne 0){throw '生成目录含符号链接或目录联接。'}
            if($item.PSIsContainer){$queue.Enqueue($item.FullName)}else{$item.FullName}
        }
    }
}
function Remove-UMStage([string]$Stage,[string]$Parent,[string]$Token){
    if([IO.Path]::GetDirectoryName($Stage)-cne $Parent-or [IO.Path]::GetFileName($Stage)-cne ('.zhaohuo-update-'+$Token)-or $Token-notmatch '^[0-9a-f]{32}$'){throw '临时目录边界验证失败，不执行清理。'}
    Assert-UMNoReparse $Stage
    if(-not(Test-Path -LiteralPath $Stage)){return}
    $directories=New-Object 'System.Collections.Generic.List[string]';$queue=New-Object 'System.Collections.Generic.Queue[string]';$queue.Enqueue($Stage)
    $files=New-Object 'System.Collections.Generic.List[string]'
    while($queue.Count){
        $dir=$queue.Dequeue();$directories.Add($dir)
        foreach($item in @(Get-ChildItem -LiteralPath $dir -Force)){
            if(($item.Attributes-band [IO.FileAttributes]::ReparsePoint)-ne 0){throw '临时目录出现链接，已停止自动清理。'}
            if($item.PSIsContainer){$queue.Enqueue($item.FullName)}else{$files.Add($item.FullName)}
        }
    }
    foreach($file in $files){
        # A copied source may be read-only. Change only this newly created copy.
        $attributes=[IO.File]::GetAttributes($file)
        if(($attributes-band [IO.FileAttributes]::ReadOnly)-ne 0){[IO.File]::SetAttributes($file,($attributes-band (-bnot [IO.FileAttributes]::ReadOnly)))}
        [IO.File]::Delete($file)
    }
    for($i=$directories.Count-1;$i-ge 0;$i--){[IO.Directory]::Delete($directories[$i],$false)}
}
function Invoke-UMUpdate([string]$Base,[string]$Output,[switch]$InspectOnly){
    try{$plan=Get-UMPlan $Base $Output}finally{Write-Progress -Id 1 -Activity '小更新：核对旧素材' -Completed}
    if($plan.AlreadyCurrent){return [pscustomobject]@{Status='AlreadyCurrent';Message='选择的目录已标记为 v2.2.4，无需本小更新包；若文件不完整，请重新下载完整包。';OutputDirectory=$plan.Base}}
    if($InspectOnly){return [pscustomobject]@{Status='Checked';BaseVersion=$plan.BaseVersion;TargetVersion=$plan.Package.Manifest.TargetVersion;Files=$plan.Package.Files.Count;ReusedFiles=$plan.ReusedFiles;RequiredBytes=$plan.RequiredBytes;OutputDirectory=$plan.Destination;FilesWritten=0}}
    $token=[Guid]::NewGuid().ToString('N');$stage=Join-Path $plan.Parent ('.zhaohuo-update-'+$token);$created=$false
    try{
        Assert-UMNoReparse $plan.Parent;Assert-UMOutsideGame $plan.Parent
        if(Test-Path -LiteralPath $stage){throw '临时目录已存在，请重试。'}
        [IO.Directory]::CreateDirectory($stage)|Out-Null;$created=$true
        $index=0
        foreach($entry in $plan.Package.Files){
            $source=if($entry.Source-ceq 'Reuse'){Get-UMChild $plan.Base $entry.Path}else{Get-UMChild $plan.Package.Root ('Payload/'+$entry.Path)}
            Copy-UMFile $source (Get-UMChild $stage $entry.Path) $entry
            $index++;Write-Progress -Activity '正在生成新版管理器，旧目录保持不变' -Status ($index.ToString()+'/'+$plan.Package.Files.Count) -PercentComplete ([int](100*$index/$plan.Package.Files.Count))
        }
        foreach($entry in $plan.Package.Files){Assert-UMFile (Get-UMChild $stage $entry.Path) $entry}
        if(@(Get-UMTreeFiles $stage).Count-ne $plan.Package.Files.Count){throw '临时目录出现清单外文件，停止生成。'}
        $newCatalog=Read-UMJson (Get-UMChild $stage 'VariantCatalog.json')
        if($newCatalog.PackageVersion-ne $plan.Package.Manifest.TargetVersion){throw '生成目录的版本与目标不一致。'}
        Assert-UMNoReparse $plan.Parent;Assert-UMNoReparse $plan.Destination;Assert-UMOutsideGame $plan.Destination
        [IO.Directory]::Move($stage,$plan.Destination);$created=$false
        return [pscustomobject]@{Status='Created';BaseVersion=$plan.BaseVersion;TargetVersion=$plan.Package.Manifest.TargetVersion;Files=$plan.Package.Files.Count;ReusedFiles=$plan.ReusedFiles;Bytes=$plan.RequiredBytes;OutputDirectory=$plan.Destination;OriginalDirectoryUnmodified=$true}
    }catch{
        $originalError=$_
        if($created){try{Remove-UMStage $stage $plan.Parent $token}catch{throw ($originalError.Exception.Message+"`n临时文件未能清理，请保留此错误信息："+$_.Exception.Message)}}
        throw $originalError
    }finally{Write-Progress -Activity '正在生成新版管理器，旧目录保持不变' -Completed}
}

# Dot-sourcing exposes functions for isolated tests; it never opens UI or updates.
if($MyInvocation.InvocationName-eq '.'){return}
$interactive=[string]::IsNullOrWhiteSpace($BasePackagePath)
try{
    if($interactive){
        Add-Type -AssemblyName System.Windows.Forms
        $dialog=New-Object Windows.Forms.FolderBrowserDialog
        $dialog.Description='选择 v2.2.1 / v2.2.2 / v2.2.3 的管理器解压目录（里面有 Install.cmd 和 VariantCatalog.json）'
        $dialog.ShowNewFolderButton=$false
        try{if($dialog.ShowDialog()-ne [Windows.Forms.DialogResult]::OK){exit 0};$BasePackagePath=$dialog.SelectedPath}finally{$dialog.Dispose()}
    }
    $result=Invoke-UMUpdate $BasePackagePath $OutputDirectory -InspectOnly:$CheckOnly
    $result|ConvertTo-Json -Depth 4
    if($interactive){
        $message=if($result.Status-eq 'AlreadyCurrent'){$result.Message}elseif($result.Status-eq 'Checked'){'检查通过，未写入文件。'}else{"新版管理器已生成，旧目录未改动。`n`n"+$result.OutputDirectory+"`n`n请先保存并退出游戏，再运行新目录中的 打开美化管理器.cmd。"}
        [Windows.Forms.MessageBox]::Show($message,'管理器小更新',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Information)|Out-Null
    }
}catch{
    if($interactive){[Windows.Forms.MessageBox]::Show($_.Exception.Message,'小更新未完成',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error)|Out-Null}
    [Console]::Error.WriteLine($_.Exception.Message);exit 1
}
