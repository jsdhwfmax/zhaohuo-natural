#requires -Version 5.1
# Static inspection only. Never load a game assembly into the CLR.
$script:ZHCecilHash = '7AE470288FFF4A402899C254D0A76CEFEF55877F5C54F96E83C797CC5BB6E2F6'
$script:ZHCompatibilityBaselineHash = '7BA8D1175F4A9C603B61E81FAF4F42DA5A9A79D14D2EEA3A12C72B04CF6F2A26'
$script:ZHCompatibilityBaseline25987745Hash = 'B20CF307BEDFED189303DFAC565B1E2EA1DBD8B616E8B649BFE41A0ED2A9B306'
$script:ZHCompatibilityBaseline26021712Hash = '70F16F0205A49450740B0D4216292EE666657FB66A4DE1E9F0788B7A63561200'
function Get-ZHCPHash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Get-ZHCPChild([string]$Root, [string]$Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative) -or $Relative.Contains(':') -or @($Relative -split '[\\/]' | Where-Object {$_ -in @('','..','.')}).Count) { throw '兼容性检查遇到不安全的相对路径。' }
    $path = [IO.Path]::GetFullPath((Join-Path $Root $Relative))
    $current = $path
    while ($current) {
        if ((Test-Path -LiteralPath $current) -and (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw '兼容性检查不支持符号链接或目录联接。' }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) { break }; $current = $parent.FullName
    }
    return $path
}
function Get-ZHCPTextHash([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','') } finally { $sha.Dispose() }
}
function Get-ZHCPVersionMetadataHash([string]$Path) {
    # Latin-1 is a reversible byte mapping. Normalize only the visible game
    # version string; any other serialized setting/length change still rejects.
    $text=[Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($Path))
    if (@([regex]::Matches($text,'release_[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')).Count -ne 1) {throw '无法识别游戏版本元数据。'}
    Get-ZHCPTextHash ([regex]::Replace($text,'release_[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+','<GAME_VERSION>'))
}
function Initialize-ZHCPCecil([string]$PackageRoot) {
    $path = Get-ZHCPChild $PackageRoot 'Dependencies\BepInEx\files\BepInEx\core\Mono.Cecil.dll'
    if ((Get-ZHCPHash $path) -ne $script:ZHCecilHash) { throw '包内官方 Mono.Cecil 校验失败，请重新下载完整安装包。' }
    $loaded = @([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object {$_.GetName().Name -eq 'Mono.Cecil'})
    foreach ($assembly in $loaded) {
        if ([string]::IsNullOrWhiteSpace($assembly.Location) -or (Get-ZHCPHash $assembly.Location) -ne $script:ZHCecilHash) { throw '检测进程已加载其他版本 Mono.Cecil，请关闭安装器后重试。' }
    }
    if ($loaded.Count -eq 0) { Add-Type -Path $path }
}
function Get-ZHCPTypes($Types) {
    foreach ($type in $Types) { $type; if ($type.HasNestedTypes) { Get-ZHCPTypes $type.NestedTypes } }
}
function Get-ZHCPAttributes($Provider) {
    foreach ($attribute in $Provider.CustomAttributes) {
        'Attribute=' + $attribute.Constructor.FullName + ':' + [BitConverter]::ToString($attribute.GetBlob())
    }
}
function Get-ZHCPGenerics($Provider) {
    foreach ($parameter in $Provider.GenericParameters) {
        'Generic=' + $parameter.Position + ':' + [int]$parameter.Attributes
        # The pinned Cecil 0.10.4 represents constraints directly as TypeReference.
        foreach ($constraint in $parameter.Constraints) {'Constraint=' + $constraint.FullName}
        Get-ZHCPAttributes $parameter
    }
}
function Get-ZHCPMethodHash($Method) {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    # Numeric flags avoid .NET Framework/.NET differences in enum alias names.
    $lines.Add($Method.FullName); $lines.Add(([int]$Method.Attributes).ToString()); $lines.Add(([int]$Method.ImplAttributes).ToString())
    $lines.Add('Convention=' + [int]$Method.CallingConvention + ';HasThis=' + $Method.HasThis + ';ExplicitThis=' + $Method.ExplicitThis)
    foreach ($line in (Get-ZHCPAttributes $Method)) {$lines.Add($line)}
    foreach ($line in (Get-ZHCPGenerics $Method)) {$lines.Add($line)}
    foreach ($parameter in $Method.Parameters) {
        $lines.Add('Parameter=' + $parameter.Index + ':' + [int]$parameter.Attributes + ':Constant=' + $parameter.Constant)
        foreach ($line in (Get-ZHCPAttributes $parameter)) {$lines.Add($line)}
    }
    $lines.Add('Return=' + [int]$Method.MethodReturnType.Attributes + ':Constant=' + $Method.MethodReturnType.Constant)
    foreach ($line in (Get-ZHCPAttributes $Method.MethodReturnType)) {$lines.Add($line)}
    foreach ($override in $Method.Overrides) {$lines.Add('Override=' + $override.FullName)}
    if ($Method.HasBody) {
        $lines.Add('InitLocals=' + $Method.Body.InitLocals); $lines.Add('MaxStack=' + $Method.Body.MaxStackSize)
        foreach ($variable in $Method.Body.Variables) { $lines.Add('Local=' + $variable.VariableType.FullName) }
        foreach ($instruction in $Method.Body.Instructions) { $lines.Add($instruction.ToString()) }
        foreach ($handler in $Method.Body.ExceptionHandlers) {
            $line = ([int]$handler.HandlerType).ToString() + ':'
            foreach ($name in @('TryStart','TryEnd','HandlerStart','HandlerEnd','FilterStart')) {
                $boundary=$handler.$name; $offset='null'; if ($null -ne $boundary) {$offset=$boundary.Offset.ToString()}; $line += $name + '=' + $offset + ';'
            }
            if ($handler.CatchType) {$line += $handler.CatchType.FullName}; $lines.Add($line)
        }
    }
    Get-ZHCPTextHash ($lines -join "`n")
}
function Get-ZHCPTypeHash($Type) {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add($Type.FullName); $lines.Add(([int]$Type.Attributes).ToString()); $lines.Add('Packing=' + $Type.PackingSize + ';Size=' + $Type.ClassSize)
    foreach ($line in (Get-ZHCPAttributes $Type)) {$lines.Add($line)}
    foreach ($line in (Get-ZHCPGenerics $Type)) {$lines.Add($line)}
    if ($Type.BaseType) {$lines.Add('Base=' + $Type.BaseType.FullName)}
    foreach ($interface in $Type.Interfaces) {$lines.Add('Interface=' + $interface.InterfaceType.FullName)}
    foreach ($field in $Type.Fields) {
        $lines.Add($field.FullName + '|' + [int]$field.Attributes + '|Offset=' + $field.Offset + '|Constant=' + $field.Constant)
        foreach ($line in (Get-ZHCPAttributes $field)) {$lines.Add($line)}
    }
    Get-ZHCPTextHash ($lines -join "`n")
}
function Test-ZHCPInternalType($Type, $Module) {
    $scope=$Type.GetElementType().Scope
    if ($scope -is [Mono.Cecil.ModuleDefinition]) {return [object]::ReferenceEquals($scope,$Module)}
    if ($scope -is [Mono.Cecil.AssemblyNameReference]) {return $scope.FullName -ceq $Module.Assembly.Name.FullName}
    if ($scope -is [Mono.Cecil.ModuleReference]) {return $scope.Name -ceq $Module.Name}
    return $false
}
function Get-ZHCPCoreSurface($Module, [string[]]$SeedTypes) {
    $types=@{}; foreach ($type in (Get-ZHCPTypes $Module.Types)) {$types[$type.FullName]=$type}
    $methods=@{}; $usedTypes=@{}; $queue=New-Object 'System.Collections.Generic.Queue[object]'
    foreach ($name in $SeedTypes) {
        if (-not $types.ContainsKey($name)) {throw ('缺少立绘依赖类型：' + $name)}
        # Enums may have no methods; still protect their numeric field constants.
        $usedTypes[$name]=Get-ZHCPTypeHash $types[$name]
        foreach ($type in (Get-ZHCPTypes @($types[$name]))) {foreach ($method in $type.Methods) {$queue.Enqueue($method)}}
    }
    while ($queue.Count -gt 0) {
        $method=$queue.Dequeue()
        if ($methods.ContainsKey($method.FullName)) {continue}
        $methods[$method.FullName]=Get-ZHCPMethodHash $method
        $type=$method.DeclaringType
        if (-not $usedTypes.ContainsKey($type.FullName)) {
            $usedTypes[$type.FullName]=Get-ZHCPTypeHash $type
            foreach ($extra in $type.Methods) {if ($extra.Name -eq '.cctor') {$queue.Enqueue($extra)}}
            foreach ($nested in (Get-ZHCPTypes $type.NestedTypes)) {foreach ($extra in $nested.Methods) {$queue.Enqueue($extra)}}
        }
        if (-not $method.HasBody) {continue}
        foreach ($instruction in $method.Body.Instructions) {
            $operand=$instruction.Operand
            if ($operand -is [Mono.Cecil.MethodReference] -and (Test-ZHCPInternalType $operand.DeclaringType $Module)) {
                $called=$operand.Resolve(); if ($null -eq $called -or -not [object]::ReferenceEquals($called.Module,$Module)) {throw '无法静态解析立绘方法调用。'}; $queue.Enqueue($called)
            }
            elseif ($operand -is [Mono.Cecil.FieldReference] -and (Test-ZHCPInternalType $operand.DeclaringType $Module)) {
                $field=$operand.Resolve(); if ($null -eq $field -or -not [object]::ReferenceEquals($field.Module,$Module)) {throw '无法静态解析立绘字段引用。'}
                if (-not $usedTypes.ContainsKey($field.DeclaringType.FullName)) {$usedTypes[$field.DeclaringType.FullName]=Get-ZHCPTypeHash $field.DeclaringType; foreach($cctor in $field.DeclaringType.Methods){if($cctor.Name -eq '.cctor'){$queue.Enqueue($cctor)}}}
            }
        }
    }
    [pscustomobject]@{
        Methods=@($methods.Keys | Sort-Object | ForEach-Object {[pscustomobject]@{Name=$_;Sha256=$methods[$_]}})
        Types=@($usedTypes.Keys | Sort-Object | ForEach-Object {[pscustomobject]@{Name=$_;Sha256=$usedTypes[$_]}})
    }
}
function Test-ZHCPSingleBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$GamePath,[Parameter(Mandatory=$true)][string]$PackageRoot,[Parameter(Mandatory=$true)][object]$BaselineSpec)
    $checks=New-Object 'System.Collections.Generic.List[object]'; $reasons=New-Object 'System.Collections.Generic.List[string]'
    $fingerprints=[ordered]@{}; $baselineIds=@(); $resolver=$null; $core=$null; $plugin=$null
    $originalCulture=[Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::InvariantCulture
        $baselinePath=Get-ZHCPChild $PackageRoot $BaselineSpec.RelativePath
        if ((Get-ZHCPHash $baselinePath) -ne $BaselineSpec.Sha256) {throw '兼容性基线校验失败，请重新下载完整安装包。'}
        $baseline=Get-Content -LiteralPath $baselinePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($baseline.SchemaVersion -ne 1) {throw '不支持的兼容性基线版本。'}
        $baselineIds=@($baseline.BaselineBuildIds)
        $checks.Add([pscustomobject]@{Name='PinnedBaseline';Passed=$true;Sha256=$BaselineSpec.Sha256;RelativePath=$BaselineSpec.RelativePath})
        Initialize-ZHCPCecil $PackageRoot
        $checks.Add([pscustomobject]@{Name='TrustedCecil';Passed=$true;Sha256=$script:ZHCecilHash})
        foreach ($name in @('Assembly-CSharp.dll','Mortal.Core.dll','Mortal.Story.dll','Fungus.dll')) {$fingerprints[$name]=Get-ZHCPHash (Get-ZHCPChild $GamePath ('Mortal_Data\Managed\'+$name))}
        foreach ($file in $baseline.FixedFiles) {
            $path=Get-ZHCPChild $GamePath $file.RelativePath
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -ne $file.SizeBytes -or (Get-ZHCPHash $path) -ne $file.Sha256) {throw ('相关框架或资源发生变化，需人工适配：'+$file.RelativePath)}
        }
        $actualInventory=@(Get-ZHCPGuardInventory $GamePath)
        $expectedInventory=@($baseline.FixedFiles | ForEach-Object {$_.RelativePath})
        [Array]::Sort($actualInventory,[StringComparer]::Ordinal)
        [Array]::Sort($expectedInventory,[StringComparer]::Ordinal)
        if (($actualInventory -join "`n") -cne ($expectedInventory -join "`n")) {throw '相关运行库或资源文件集合发生变化，需人工适配。'}
        $checks.Add([pscustomobject]@{Name='GuardedFileInventory';Passed=$true;Count=$actualInventory.Count;Sha256=(Get-ZHCPTextHash ($actualInventory -join "`n"))})
        foreach($group in @($baseline.FixedFiles | Group-Object Category)) {
            $checks.Add([pscustomobject]@{Name=$group.Name;Passed=$true;Count=$group.Count;Sha256=(Get-ZHCPTextHash (($group.Group | ForEach-Object {$_.RelativePath+'='+$_.Sha256}) -join "`n"))})
        }
        if ((Get-ZHCPVersionMetadataHash (Get-ZHCPChild $GamePath $baseline.VersionMetadata.RelativePath)) -ne $baseline.VersionMetadata.NormalizedSha256) {throw '游戏引导或版本元数据结构发生变化，需人工适配。'}
        $checks.Add([pscustomobject]@{Name='VersionMetadata';Passed=$true;Sha256=$baseline.VersionMetadata.NormalizedSha256})
        $managed=Get-ZHCPChild $GamePath 'Mortal_Data\Managed'
        $actualNames=@(Get-ChildItem -LiteralPath $managed -File -Filter '*.dll' | ForEach-Object {$_.Name} | Sort-Object)
        if (($actualNames -join "`n") -cne (@($baseline.ManagedAssemblyNames) -join "`n")) {throw '游戏程序集清单发生变化，需人工确认。'}
        $checks.Add([pscustomobject]@{Name='ManagedAssemblyNames';Passed=$true;Count=$actualNames.Count;Sha256=(Get-ZHCPTextHash ($actualNames -join "`n"))})
        $resolver=New-Object Mono.Cecil.DefaultAssemblyResolver
        $resolver.AddSearchDirectory($managed)
        $resolver.AddSearchDirectory((Get-ZHCPChild $PackageRoot 'Dependencies\BepInEx\files\BepInEx\core'))
        $reader=New-Object Mono.Cecil.ReaderParameters; $reader.AssemblyResolver=$resolver
        $core=[Mono.Cecil.ModuleDefinition]::ReadModule((Get-ZHCPChild $managed 'Mortal.Core.dll'),$reader)
        $surface=Get-ZHCPCoreSurface $core @($baseline.CoreSeedTypes)
        foreach ($category in @('Methods','Types')) {
            $expected=@{}; foreach ($entry in $baseline.CoreSurface.$category) {$expected[$entry.Name]=$entry.Sha256}
            $actual=@($surface.$category)
            if ($actual.Count -ne $expected.Count) {throw ('立绘依赖的'+$category+'范围发生变化，需人工适配。')}
            foreach($entry in $actual) {if (-not $expected.ContainsKey($entry.Name) -or $expected[$entry.Name] -ne $entry.Sha256) {throw ('立绘接口或行为发生变化：'+$entry.Name)}}
            $checks.Add([pscustomobject]@{Name=('Core'+$category);Passed=$true;Count=$actual.Count;Sha256=(Get-ZHCPTextHash (($actual | ForEach-Object {$_.Name+'='+$_.Sha256}) -join "`n"))})
        }
        $pluginPath=Get-ZHCPChild $PackageRoot 'BepInEx\plugins\ZhaoHuoNatural\ZhaoHuoNatural.dll'
        if ((Get-ZHCPHash $pluginPath) -ne $baseline.PluginSha256) {throw '插件版本与兼容性基线不一致。'}
        $plugin=[Mono.Cecil.ModuleDefinition]::ReadModule($pluginPath,$reader)
        $references=@($plugin.GetMemberReferences() | Where-Object {$_.DeclaringType.Scope.Name -in @('Mortal.Core','Mortal.Story','Fungus','OBB.Framework')})
        if ($references.Count -ne $baseline.GameMemberReferenceCount) {throw '插件游戏成员引用清单与基线不一致。'}
        foreach ($reference in $references) {if ($null -eq $reference.Resolve()) {throw ('无法静态解析游戏接口：'+$reference.FullName)}}
        $checks.Add([pscustomobject]@{Name='GameMemberReferences';Passed=$true;Count=$references.Count;Sha256=(Get-ZHCPTextHash (($references | ForEach-Object {$_.FullName} | Sort-Object) -join "`n"))})
    } catch {
        # Do not expose exception paths or account details in public diagnostic records.
        $message=$_.Exception.Message
        if ($message -match '[A-Za-z]:[\\/]|\\\\' -or $message -notmatch '[\u4e00-\u9fff]') {$message='兼容性检查无法读取或解析必要文件，请完整解压并确认游戏文件完整。'}
        $reasons.Add($message)
    } finally {
        if ($plugin) {$plugin.Dispose()}; if ($core) {$core.Dispose()}; if ($resolver) {$resolver.Dispose()}
        [Threading.Thread]::CurrentThread.CurrentCulture=$originalCulture
    }
    [pscustomobject]@{Compatible=($reasons.Count -eq 0);Method='OfflineCompatibilityProbe';BaselineBuildIds=$baselineIds;MatchedBaselineFile=$(if($reasons.Count-eq 0){$BaselineSpec.RelativePath}else{$null});Reasons=$reasons.ToArray();Checks=$checks.ToArray();FingerprintSet=$fingerprints}
}

function Get-ZHCPGuardInventory([string]$GamePath) {
    # This exact inventory closes the gap where a new bundle or serialized scene
    # could be added while every previously pinned file remained unchanged.
    $root=[IO.Path]::GetFullPath($GamePath).TrimEnd('\')
    $files=New-Object 'System.Collections.Generic.List[string]'
    function Add-InventoryPath([string]$Path) {
        $relative=$Path.Substring($root.Length+1).Replace('\','/')
        $null=Get-ZHCPChild $root $relative
        $files.Add($relative)
    }
    Get-ChildItem -LiteralPath (Get-ZHCPChild $root 'Mortal_Data/Managed') -Filter '*.dll' -File|Where-Object Name -ne 'Mortal.Core.dll'|ForEach-Object{Add-InventoryPath $_.FullName}
    foreach($name in @('Mortal.exe','UnityPlayer.dll')){Add-InventoryPath (Get-ZHCPChild $root $name)}
    Get-ChildItem -LiteralPath (Get-ZHCPChild $root 'MonoBleedingEdge') -Recurse -File|ForEach-Object{Add-InventoryPath $_.FullName}
    Get-ChildItem -LiteralPath (Get-ZHCPChild $root 'Mortal_Data') -File|Where-Object Name -ne 'globalgamemanagers'|ForEach-Object{Add-InventoryPath $_.FullName}
    Get-ChildItem -LiteralPath (Get-ZHCPChild $root 'Mortal_Data/Resources') -Recurse -File|ForEach-Object{Add-InventoryPath $_.FullName}
    $aa=Get-ZHCPChild $root 'Mortal_Data/StreamingAssets/aa'
    foreach($name in @('catalog.json','settings.json')){Add-InventoryPath (Join-Path $aa $name)}
    Get-ChildItem -LiteralPath $aa -Recurse -File -Filter '*.bundle'|ForEach-Object{Add-InventoryPath $_.FullName}
    $files.ToArray()
}
function Get-ZHCompatibilityBaselineFiles {
    # Each entry is one indivisible snapshot. Never accept a union of per-file
    # hashes from these baselines, even when all individual files look familiar.
    @(
        [pscustomobject]@{RelativePath='installer/compatibility-baseline.json';Sha256=$script:ZHCompatibilityBaselineHash}
        [pscustomobject]@{RelativePath='installer/compatibility-baseline-25987745.json';Sha256=$script:ZHCompatibilityBaseline25987745Hash}
        [pscustomobject]@{RelativePath='installer/compatibility-baseline-26021712.json';Sha256=$script:ZHCompatibilityBaseline26021712Hash}
    )
}
function Test-ZhaoHuoCompatibility {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$GamePath,[Parameter(Mandatory=$true)][string]$PackageRoot)
    $failures=New-Object 'System.Collections.Generic.List[object]'
    $availableIds=New-Object 'System.Collections.Generic.List[string]'
    $fingerprints=[ordered]@{}
    try {
        $specs=@(Get-ZHCompatibilityBaselineFiles)
        # Validate the entire shipped baseline set before selecting one. A
        # missing/tampered alternative must not silently become a successful
        # partial package, nor permit arbitrary caller-supplied baselines.
        foreach($spec in $specs) {
            if($spec.Sha256 -notmatch '^[0-9A-F]{64}$'){throw '兼容性基线尚未完成，请使用正式完整安装包。'}
            $path=Get-ZHCPChild $PackageRoot $spec.RelativePath
            if(-not(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-ZHCPHash $path)-ne $spec.Sha256){throw '兼容性基线校验失败，请重新下载完整安装包。'}
            $baseline=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
            if($baseline.SchemaVersion-ne 1 -or @($baseline.BaselineBuildIds).Count-eq 0){throw '不支持的兼容性基线版本。'}
            foreach($id in $baseline.BaselineBuildIds){$availableIds.Add([string]$id)}
        }
        foreach($spec in $specs) {
            $result=Test-ZHCPSingleBaseline -GamePath $GamePath -PackageRoot $PackageRoot -BaselineSpec $spec
            $fingerprints=$result.FingerprintSet
            if($result.Compatible) {
                $result|Add-Member NoteProperty 'AvailableBaselineBuildIds' @($availableIds.ToArray()|Select-Object -Unique)
                return $result
            }
            $failures.Add([pscustomobject]@{BaselineBuildIds=@($result.BaselineBuildIds);Reasons=@($result.Reasons)})
        }
        $reasons=@($failures|ForEach-Object{'基线'+($_.BaselineBuildIds -join '/')+'：'+($_.Reasons -join '；')})
    } catch {
        $message=$_.Exception.Message
        if($message -match '[A-Za-z]:[\\/]|\\\\' -or $message -notmatch '[\u4e00-\u9fff]'){$message='兼容性检查无法读取或解析必要文件，请完整解压并确认游戏文件完整。'}
        $reasons=@($message)
    }
    [pscustomobject]@{Compatible=$false;Method='OfflineCompatibilityProbe';BaselineBuildIds=@($availableIds.ToArray()|Select-Object -Unique);AvailableBaselineBuildIds=@($availableIds.ToArray()|Select-Object -Unique);MatchedBaselineFile=$null;Reasons=$reasons;Checks=@();FingerprintSet=$fingerprints;RejectedBaselines=$failures.ToArray()}
}
