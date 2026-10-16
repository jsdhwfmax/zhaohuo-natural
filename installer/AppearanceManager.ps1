#requires -Version 5.1
# Read-only catalog and status helpers. Game assemblies are never executed.
function Get-ZHMutexName([string]$GamePath) {
    $canonical = (Get-ZHCanonical $GamePath).ToLowerInvariant()
    Assert-ZHNoLink $canonical
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)))).Replace('-','') }
    finally { $sha.Dispose() }
    return ('Local\ZhaoHuoAppearance-' + $hash)
}
function Enter-ZHOperation([string]$GamePath) {
    $mutex = New-Object Threading.Mutex($false, (Get-ZHMutexName $GamePath))
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw '另一个安装器正在处理此游戏目录，请等待它完成后再试。' }
        return $mutex
    } catch { $mutex.Dispose(); throw }
}
function Install-ZhaoHuo {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$GamePath,[Parameter(Mandatory=$true)][string]$PackageRoot,[switch]$CheckOnly,[scriptblock]$Log,[string]$VariantId,[string]$CharacterId='player')
    if (Test-ZHMultiPackage $PackageRoot) {
        if ([string]::IsNullOrWhiteSpace($VariantId)) { $VariantId='natural' }
        return (Set-PortraitAppearance -GamePath $GamePath -PackageRoot $PackageRoot -CheckOnly:$CheckOnly -Log $Log -CharacterId $CharacterId -VariantId $VariantId)
    }
    if ($CharacterId -ne 'player') { throw '旧版包不支持其他角色，请使用多角色管理器。' }
    $arguments=@{}; foreach($key in $PSBoundParameters.Keys){if($key-ne 'CharacterId'){$arguments[$key]=$PSBoundParameters[$key]}}
    $mutex = Enter-ZHOperation $GamePath
    try { Invoke-ZHInstallCore @arguments }
    finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
}
function Uninstall-ZhaoHuo {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$GamePath,[switch]$CheckOnly,[scriptblock]$Log)
    $mutex = Enter-ZHOperation $GamePath
    try { Invoke-ZHUninstallCore @PSBoundParameters }
    finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
}
$script:KnownVariantFingerprints = @{
    natural='1179319D7CEE4F7D19A7FF00D8A23E1D7474A8871F601343666DF4E6624E5E66'
    handsome='E38B63E6DECA2C3837AA659D19CA8AA48FBD4D748FFEB257D6DFEE6016832A8E'
    xianxia='12BC83F70EF4C99BBD49A13ABBA4A1867998B6DD794873EFAE47B065870A9802'
}
function Read-ZHVariantCatalog([string]$PackageRoot) {
    $path = Get-ZHChild $PackageRoot 'VariantCatalog.json'
    Assert-ZHNoLink $path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $catalog = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($catalog.SchemaVersion -ne 1 -or $catalog.PackageVersion -ne '1.3.0' -or $catalog.DefaultVariantId -ne 'natural' -or
        $catalog.FingerprintAlgorithm -ne 'SHA256-normalized-path-hash-lines-ordinal-v1' -or @($catalog.Variants).Count -ne 3) { throw '外观目录文件无效，请重新完整解压管理器。' }
    $ids = @{}; $hashes = @{}
    foreach ($variant in @($catalog.Variants)) {
        if ($variant.Id -notin @('natural','handsome','xianxia') -or $ids.ContainsKey($variant.Id) -or
            [string]::IsNullOrWhiteSpace($variant.DisplayName) -or [string]::IsNullOrWhiteSpace($variant.Description) -or
            $variant.PayloadFingerprint -notmatch '^[0-9A-Fa-f]{64}$' -or $hashes.ContainsKey($variant.PayloadFingerprint)) { throw '外观目录中的名称或指纹无效、重复。' }
        if ($variant.PayloadFingerprint -ne $script:KnownVariantFingerprints[$variant.Id]) { throw '外观目录的指纹不是此管理器认可的发布版本，请重新完整解压。' }
        $expected = if ($variant.Id -eq 'natural') { 'BepInEx/plugins/ZhaoHuoNatural/Portraits' } else { 'Variants/' + $variant.Id + '/Portraits' }
        if ($variant.PortraitPath -cne $expected -or $variant.PreviewPath -cne ($expected + '/normal.png')) { throw '外观目录中的图片路径无效。' }
        Assert-ZHNoLink (Get-ZHChild $PackageRoot $variant.PortraitPath)
        Assert-ZHNoLink (Get-ZHChild $PackageRoot $variant.PreviewPath)
        $ids[$variant.Id] = $true; $hashes[$variant.PayloadFingerprint] = $true
    }
    return $catalog
}
function Get-ZhaoHuoVariants {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$PackageRoot)
    $catalog = Read-ZHVariantCatalog (Get-ZHCanonical $PackageRoot)
    if ($null -eq $catalog) { throw '此目录不是包含三种形象的外观管理器，请完整解压 v1.3.0 安装包。' }
    return @($catalog.Variants)
}
function Get-ZHVariantPayload([string]$PackageRoot,[object]$Variant) {
    $shared = Get-ZHChild $PackageRoot $script:PluginRelative
    $portraitRelative = if ($Variant.PSObject.Properties['PortraitPath']) { $Variant.PortraitPath } else { $script:PluginRelative + '\Portraits' }
    $portraits = Get-ZHChild $PackageRoot $portraitRelative
    foreach ($name in @('ZhaoHuoNatural.dll','portrait-map.txt','portrait-layout.tsv')) {
        $source = Get-ZHChild $shared $name
        Assert-ZHNoLink $source
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "美化包未完整解压，缺少 $name。" }
    }
    if (-not (Test-Path -LiteralPath $portraits -PathType Container)) { throw '美化包必须包含完整的 47 张立绘，请重新完整解压发布包。' }
    $files = @(Get-ZHFiles $portraits)
    if ($files.Count -ne $script:PortraitNames.Count) { throw '美化包必须包含完整的 47 张立绘，请重新完整解压发布包。' }
    $actions = @()
    foreach ($name in @('ZhaoHuoNatural.dll','portrait-map.txt','portrait-layout.tsv')) {
        $source = Get-ZHChild $shared $name
        $actions += [pscustomobject]@{ RelativePath=($script:PluginRelative + '\' + $name); Source=$source; Sha256=(Get-ZHHash $source); Category='Plugin' }
    }
    foreach ($name in $script:PortraitNames) {
        $source = Get-ZHChild $portraits ($name + '.png')
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "美化包缺少必要立绘：$name.png。请重新完整解压发布包。" }
        $actions += [pscustomobject]@{ RelativePath=($script:PluginRelative + '\Portraits\' + $name + '.png'); Source=$source; Sha256=(Get-ZHHash $source); Category='Plugin' }
    }
    # The shared plugin root must remain exactly three common files plus natural
    # portraits. Do not silently adopt unexpected payloads or duplicate DLLs.
    $allowed = @{}
    foreach ($name in @('ZhaoHuoNatural.dll','portrait-map.txt','portrait-layout.tsv')) { $allowed[$name]=$true }
    foreach ($name in $script:PortraitNames) { $allowed['Portraits\' + $name + '.png']=$true }
    foreach ($file in @(Get-ZHFiles $shared)) {
        if (-not $allowed.ContainsKey($file.FullName.Substring($shared.Length + 1))) { throw '美化包共享目录包含额外文件，请重新完整解压发布包。' }
    }
    return $actions
}
function Assert-ZHPluginInventory([object]$Paths,[object[]]$Records) {
    $owned = @{}
    foreach ($record in $Records) { $owned[$record.RelativePath]=$true }
    foreach ($file in @(Get-ZHFiles $Paths.Plugin)) {
        $relative = $file.FullName.Substring($Paths.Game.Length + 1)
        if (-not $owned.ContainsKey($relative) -and -not $relative.StartsWith($script:PluginRelative + '\Diagnostics\',[StringComparison]::OrdinalIgnoreCase)) { throw "立绘目录中有未登记文件，不能自动切换；该文件已保留：$relative" }
    }
}
function Get-ZHKnownVariant([object]$Manifest,[object[]]$Records,[object[]]$Variants) {
    if ($Records.Count -ne 50) { throw '受管立绘不是完整的 50 个载荷文件，无法识别外观。' }
    $fingerprint = Get-ZHPayloadFingerprint $Records
    $matched = @($Variants | Where-Object { $_.PayloadFingerprint -eq $fingerprint })
    if ($matched.Count -ne 1) { throw '当前受管立绘的完整文件指纹未知，不能自动切换。请保留文件和记录。' }
    if (($Manifest.PSObject.Properties['VariantId'] -and $Manifest.VariantId -ne $matched[0].Id) -or
        ($Manifest.PSObject.Properties['PayloadFingerprint'] -and $Manifest.PayloadFingerprint -ne $fingerprint)) { throw '安装记录的外观名称或指纹与实际文件不一致，请保留文件和记录。' }
    return $matched[0]
}
function Get-ZhaoHuoInstalledVariant {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$GamePath,[Parameter(Mandatory=$true)][string]$PackageRoot)
    $variants = @(Get-ZhaoHuoVariants -PackageRoot $PackageRoot)
    $result = [pscustomobject]@{ Status='NotInstalled'; VariantId=$null; DisplayName=$null; PayloadFingerprint=$null; Message='尚未安装本美化包。'; CanSwitch=$false; HasManifest=$false }
    try {
        $paths = Get-ZHLocations $GamePath
        Assert-ZHNoLink $paths.Game; Assert-ZHNoLink $paths.State; Assert-ZHNoLink $paths.Manifest; Assert-ZHNoLink $paths.Plugin
        if (-not (Test-Path -LiteralPath (Get-ZHChild $paths.Game 'Mortal.exe') -PathType Leaf)) { throw '请选择包含 Mortal.exe 的游戏目录。' }
        $result.HasManifest = Test-Path -LiteralPath $paths.Manifest -PathType Leaf
        if (Test-Path -LiteralPath (Get-ZHSwitchPath $paths)) { $result.Status='RecoveryRequired'; $result.Message='存在未完成的切换。应用或卸载时将先恢复切换前外观。'; return $result }
        $manifest = Read-ZHState $paths
        if ($null -eq $manifest) {
            if (Test-Path -LiteralPath $paths.Plugin) { $result.Status='Unmanaged'; $result.Message='发现没有安装记录的立绘目录。仅完整自然版可按既有规则备份接管，其他内容请先归档。' }
            return $result
        }
        if ($manifest.SchemaVersion -ne 3) { $result.Status='Legacy'; $result.Message='检测到旧版安装记录，请先使用原安装包卸载并恢复。'; return $result }
        if ($manifest.Status -ne 'installed') { $result.Status='RecoveryRequired'; $result.Message='安装或卸载尚未完成，请先使用卸载并恢复完成回滚。'; return $result }
        $result.Status='Modified'
        $records = @(Get-ZHOwnedRecords $manifest); $seen=@{}
        $backupRoot = Get-ZHChild $paths.State $manifest.BackupRelativePath
        foreach ($record in $records) {
            Assert-ZHRecord $record $paths $backupRoot
            if ($seen.ContainsKey($record.RelativePath)) { throw '安装记录中有重复文件。' }; $seen[$record.RelativePath]=$true
            $file = Get-ZHChild $paths.Game $record.RelativePath
            if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or (Get-ZHHash $file) -ne $record.InstalledSha256) { throw '已安装文件被修改或缺失，无法确认当前外观；请先卸载并保留修改文件。' }
        }
        $pluginRecords = @($records | Where-Object { $_.Category -eq 'Plugin' })
        Assert-ZHPluginInventory $paths $pluginRecords
        $known = Get-ZHKnownVariant $manifest $pluginRecords $variants
        $result.Status='Installed'; $result.VariantId=$known.Id; $result.DisplayName=$known.DisplayName; $result.PayloadFingerprint=$known.PayloadFingerprint
        $result.CanSwitch = -not (($manifest.PSObject.Properties['AdoptedUntrackedPayload'] -and $manifest.AdoptedUntrackedPayload) -or @($pluginRecords | Where-Object { $_.WasPresent }).Count -ne 0)
        $result.Message = if ($result.CanSwitch) { '已验证当前安装：' + $known.DisplayName + '。' } else { '已验证当前安装，但它来自手工文件接管；请先卸载并归档原文件后再切换。' }
    } catch {
        if ($result.Status -ne 'Modified') { $result.Status='Invalid' }
        $result.VariantId=$null; $result.DisplayName=$null; $result.PayloadFingerprint=$null; $result.CanSwitch=$false; $result.Message=$_.Exception.Message
    }
    return $result
}
