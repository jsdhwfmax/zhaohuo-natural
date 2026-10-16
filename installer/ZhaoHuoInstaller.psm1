#requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:GameAssemblyNames = @('Assembly-CSharp.dll', 'Mortal.Core.dll', 'Mortal.Story.dll', 'Fungus.dll')
# Accept only complete, verified fingerprint groups. A hash from one build must
# never be combined with a hash from another build to create an untested set.
$script:SupportedGameBuilds = @(
    [pscustomobject]@{
        BuildId = '25953419'
        Hashes = [ordered]@{
            'Assembly-CSharp.dll' = '5803AF11CFA7428CF1E8E6B9F0447CAC607C1310119F7DB1CE013DB651D8BF23'
            'Mortal.Core.dll' = 'A377455BBD41E33B680E1647DD6199B27079AC07D9E6999716204F7805584D84'
            'Mortal.Story.dll' = '69340F2B4908A96DE26ED947B870752D674D2CF7193DA17431F4F94A6F41F66A'
            'Fungus.dll' = '16DCD300966F3CB747E693B3BD7996AD6C36303B9112B81F9696D2B4C8BC0114'
        }
    },
    [pscustomobject]@{
        BuildId = '25957922'
        Hashes = [ordered]@{
            'Assembly-CSharp.dll' = '5803AF11CFA7428CF1E8E6B9F0447CAC607C1310119F7DB1CE013DB651D8BF23'
            'Mortal.Core.dll' = 'E2FE344EA90DED6E11F06711DE86F27290E005D817B21755149F9EE24966FC9F'
            'Mortal.Story.dll' = '69340F2B4908A96DE26ED947B870752D674D2CF7193DA17431F4F94A6F41F66A'
            'Fungus.dll' = '16DCD300966F3CB747E693B3BD7996AD6C36303B9112B81F9696D2B4C8BC0114'
        }
    }
)
$script:LoaderHash = 'D3B62F4C9C3E2196EF82603C52D6B98C043A0D6C125C081FD33D7CA3798B41B8'
$script:DependencyManifestHash = 'D4C53D568F7254ACC9754405E1EAD03BB9AEE484F3962274AFF3C497A96BA7DC'
$script:KnownLoaderHashes = @($script:LoaderHash, '80A5988815FCCF70FBA37B9BAA4FC5E39D869969F7FF9EC77A9EFBDCFED10183')
$script:PluginRelative = 'BepInEx\plugins\ZhaoHuoNatural'
$script:StateRelative = 'BepInEx\ZhaoHuoNatural-install'
$script:LegacyRelative = 'BepInEx\plugins\Tianfei\MortalBeauty.dll'
$script:PortraitNames = @(
    'angry1','angry2','angry3','blood_laugh1','blood_nervous1','blood_no_weapon_laugh1','blood_no_weapon','blood','caught',
    'close_eye_laugh','close_eye_nervous','close_eye_nervous2','close_eye_powder','close_eye','determined','die','doubt',
    'eye_mask_nervous1','eye_mask_nervous2','fist_north_star','gloomy2','god_thunder','head','hero_landing','hurt_fist','hurt','hurt2',
    'laugh1','laugh2','mask','mud','nervous1','nervous2','nervous3','normal','oraora','revel','sad1','shake','shake2','shock',
    'soul','special1','stupid','suck1','suck3','suck4'
)

function Write-ZHLog([scriptblock]$Log, [string]$Message, [string]$Level = 'Info') {
    if ($Log) { & $Log $Message $Level | Out-Null } else { Write-Host $Message }
}
function Get-ZHCanonical([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw '请先选择包含 Mortal.exe 的游戏目录。' }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.Length -gt [IO.Path]::GetPathRoot($full).Length) { $full = $full.TrimEnd('\', '/') }
    return $full
}
function Get-ZHChild([string]$Root, [string]$Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative) -or $Relative.Contains(':') -or
        @($Relative -split '[\\/]' | Where-Object { $_ -eq '..' -or $_ -eq '.' -or $_ -eq '' }).Count -gt 0) {
        throw "拒绝不安全的相对路径：$Relative"
    }
    $base = (Get-ZHCanonical $Root).TrimEnd('\', '/') + '\'
    $result = [IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if (-not $result.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw "路径越出允许的目录：$Relative" }
    return $result
}
function Assert-ZHNoLink([string]$Path) {
    $current = Get-ZHCanonical $Path
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "为避免修改错误位置，暂不支持符号链接或目录联接：$current"
            }
        }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) { break }
        $current = $parent.FullName
    }
}
function Get-ZHFiles([string]$Root) {
    Assert-ZHNoLink $Root
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Root)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "目录中包含符号链接或联接：$($item.FullName)" }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) } else { $item }
        }
    }
}
function Get-ZHHash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Get-ZHMachine([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) { throw "不是有效的 PE 程序文件：$Path" }
        $stream.Position = 0x3C
        $offset = $reader.ReadInt32()
        if ($offset -lt 0 -or $offset -gt ($stream.Length - 6)) { throw "PE 文件头无效：$Path" }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw "PE 签名无效：$Path" }
        return $reader.ReadUInt16()
    } finally { $reader.Dispose(); $stream.Dispose() }
}
function Assert-ZHStopped([string]$GamePath) {
    $exe = Get-ZHChild $GamePath 'Mortal.exe'
    foreach ($process in @(Get-Process -Name Mortal -ErrorAction SilentlyContinue)) {
        try { $processPath = $process.Path } catch { $processPath = $null }
        if ([string]::IsNullOrWhiteSpace($processPath) -or $processPath -eq $exe) {
            throw '游戏仍在运行。请正常保存并完全退出活侠传后重试。'
        }
    }
}
function Save-ZHJson([object]$Value, [string]$Path) {
    Assert-ZHNoLink $Path
    $temporary = $Path + '.tmp'
    Assert-ZHNoLink $temporary
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 14), (New-Object Text.UTF8Encoding($true)))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}
function Copy-ZHVerified([string]$Source, [string]$Destination, [string]$Sha256) {
    Assert-ZHNoLink $Source
    Assert-ZHNoLink $Destination
    if ((Get-ZHHash $Source) -ne $Sha256) { throw "复制前校验失败，源文件可能被改变：$Source" }
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Destination)) -Force | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    if ((Get-ZHHash $Destination) -ne $Sha256) { throw "复制后校验失败：$Destination" }
}
function Get-ZHLocations([string]$GamePath) {
    $game = Get-ZHCanonical $GamePath
    $state = Get-ZHChild $game $script:StateRelative
    [pscustomobject]@{
        Game = $game; Plugin = (Get-ZHChild $game $script:PluginRelative); State = $state
        Manifest = (Get-ZHChild $state 'ActiveManifest.json')
        Legacy = (Get-ZHChild $game $script:LegacyRelative)
        Disabled = (Get-ZHChild $game ($script:LegacyRelative + '.disabled-by-zhaohuo-natural'))
    }
}
function Invoke-ZHCompatibilityProbe([string]$GamePath, [string]$PackageRoot) {
    $probePath = Join-Path $PSScriptRoot 'CompatibilityProbe.ps1'
    Assert-ZHNoLink $probePath
    if (-not (Test-Path -LiteralPath $probePath -PathType Leaf)) { throw '离线兼容检测文件缺失，请重新完整解压发布包。' }
    . $probePath
    Test-ZhaoHuoCompatibility -GamePath $GamePath -PackageRoot $PackageRoot
}
function Get-ZHGameValidation([string]$GamePath, [string]$PackageRoot) {
    $paths = Get-ZHLocations $GamePath
    foreach ($path in @($paths.Game, $paths.Plugin, $paths.State, $paths.Manifest, $paths.Legacy, $paths.Disabled)) { Assert-ZHNoLink $path }
    Assert-ZHStopped $paths.Game
    foreach ($name in @('Mortal.exe', 'UnityPlayer.dll')) {
        $binary = Get-ZHChild $paths.Game $name
        Assert-ZHNoLink $binary
        if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { throw "所选目录不是完整游戏目录，缺少：$name" }
        if ((Get-ZHMachine $binary) -ne 0x8664) { throw "当前美化包只适用于 64 位游戏，架构不匹配：$name" }
    }
    $hashes = [ordered]@{}
    foreach ($name in $script:GameAssemblyNames) {
        $file = Get-ZHChild $paths.Game ('Mortal_Data\Managed\' + $name)
        Assert-ZHNoLink $file
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "游戏程序集缺失：$name" }
        $hashes[$name] = Get-ZHHash $file
    }
    $build = $null
    $acf = $null
    $acfHash = $null
    $parent = [IO.Directory]::GetParent($paths.Game)
    if ($parent -and $parent.Parent) {
        $acf = Join-Path $parent.Parent.FullName 'appmanifest_1859910.acf'
        if (Test-Path -LiteralPath $acf -PathType Leaf) {
            $acfHash = Get-ZHHash $acf
            if ((Get-Content -LiteralPath $acf -Raw) -match '"buildid"\s+"([0-9]+)"') { $build = $Matches[1] }
        }
    }
    $matchedBuild = $null
    foreach ($candidate in $script:SupportedGameBuilds) {
        $matchesAll = $true
        foreach ($name in $script:GameAssemblyNames) {
            if ($hashes[$name] -ne $candidate.Hashes[$name]) { $matchesAll = $false; break }
        }
        # A new Steam build may change only resources while keeping these four
        # DLLs. It still needs the resource/interface probe, as does missing
        # Steam metadata; only a matching build and fingerprint use this path.
        if ($matchesAll -and $build -eq $candidate.BuildId) { $matchedBuild = $candidate; break }
    }
    $mode = 'VerifiedFingerprint'
    $matchedBuildId = $null
    $probe = $null
    if ($null -ne $matchedBuild) { $matchedBuildId = $matchedBuild.BuildId }
    else {
        $probeReasons = @()
        $compatible = $false
        try {
            $probe = Invoke-ZHCompatibilityProbe -GamePath $paths.Game -PackageRoot $PackageRoot
            if ($probe.Compatible -isnot [bool] -or $probe.Method -ne 'OfflineCompatibilityProbe') { throw '离线兼容检测未返回有效结果。' }
            $compatible = $probe.Compatible
            $probeReasons = @($probe.Reasons)
            if ($compatible) {
                if (@($probe.Checks).Count -eq 0 -or @($probe.BaselineBuildIds).Count -eq 0) { throw '离线兼容检测缺少检查依据。' }
                foreach ($check in @($probe.Checks)) {
                    if ($null -eq $check -or $check.Passed -isnot [bool] -or -not $check.Passed) { throw '离线兼容检测含有未通过的检查。' }
                }
                foreach ($baseline in @($probe.BaselineBuildIds)) {
                    if ([string]::IsNullOrWhiteSpace([string]$baseline)) { throw '离线兼容检测缺少基准版本。' }
                }
                $currentAcfHash = $null
                if ($acf -and (Test-Path -LiteralPath $acf -PathType Leaf)) { $currentAcfHash = Get-ZHHash $acf }
                if ($currentAcfHash -ne $acfHash) { throw '检测期间 Steam 安装清单发生变化，请等待游戏更新完成后重试。' }
                foreach ($name in $script:GameAssemblyNames) {
                    $probeHash = if ($probe.FingerprintSet -is [Collections.IDictionary]) { $probe.FingerprintSet[$name] } else { $probe.FingerprintSet.PSObject.Properties[$name].Value }
                    $currentHash = Get-ZHHash (Get-ZHChild $paths.Game ('Mortal_Data\Managed\' + $name))
                    if ($probeHash -ne $hashes[$name] -or $currentHash -ne $hashes[$name]) { throw "检测期间游戏文件发生变化，请等待 Steam 更新完成后重试：$name" }
                }
            }
        } catch { $compatible = $false; $probeReasons = @($_.Exception.Message) }
        if (-not $compatible) {
            $detected = if ($build) { $build } else { '未知（未找到 Steam 清单）' }
            $supported = ($script:SupportedGameBuilds | ForEach-Object { $_.BuildId }) -join '、'
            $details = @($script:GameAssemblyNames | ForEach-Object { $_ + ' SHA-256: ' + $hashes[$_] }) -join [Environment]::NewLine
            $reasonText = $probeReasons -join '；'
            if ([string]::IsNullOrWhiteSpace($reasonText)) { $reasonText = '未取得足够的离线兼容证据。' }
            throw ("游戏版本不受支持：未匹配实机验证指纹，且离线兼容检测未通过，未改动游戏文件。`r`n" +
                "检测到 Steam build：$detected；已实机验证 build：$supported。`r`n" +
                "检测原因：$reasonText`r`n" +
                "请从 https://github.com/jsdhwfmax/zhaohuo-natural/releases 查看适配情况；反馈时请附上检测原因和以下四行信息，不要跳过检查。`r`n" + $details)
        }
        $mode = 'OfflineCompatibilityProbe'
    }
    # The observed build is never treated as proof by itself. A fast-path result
    # requires its full fingerprint; all other cases require the offline probe.
    [pscustomobject]@{ Paths = $paths; Hashes = $hashes; BuildId = $build; DetectedBuild = $build; MatchedBuildId = $matchedBuildId; CompatibilityMode = $mode; Probe = $probe }
}
function Read-ZHDependencies([string]$PackageRoot) {
    $root = Get-ZHChild $PackageRoot 'Dependencies\BepInEx'
    $file = Get-ZHChild $root 'runtime-manifest.json'
    Assert-ZHNoLink $file
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw '离线 BepInEx 依赖清单缺失，请重新完整解压发布包。' }
    if ((Get-ZHHash $file) -ne $script:DependencyManifestHash) { throw '离线依赖清单与已验证的官方 be.692 文件集合不一致，请重新完整解压发布包。' }
    $data = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
    $entries = @()
    $seen = @{}
    foreach ($entry in @($data.Files)) {
        $relative = ([string]$entry.RelativePath).Replace('/', '\')
        if ($relative -notmatch '^BepInEx\\core\\[^\\:]+\.(dll|xml)$' -and $relative -ne 'doorstop_config.ini') {
            throw "离线依赖清单包含不允许的目标：$relative"
        }
        $source = Get-ZHChild (Get-ZHChild $root 'files') $relative
        Assert-ZHNoLink $source
        if ($seen.ContainsKey($relative) -or $entry.Sha256 -notmatch '^[0-9A-Fa-f]{64}$' -or
            -not (Test-Path -LiteralPath $source -PathType Leaf) -or (Get-ZHHash $source) -ne $entry.Sha256) {
            throw "离线依赖校验失败：$relative，请重新完整解压发布包。"
        }
        $seen[$relative] = $true
        $entries += [pscustomobject]@{ RelativePath = $relative; Source = $source; Sha256 = $entry.Sha256 }
    }
    foreach ($required in @('BepInEx\core\BepInEx.Core.dll', 'BepInEx\core\BepInEx.Unity.Mono.dll', 'BepInEx\core\BepInEx.Unity.Mono.Preloader.dll', 'BepInEx\core\BepInEx.Preloader.Core.dll', 'BepInEx\core\0Harmony.dll', 'doorstop_config.ini')) {
        if (-not $seen.ContainsKey($required)) { throw "离线运行库不完整：$required" }
    }
    return $entries
}
function Assert-ZHConfig([string]$Path) {
    $sections = @{}
    $section = ''
    foreach ($raw in [IO.File]::ReadAllLines($Path)) {
        $line = $raw.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith('#') -or $line.StartsWith(';')) { continue }
        if ($line -match '^\[([^\]]+)\]$') { $section = $Matches[1]; continue }
        if ($line -notmatch '^([^=]+)=(.*)$') { throw "无法识别现有 Doorstop 配置，请保留原文件并先处理冲突：$Path" }
        $key = $section + '.' + $Matches[1].Trim()
        if ($sections.ContainsKey($key)) { throw "Doorstop 配置中存在重复设置：$key" }
        $sections[$key] = $Matches[2].Trim().Trim('"').Replace('/', '\')
    }
    if ($sections['General.enabled'] -ne 'true' -or
        $sections['General.target_assembly'] -ne 'BepInEx\core\BepInEx.Unity.Mono.Preloader.dll' -or
        ($sections.ContainsKey('General.boot_config_override') -and $sections['General.boot_config_override'] -ne '') -or
        ($sections.ContainsKey('UnityMono.dll_search_path_override') -and $sections['UnityMono.dll_search_path_override'] -notin @('', 'BepInEx\core'))) {
        throw '现有 Doorstop 配置未指向受支持的 BepInEx 6 Mono 加载器，或包含自定义引导路径。为保护现有模组，安装已停止，配置未被覆盖。'
    }
}
function Get-ZHEnvironment([string]$GamePath, [object[]]$Dependencies) {
    $core = Get-ZHChild $GamePath 'BepInEx\core'
    $config = Get-ZHChild $GamePath 'doorstop_config.ini'
    $loader = Get-ZHChild $GamePath 'winhttp.dll'
    foreach ($path in @($core, $config, $loader)) { Assert-ZHNoLink $path }
    if ((Test-Path -LiteralPath $loader) -and -not (Test-Path -LiteralPath $loader -PathType Leaf)) { throw 'winhttp.dll 被同名目录占用。' }
    if (Test-Path -LiteralPath $loader -PathType Leaf) {
        if ((Get-ZHHash $loader) -notin $script:KnownLoaderHashes) { throw '检测到未知 winhttp.dll 引导器。它可能属于其他模组或图形工具，安装器不会覆盖它。请先自行确认并处理冲突。' }
    }
    if (Test-Path -LiteralPath $config) {
        if (-not (Test-Path -LiteralPath $config -PathType Leaf)) { throw 'doorstop_config.ini 被同名目录占用。' }
        Assert-ZHConfig $config
    }
    if (Test-Path -LiteralPath (Get-ZHChild $core 'BepInEx.dll')) { throw '检测到 BepInEx 5 或混合运行库。本包需要 BepInEx 6 Mono，不会覆盖旧运行库，请先备份并移除冲突版本。' }
    $main = Get-ZHChild $core 'BepInEx.Core.dll'
    if (Test-Path -LiteralPath $main -PathType Leaf) {
        try { $major = [Reflection.AssemblyName]::GetAssemblyName($main).Version.Major } catch { throw '无法识别现有 BepInEx.Core.dll；运行库可能损坏，安装已停止。' }
        if ($major -ne 6) { throw '现有 BepInEx 不是受支持的第 6 版，安装已停止。' }
        foreach ($entry in $Dependencies) {
            if ($entry.RelativePath -like 'BepInEx\core\*.dll') {
                $required = Get-ZHChild $GamePath $entry.RelativePath
                Assert-ZHNoLink $required
                if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "现有 BepInEx 6 运行库不完整，安装器不会混入另一版核心文件。缺少：$($entry.RelativePath)" }
                if ((Get-ZHHash $required) -ne $entry.Sha256) { throw "现有 BepInEx 6 与已验证的 6.0.0-be.692 不匹配：$($entry.RelativePath)。核心文件未被覆盖，请先备份并处理版本冲突。" }
            }
        }
        foreach ($name in @('BepInEx.Unity.Mono.dll', 'BepInEx.Unity.Mono.Preloader.dll', 'BepInEx.Preloader.Core.dll')) {
            try { $major = [Reflection.AssemblyName]::GetAssemblyName((Get-ZHChild $core $name)).Version.Major } catch { throw "无法识别现有 BepInEx 6 组件：$name" }
            if ($major -ne 6) { throw "检测到混合版本 BepInEx 组件：$name" }
        }
        return 'ExistingBepInEx6'
    }
    if ((Test-Path -LiteralPath $core) -or (Test-Path -LiteralPath $config) -or (Test-Path -LiteralPath $loader)) {
        throw '检测到不完整或未知的模组引导环境（已有 core/config/loader，但没有完整 BepInEx 6）。为防止盲目覆盖，安装已停止。'
    }
    return 'CleanGame'
}
function Read-ZHState([object]$Paths) {
    if (-not (Test-Path -LiteralPath $Paths.Manifest -PathType Leaf)) { return $null }
    $manifest = Get-Content -LiteralPath $Paths.Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.SchemaVersion -notin @(1, 2, 3) -or $manifest.PackageId -ne 'ZhaoHuoNatural' -or
        $manifest.GamePath -ne $Paths.Game -or $manifest.InstallationId -notmatch '^\d{8}-\d{6}-[0-9a-f]{8}$' -or
        $manifest.Status -notin @('installed', 'installing', 'uninstalling', 'switching') -or
        $manifest.BackupRelativePath -ne ('Backups\' + $manifest.InstallationId)) {
        throw '安装记录无效、被移动或属于其他目录。请保留备份，勿手工删除记录后重装。'
    }
    return $manifest
}
function Get-ZHOwnedRecords([object]$Manifest) {
    if ($Manifest.SchemaVersion -eq 3) { return @($Manifest.OwnedFiles) }
    $records = @()
    foreach ($file in @($Manifest.Files)) {
        $records += [pscustomobject]@{ RelativePath = ($script:PluginRelative + '\' + $file.RelativePath); InstalledSha256 = $file.Sha256; WasPresent = $false; OriginalSha256 = $null; BackupRelativePath = $null; Stage = 'applied'; Category = 'Plugin' }
    }
    if ($Manifest.SchemaVersion -eq 2) {
        $records += [pscustomobject]@{ RelativePath = 'winhttp.dll'; InstalledSha256 = $Manifest.Loader.InstalledSha256; WasPresent = $true; OriginalSha256 = $Manifest.Loader.OriginalSha256; BackupRelativePath = 'winhttp.dll'; Stage = 'applied'; Category = 'Loader' }
    }
    return $records
}
function Assert-ZHRecord([object]$Record, [object]$Paths, [string]$BackupRoot) {
    $relative = ([string]$Record.RelativePath).Replace('/', '\')
    if ($relative -notmatch '^BepInEx\\plugins\\ZhaoHuoNatural\\.+' -and $relative -notmatch '^BepInEx\\core\\[^\\:]+\.(dll|xml)$' -and $relative -notin @('winhttp.dll', 'doorstop_config.ini')) {
        throw "安装记录含有不属于本包的目标：$relative"
    }
    $destination = Get-ZHChild $Paths.Game $relative
    Assert-ZHNoLink $destination
    if ($Record.InstalledSha256 -notmatch '^[0-9A-Fa-f]{64}$' -or $Record.Stage -notin @('pending', 'applying', 'applied')) { throw '安装记录的哈希或事务状态无效。' }
    if (Test-Path -LiteralPath $destination -PathType Container) { throw "记录中的文件被同名目录替换：$destination" }
    if ($Record.WasPresent) {
        $backup = Get-ZHChild $BackupRoot $Record.BackupRelativePath
        Assert-ZHNoLink $backup
        if ($Record.OriginalSha256 -notmatch '^[0-9A-Fa-f]{64}$' -or -not (Test-Path -LiteralPath $backup -PathType Leaf) -or (Get-ZHHash $backup) -ne $Record.OriginalSha256) {
            throw "原文件备份缺失或校验失败，未进行卸载：$relative"
        }
    }
}
function Get-ZhaoHuoInstallPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$GamePath, [Parameter(Mandatory=$true)][string]$PackageRoot, [string]$VariantId)
    $package = Get-ZHCanonical $PackageRoot
    $variant = Read-ZHVariant $package $VariantId
    $validation = Get-ZHGameValidation -GamePath $GamePath -PackageRoot $package
    $paths = $validation.Paths
    if (Test-Path -LiteralPath (Get-ZHSwitchPath $paths)) { throw '存在未完成的外观切换，请使用当前外观包的安装或卸载入口恢复，勿使用旧版安装器。' }
    if ($package -eq $paths.Game -or $package.StartsWith($paths.Game.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw '请将原安装包 ZIP 重新完整解压到游戏目录之外的独立文件夹（例如桌面），再运行 Install.cmd。不要直接解压到游戏目录。若此前误解压，安装器会检查并备份与发布包完全一致的本插件文件；不会删除其他模组。'
    }
    $actions = @(Get-ZHVariantPayload $package $variant)
    $payloadFileCount = $actions.Count
    $loaderSource = Get-ZHChild $package 'Loader\winhttp.dll'
    $payloadFingerprint = Get-ZHPayloadFingerprint @($actions)
    if ($variant.PayloadFingerprint -and $variant.PayloadFingerprint -ne $payloadFingerprint) { throw '外观包文件与外观目录校验值不一致，请重新完整解压安装包。' }
    Assert-ZHNoLink $loaderSource
    if (-not (Test-Path -LiteralPath $loaderSource -PathType Leaf) -or (Get-ZHHash $loaderSource) -ne $script:LoaderHash -or (Get-ZHMachine $loaderSource) -ne 0x8664) { throw '包内官方 x64 Doorstop 4.3.0 加载器缺失或校验失败。' }
    $actions += [pscustomobject]@{ RelativePath = 'winhttp.dll'; Source = $loaderSource; Sha256 = $script:LoaderHash; Category = 'Loader' }
    $dependencies = @(Read-ZHDependencies $package)
    $existing = Read-ZHState $paths
    if ($existing) {
        if ($existing.Status -ne 'installed') { throw '存在未完成的安装或卸载记录，请先使用“卸载并恢复”完成回滚。' }
        $null = Get-ZHEnvironment $paths.Game $dependencies
        if (-not (Test-Path -LiteralPath (Get-ZHChild $paths.Game 'doorstop_config.ini') -PathType Leaf)) { throw '已安装环境缺少 doorstop_config.ini，请先卸载再重新安装。' }
        $backupRoot = Get-ZHChild $paths.State $existing.BackupRelativePath
        $owned = @(Get-ZHOwnedRecords $existing)
        $seen = @{}
        foreach ($record in $owned) {
            Assert-ZHRecord $record $paths $backupRoot
            if ($seen.ContainsKey($record.RelativePath)) { throw '安装记录中有重复文件。' }
            $seen[$record.RelativePath] = $true
            $destination = Get-ZHChild $paths.Game $record.RelativePath
            if (-not (Test-Path -LiteralPath $destination -PathType Leaf) -or (Get-ZHHash $destination) -ne $record.InstalledSha256) { throw "已安装文件被改变或缺失：$($record.RelativePath)。请先卸载再安装，卸载会保留修改过的文件。" }
        }
        $pluginRecords = @($owned | Where-Object { $_.Category -eq 'Plugin' })
        if ($pluginRecords.Count -ne @($actions | Where-Object { $_.Category -eq 'Plugin' }).Count) { throw '包内版本与已安装版本不同，请先卸载再安装。' }
        if ($variant.PSObject.Properties['ManagerCatalog']) {
            $null = Get-ZHKnownVariant $existing $pluginRecords (@($variant) + @($variant.SwitchFrom))
            Assert-ZHPluginInventory $paths $pluginRecords
        }
        $different = @()
        foreach ($action in $actions) {
            if (@($owned | Where-Object { $_.RelativePath -eq $action.RelativePath -and $_.InstalledSha256 -eq $action.Sha256 }).Count -ne 1) { $different += $action }
        }
        if ($existing.Legacy.DisabledByThisInstall -and ((Test-Path -LiteralPath $paths.Legacy) -or -not (Test-Path -LiteralPath $paths.Disabled -PathType Leaf) -or (Get-ZHHash $paths.Disabled) -ne $existing.Legacy.Sha256)) { throw '旧 MortalBeauty 插件的状态发生改变，请先卸载再重新安装。' }
        if ($different.Count -gt 0) {
            $sourceVariant=Assert-ZHSwitchSource -PlanVariant $variant -Manifest $existing -Records $pluginRecords -Actions @($actions | Where-Object Category -eq 'Plugin') -Paths $paths
            if (@($different | Where-Object { $_.Category -ne 'Plugin' -or $_.RelativePath -notmatch '\\Portraits\\[^\\]+\.png$' }).Count -gt 0) { throw '切换涉及加载器或非立绘文件，请先卸载再安装。' }
            return [pscustomobject]@{ AlreadyInstalled=$false; SwitchRequired=$true; Paths=$paths; Environment='VariantSwitch'; Validation=$validation; Actions=$different; Manifest=$existing; ManifestSha256=(Get-ZHHash $paths.Manifest); Variant=$variant; PayloadFingerprint=$payloadFingerprint; SourceVariant=$sourceVariant }
        }
        return [pscustomobject]@{ AlreadyInstalled = $true; SwitchRequired=$false; Paths = $paths; Environment = 'AlreadyInstalled'; Validation = $validation; Actions = @(); Manifest = $existing; Variant=$variant; PayloadFingerprint=$payloadFingerprint }
    }
    $adoptUntracked = $false
    if (Test-Path -LiteralPath $paths.Plugin) {
        if ($variant.Id -ne 'natural') { throw '游戏中存在未登记的立绘目录。本外观包不会接管手工误解压文件；请先保留并归档该目录到 BepInEx\plugins 之外，再从游戏外安装。' }
        # A release ZIP extracted into the game creates the portrait directory
        # without an install record. Adopt only an exact copy of this payload,
        # backing every pre-existing file up through the ordinary transaction.
        $identical = Test-Path -LiteralPath $paths.Plugin -PathType Container
        $untrackedFiles = @()
        if ($identical) { $untrackedFiles = @(Get-ZHFiles $paths.Plugin) }
        if ($payloadFileCount -ne ($script:PortraitNames.Count + 3) -or $untrackedFiles.Count -ne $payloadFileCount) { $identical = $false }
        $expectedFiles = @{}
        foreach ($action in $actions | Where-Object { $_.Category -eq 'Plugin' }) { $expectedFiles[$action.RelativePath] = $action.Sha256 }
        foreach ($file in $untrackedFiles) {
            $relative = $file.FullName.Substring($paths.Game.Length + 1)
            if (-not $expectedFiles.ContainsKey($relative) -or (Get-ZHHash $file.FullName) -ne $expectedFiles[$relative]) { $identical = $false; break }
        }
        if (-not $identical) { throw '美化包专用目录已存在，但没有有效安装记录，且文件与本发布包不完全一致。可能有额外、缺少或修改的文件。为保护已有内容，请先备份并重命名 BepInEx\plugins\ZhaoHuoNatural，再从游戏目录之外运行安装器。' }
        $adoptUntracked = $true
    }
    $environment = Get-ZHEnvironment $paths.Game $dependencies
    foreach ($entry in $dependencies) {
        if ($environment -eq 'CleanGame' -or ($entry.RelativePath -eq 'doorstop_config.ini' -and -not (Test-Path -LiteralPath (Get-ZHChild $paths.Game $entry.RelativePath)))) {
            $actions += [pscustomobject]@{ RelativePath = $entry.RelativePath; Source = $entry.Source; Sha256 = $entry.Sha256; Category = 'Runtime' }
        }
    }
    $legacyPresent = Test-Path -LiteralPath $paths.Legacy -PathType Leaf
    if ((Test-Path -LiteralPath $paths.Legacy) -and -not $legacyPresent) { throw 'MortalBeauty.dll 被同名目录占用。' }
    if ($legacyPresent -and (Test-Path -LiteralPath $paths.Disabled)) { throw '旧插件启用文件和本包禁用文件同时存在，请先自行处理冲突。' }
    foreach ($action in $actions) {
        $destination = Get-ZHChild $paths.Game $action.RelativePath
        Assert-ZHNoLink $destination
        if (Test-Path -LiteralPath $destination -PathType Container) { throw "目标文件被目录占用：$destination" }
        if ($action.Category -ne 'Loader' -and -not ($adoptUntracked -and $action.Category -eq 'Plugin') -and (Test-Path -LiteralPath $destination)) { throw "安装目标已有文件，未盲目覆盖：$destination" }
    }
    [pscustomobject]@{ AlreadyInstalled = $false; SwitchRequired=$false; Paths = $paths; Environment = $environment; Validation = $validation; Actions = $actions; LegacyPresent = $legacyPresent; AdoptedUntrackedPayload = $adoptUntracked; Variant=$variant; PayloadFingerprint=$payloadFingerprint }
}
function Invoke-ZHInstallCore {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$GamePath, [Parameter(Mandatory=$true)][string]$PackageRoot, [switch]$CheckOnly, [scriptblock]$Log, [string]$VariantId)
    $recoveryPaths = Get-ZHLocations $GamePath
    if (Test-Path -LiteralPath (Get-ZHSwitchPath $recoveryPaths)) {
        $null = Restore-ZHSwitch -Paths $recoveryPaths -CheckOnly:$CheckOnly -Log $Log
        if ($CheckOnly) { return [pscustomobject]@{ RecoveryRequired=$true } }
    }
    $plan = Get-ZhaoHuoInstallPlan -GamePath $GamePath -PackageRoot $PackageRoot -VariantId $VariantId
    if ($plan.Validation.CompatibilityMode -eq 'OfflineCompatibilityProbe') {
        $detected = if ($plan.Validation.DetectedBuild) { $plan.Validation.DetectedBuild } else { '未知' }
        Write-ZHLog $Log "Steam build $detected 的离线兼容检测通过，允许继续安装或检查。该构建尚未经本项目实机验证；关键立绘接口与资源通过检测不代表所有剧情已验证。" 'Warning'
    } else {
        Write-ZHLog $Log "64 位游戏与四个程序集 SHA-256 校验通过，匹配已验证 Steam build $($plan.Validation.MatchedBuildId)。"
    }
    if ($plan.AlreadyInstalled) { Write-ZHLog $Log '已经安装同一份美化包，文件校验通过，无需重复覆盖。'; return $plan }
    if ($plan.SwitchRequired) {
        $sourceLabel=if ($plan.SourceVariant.PSObject.Properties['DisplayName']) { $plan.SourceVariant.DisplayName } else { $plan.SourceVariant.Id }
        Write-ZHLog $Log "检测到完整受管$sourceLabel，将备份并替换 $($plan.Actions.Count) 张不同立绘为$($plan.Variant.DisplayName)，保留最初卸载备份。"
        if ($CheckOnly) { Write-ZHLog $Log '切换检查通过，未修改任何游戏文件。'; return $plan }
        return (Invoke-ZHVariantSwitch -Plan $plan -Log $Log)
    }
    if ($plan.Environment -eq 'CleanGame') { Write-ZHLog $Log '识别为纯净游戏：将添加离线官方 BepInEx 6 运行库、配置和 x64 加载器。' }
    else { Write-ZHLog $Log '识别为已有 BepInEx 6：保留现有核心和已有配置，只安装本包并处理兼容加载器。' }
    if ($plan.AdoptedUntrackedPayload) {
        Write-ZHLog $Log '发现无安装记录但与本发布包完全一致的立绘目录，可能是此前直接解压到游戏中。安装时将先逐文件备份，再补全安装记录和加载环境；卸载会恢复这些原有文件。' 'Warning'
    }
    Write-ZHLog $Log "目录：$($plan.Paths.Game)；待安装文件：$($plan.Actions.Count)。"
    if ($CheckOnly) { Write-ZHLog $Log '仅检查完成，未改动任何游戏文件。'; return $plan }
    $paths = $plan.Paths
    Assert-ZHStopped $paths.Game
    $id = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $backupRelative = 'Backups\' + $id
    $backupRoot = Get-ZHChild $paths.State $backupRelative
    $records = @()
    $created = @{}
    foreach ($action in $plan.Actions) {
        $destination = Get-ZHChild $paths.Game $action.RelativePath
        $wasPresent = Test-Path -LiteralPath $destination -PathType Leaf
        $originalHash = $null; $originalRelative = $null
        if ($wasPresent) {
            $originalHash = Get-ZHHash $destination; $originalRelative = 'Original\' + $action.RelativePath
            if ($plan.AdoptedUntrackedPayload -and $action.Category -eq 'Plugin' -and $originalHash -ne $action.Sha256) { throw "未登记立绘文件在检查后被改变，安装已停止：$($action.RelativePath)" }
        }
        $records += [pscustomobject]@{ RelativePath = $action.RelativePath; InstalledSha256 = $action.Sha256; WasPresent = $wasPresent; OriginalSha256 = $originalHash; BackupRelativePath = $originalRelative; Stage = 'pending'; Category = $action.Category }
        $directory = [IO.Path]::GetDirectoryName($destination)
        while ($directory -and $directory -ne $paths.Game) {
            if (-not (Test-Path -LiteralPath $directory)) { $created[$directory.Substring($paths.Game.Length + 1)] = $true }
            $directory = [IO.Path]::GetDirectoryName($directory)
        }
    }
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    foreach ($record in $records) {
        if ($record.WasPresent) { Copy-ZHVerified (Get-ZHChild $paths.Game $record.RelativePath) (Get-ZHChild $backupRoot $record.BackupRelativePath) $record.OriginalSha256 }
    }
    $legacyHash = $null
    if ($plan.LegacyPresent) { $legacyHash = Get-ZHHash $paths.Legacy; Copy-ZHVerified $paths.Legacy (Get-ZHChild $backupRoot 'MortalBeauty.dll') $legacyHash }
    $manifest = [pscustomobject][ordered]@{
        SchemaVersion = 3; PackageId = 'ZhaoHuoNatural'; InstallationId = $id; Status = 'installing'; GamePath = $paths.Game
        InstalledAtUtc = [DateTime]::UtcNow.ToString('o'); GameAssemblySha256 = $plan.Validation.Hashes; SteamBuildId = $plan.Validation.BuildId
        MatchedBuildId = $plan.Validation.MatchedBuildId
        VariantId=$plan.Variant.Id; VariantDisplayName=$plan.Variant.DisplayName; PayloadFingerprint=$plan.PayloadFingerprint
        CompatibilityMode = $plan.Validation.CompatibilityMode; DetectedBuild = $plan.Validation.DetectedBuild
        CompatibilityEvidence = $(if ($plan.Validation.Probe) { [pscustomobject]@{ BaselineBuildIds = @($plan.Validation.Probe.BaselineBuildIds); Checks = @($plan.Validation.Probe.Checks) } } else { $null })
        AdoptedUntrackedPayload = $plan.AdoptedUntrackedPayload
        Environment = $plan.Environment; BackupRelativePath = $backupRelative; OwnedFiles = $records; CreatedDirectories = @($created.Keys)
        Legacy = [pscustomobject]@{ WasPresent = $plan.LegacyPresent; DisabledByThisInstall = $plan.LegacyPresent; Sha256 = $legacyHash; Stage = 'pending' }
    }
    Save-ZHJson $manifest $paths.Manifest
    try {
        if ($plan.LegacyPresent) {
            $manifest.Legacy.Stage = 'applying'; Save-ZHJson $manifest $paths.Manifest
            Move-Item -LiteralPath $paths.Legacy -Destination $paths.Disabled
            $manifest.Legacy.Stage = 'applied'; Save-ZHJson $manifest $paths.Manifest
            Write-ZHLog $Log '已备份并停用旧 MortalBeauty.dll；旧图片和其他内容保持原样。'
        }
        for ($index = 0; $index -lt $records.Count; $index++) {
            $records[$index].Stage = 'applying'; Save-ZHJson $manifest $paths.Manifest
            $action = $plan.Actions[$index]
            Copy-ZHVerified $action.Source (Get-ZHChild $paths.Game $action.RelativePath) $action.Sha256
            $records[$index].Stage = 'applied'; Save-ZHJson $manifest $paths.Manifest
        }
        $manifest.Status = 'installed'; Save-ZHJson $manifest $paths.Manifest
        Write-ZHLog $Log '安装完成。请从 Steam 库正常启动活侠传。'
        Write-ZHLog $Log "备份和安装记录：$($paths.State)"
        return $manifest
    } catch {
        $failure = $_
        Write-ZHLog $Log "安装失败：$($failure.Exception.Message)。正在自动回滚……" 'Error'
        try { Uninstall-ZhaoHuo -GamePath $paths.Game -Log $Log | Out-Null }
        catch { Write-ZHLog $Log "自动回滚未完成：$($_.Exception.Message)。请保留备份，解决问题后再次点击“卸载并恢复”。" 'Error' }
        throw $failure
    }
}
function Invoke-ZHUninstallCore {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$GamePath, [switch]$CheckOnly, [scriptblock]$Log)
    $paths = Get-ZHLocations $GamePath
    foreach ($path in @($paths.Game, $paths.Plugin, $paths.State, $paths.Manifest, $paths.Legacy, $paths.Disabled)) { Assert-ZHNoLink $path }
    Assert-ZHStopped $paths.Game
    if (Test-Path -LiteralPath (Get-ZHSwitchPath $paths)) {
        $null = Restore-ZHSwitch -Paths $paths -CheckOnly:$CheckOnly -Log $Log
        if ($CheckOnly) { return }
    }
    $manifest = Read-ZHState $paths
    if (-not $manifest) { Write-ZHLog $Log '没有找到活动安装记录，未改动任何文件。'; return }
    $backupRoot = Get-ZHChild $paths.State $manifest.BackupRelativePath
    Assert-ZHNoLink $backupRoot
    $records = @(Get-ZHOwnedRecords $manifest)
    $seen = @{}
    foreach ($record in $records) {
        Assert-ZHRecord $record $paths $backupRoot
        $destination = Get-ZHChild $paths.Game $record.RelativePath
        if ($seen.ContainsKey($destination)) { throw '安装记录中有重复目标。' }
        $seen[$destination] = $true
    }
    $restoreLegacy = $manifest.Legacy.DisabledByThisInstall -and ($manifest.SchemaVersion -ne 3 -or $manifest.Legacy.Stage -ne 'pending')
    $legacyBackup = Get-ZHChild $backupRoot 'MortalBeauty.dll'
    if ($restoreLegacy) {
        Assert-ZHNoLink $legacyBackup
        if (-not $manifest.Legacy.WasPresent -or -not (Test-Path -LiteralPath $legacyBackup -PathType Leaf) -or (Get-ZHHash $legacyBackup) -ne $manifest.Legacy.Sha256) { throw '旧插件原文件备份缺失或校验失败，未进行卸载。' }
        if (Test-Path -LiteralPath $paths.Disabled -PathType Container) { throw '被停用的旧插件路径被目录占用。' }
    }
    $diagnostics = Get-ZHChild $paths.Plugin 'Diagnostics'
    Assert-ZHNoLink $diagnostics
    if (Test-Path -LiteralPath $diagnostics -PathType Container) { $null = @(Get-ZHFiles $diagnostics) }
    $ownedDirectories = @{}
    if ($manifest.SchemaVersion -eq 3) {
        foreach ($relative in @($manifest.CreatedDirectories)) {
            if ($relative -ne 'BepInEx' -and $relative -ne 'BepInEx\core' -and $relative -ne 'BepInEx\plugins' -and $relative -ne $script:PluginRelative -and -not $relative.StartsWith($script:PluginRelative + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "安装记录中的目录不属于本包：$relative" }
            $ownedDirectories[(Get-ZHChild $paths.Game $relative)] = $true
        }
    } else {
        foreach ($record in $records) {
            if ($record.Category -ne 'Plugin') { continue }
            $directory = [IO.Path]::GetDirectoryName((Get-ZHChild $paths.Game $record.RelativePath))
            while ($directory.StartsWith($paths.Plugin, [StringComparison]::OrdinalIgnoreCase)) { $ownedDirectories[$directory] = $true; $directory = [IO.Path]::GetDirectoryName($directory) }
        }
    }
    foreach ($directory in $ownedDirectories.Keys) { Assert-ZHNoLink $directory }
    Write-ZHLog $Log "已验证卸载记录与原文件备份，记录文件数：$($records.Count)。"
    if ($CheckOnly) { Write-ZHLog $Log '仅检查完成，未改动任何文件。'; return }
    Assert-ZHStopped $paths.Game
    $manifest.Status = 'uninstalling'; Save-ZHJson $manifest $paths.Manifest
    $preserved = Get-ZHChild $backupRoot ('Preserved-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    if (Test-Path -LiteralPath $diagnostics -PathType Container) {
        $diagnosticTarget = Get-ZHChild $preserved 'Diagnostics'
        Assert-ZHNoLink $diagnosticTarget
        New-Item -ItemType Directory -Path $preserved -Force | Out-Null
        Move-Item -LiteralPath $diagnostics -Destination $diagnosticTarget
        Write-ZHLog $Log "运行验证记录已保留：$diagnosticTarget"
    }
    foreach ($record in $records) {
        if ($record.Stage -eq 'pending') { continue }
        $destination = Get-ZHChild $paths.Game $record.RelativePath
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            $currentHash = Get-ZHHash $destination
            if ($currentHash -ne $record.InstalledSha256 -and (-not $record.WasPresent -or $currentHash -ne $record.OriginalSha256)) {
                Copy-ZHVerified $destination (Get-ZHChild $preserved $record.RelativePath) $currentHash
                Write-ZHLog $Log "已保留安装后修改的文件：$($record.RelativePath)"
            }
        }
        if ($record.WasPresent) { Copy-ZHVerified (Get-ZHChild $backupRoot $record.BackupRelativePath) $destination $record.OriginalSha256 }
        elseif (Test-Path -LiteralPath $destination -PathType Leaf) { Remove-Item -LiteralPath $destination -Force }
    }
    if ($restoreLegacy) {
        if (-not (Test-Path -LiteralPath $paths.Legacy)) { Copy-ZHVerified $legacyBackup $paths.Legacy $manifest.Legacy.Sha256 }
        elseif (-not (Test-Path -LiteralPath $paths.Legacy -PathType Leaf) -or (Get-ZHHash $paths.Legacy) -ne $manifest.Legacy.Sha256) { Write-ZHLog $Log "检测到后来放入的同名旧插件，已保留它；原始版本仍在：$legacyBackup" 'Warning' }
        if (Test-Path -LiteralPath $paths.Disabled -PathType Leaf) {
            $disabledHash = Get-ZHHash $paths.Disabled
            if ($disabledHash -ne $manifest.Legacy.Sha256) { Copy-ZHVerified $paths.Disabled (Get-ZHChild $preserved 'MortalBeauty.dll.disabled-by-zhaohuo-natural') $disabledHash }
            Remove-Item -LiteralPath $paths.Disabled -Force
        }
    }
    foreach ($directory in @($ownedDirectories.Keys | Sort-Object Length -Descending)) {
        if ((Test-Path -LiteralPath $directory -PathType Container) -and @(Get-ChildItem -LiteralPath $directory -Force).Count -eq 0) { Remove-Item -LiteralPath $directory -Force }
    }
    $manifest.Status = 'uninstalled'
    $manifest | Add-Member -MemberType NoteProperty -Name UninstalledAtUtc -Value ([DateTime]::UtcNow.ToString('o')) -Force
    Save-ZHJson $manifest (Get-ZHChild $backupRoot 'UninstallManifest.json')
    Remove-Item -LiteralPath $paths.Manifest -Force
    Write-ZHLog $Log '卸载完成，已恢复安装前的受管文件状态。用户另加文件、存档和其他插件未删除。'
    Write-ZHLog $Log "备份、历史与修改文件保留在：$backupRoot"
}
function Get-ZhaoHuoSteamCandidates {
    [CmdletBinding()]
    param([string[]]$SteamRoots)
    $roots = @()
    if ($SteamRoots) { $roots += $SteamRoots }
    else {
        foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
            $properties = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
            if ($properties) {
                foreach ($name in @('SteamPath', 'InstallPath')) { if ($properties.PSObject.Properties[$name]) { $roots += [string]$properties.$name } }
            }
        }
        foreach ($programRoot in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) { if ($programRoot) { $roots += Join-Path $programRoot 'Steam' } }
    }
    $libraries = @{}
    foreach ($root in @($roots | Where-Object { $_ } | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $canonical = Get-ZHCanonical $root
        $libraries[$canonical] = $true
        $vdf = Join-Path $canonical 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf -PathType Leaf) {
            $text = Get-Content -LiteralPath $vdf -Raw -Encoding UTF8
            foreach ($match in [regex]::Matches($text, '"(?:path|[0-9]+)"\s+"([^"\r\n]+)"')) {
                $candidate = $match.Groups[1].Value.Replace('\\', '\')
                if ([IO.Path]::IsPathRooted($candidate) -and (Test-Path -LiteralPath $candidate -PathType Container)) { $libraries[(Get-ZHCanonical $candidate)] = $true }
            }
        }
    }
    $found = @{}
    foreach ($library in $libraries.Keys) {
        $common = Join-Path $library 'steamapps\common'
        $installDir = 'LegendOfMortal'
        $acf = Join-Path $library 'steamapps\appmanifest_1859910.acf'
        if (Test-Path -LiteralPath $acf -PathType Leaf) {
            if ((Get-Content -LiteralPath $acf -Raw -Encoding UTF8) -match '"installdir"\s+"([^"\r\n]+)"') { $installDir = $Matches[1] }
        }
        try { $candidate = Get-ZHChild $common $installDir } catch { continue }
        if (Test-Path -LiteralPath (Join-Path $candidate 'Mortal.exe') -PathType Leaf) { $found[$candidate] = $true }
    }
    return @($found.Keys | Sort-Object)
}
. (Join-Path $PSScriptRoot 'VariantSupport.ps1')
. (Join-Path $PSScriptRoot 'AppearanceManager.ps1')
Export-ModuleMember -Function Get-ZhaoHuoSteamCandidates, Get-ZhaoHuoInstallPlan, Install-ZhaoHuo, Uninstall-ZhaoHuo, Get-ZhaoHuoVariants, Get-ZhaoHuoInstalledVariant
