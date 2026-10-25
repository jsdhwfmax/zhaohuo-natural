#requires -Version 5.1
# Data-only package validation. No game assembly is loaded or executed.
$script:LegacyCharacterIds=@('player','tang-buyi','xiahou-lan')
$script:CharacterIds=@('player','tang-buyi','xiahou-lan','tang-moling','long-xiang','yu-xiaomei','tang-zheng')
$script:CharacterNames=@{player='赵活';'tang-buyi'='唐布衣（大师兄）';'xiahou-lan'='夏侯兰';'tang-moling'='唐默铃';'long-xiang'='龙湘';'yu-xiaomei'='虞小梅';'tang-zheng'='唐铮'}
$script:CharacterSharedHashes=@{
    'ZhaoHuoNatural.dll'='AEEE02AC56DCDCB1E683D6356AC28FE19E61AF861D5663ACFFD1B83984F06957'
    'portrait-map.txt'='844B9A7F73CB2B16DC2F911B18418ADDD4446E9D522D4F7448EFEDD4A614614C'
    'portrait-layout.tsv'='DCE2CDF380008740BC6151F979251F119880605A0C370DB0C0533C088FED011A'
}
$script:CharacterAssets=@{
    player=$script:PortraitNames
    'tang-buyi'=@('angry1','angry2','angry3','hand','hat','hurt','laugh1','laugh2','nervous1','nervous2','nervous3','normal','serious','shock','special1','suck')
    'xiahou-lan'=@('angry','angry2','block','blood','cry','droopy','gloomy','gloomy2','laugh1','love','nervous','nervous2','normal','shy2','squint','white')
    'tang-moling'=@('angry1','close_eye','close_eye_laugh','gamer','laugh1','laugh3','nervous1','nervous2','normal','one_hand','proud','sad2','shy','special1','special2','special3')
    'long-xiang'=@('angry1','angry3','angry4','black','close_eyes','diffident','doubt','drumstick','drumstick_sword','hurt','hurt2','laugh1','laugh2','nervous1','nervous2','nervous3','normal','sad','sad2','shy','shy2','sword')
    'yu-xiaomei'=@('angry1','angry2','angry3','backstage','black','gloomy2','hurt','kick','laugh1','laugh2','laugh3','nervous1','nervous2','nervous3','normal','norseblood','proud','sad1','scary','scary_laugh','scary_shock','shy1','shy2','shy3','shy4','special5','special5_2','special6')
    'tang-zheng'=@('angry1','angry2','close_eye','close_eye_nervous','gloomy1','gloomy2','hurt','laugh1','laugh2','nervous1','nervous2','normal')
}
function Get-ZHTextHash([string]$Text) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try {([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','')}finally{$sha.Dispose()}
}
function Get-ZHCharacterFingerprint([string]$CharacterId,[object[]]$Files) {
    $lines=[string[]]@($Files|ForEach-Object{$CharacterId+'/'+([string]$_.Name).ToLowerInvariant()+'='+([string]$_.Sha256).ToUpperInvariant()})
    [Array]::Sort($lines,[StringComparer]::Ordinal)
    Get-ZHTextHash ($lines-join "`n")
}
function Get-ZHCharacterFolder([string]$Id) {
    if($Id-notin $script:CharacterIds){throw '未知角色，未访问文件。'}
    if($Id-eq 'player'){return $script:PluginRelative}
    return ($script:PluginRelative+'\Characters\'+$Id)
}
function Test-ZHMultiPackage([string]$PackageRoot) {
    $file=Get-ZHChild $PackageRoot 'VariantCatalog.json';Assert-ZHNoLink $file
    if(-not(Test-Path -LiteralPath $file -PathType Leaf)){return $false}
    $data=Get-Content -LiteralPath $file -Raw -Encoding UTF8|ConvertFrom-Json
    return ($data.SchemaVersion-eq 2)
}
function Read-ZHCharacterCatalog([string]$PackageRoot) {
    $root=Get-ZHCanonical $PackageRoot;$path=Get-ZHChild $root 'VariantCatalog.json';Assert-ZHNoLink $path
    $catalog=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
    if($catalog.SchemaVersion-ne 2 -or $catalog.PackageVersion-ne '2.2.3' -or $catalog.RuntimeProtocol-ne 2 -or $catalog.PackageReady-isnot [bool] -or $catalog.DefaultCharacterId-ne 'player' -or $catalog.FingerprintAlgorithm-ne 'SHA256-character-path-hash-lines-ordinal-v1' -or @($catalog.Characters).Count-ne $script:CharacterIds.Count){throw '多角色目录协议无效，请重新完整解压正式安装包。'}
    $ids=@{};$sources=@{}
    foreach($character in @($catalog.Characters)){
        if($character.Id-notin $script:CharacterIds -or $ids.ContainsKey($character.Id) -or $character.RuntimeBindingId-ne $character.Id -or [string]::IsNullOrWhiteSpace($character.DisplayName)){throw '角色目录包含未知、重复或不匹配的身份。'}
        $ids[$character.Id]=$true;$variants=@{};$originals=0
        $layoutExpected=if($character.Id-eq 'player'){'BepInEx/plugins/ZhaoHuoNatural/portrait-layout.tsv'}else{'Characters/'+$character.Id+'/portrait-layout.tsv'}
        if($character.LayoutSourcePath-cne $layoutExpected){throw '角色布局来源越界或混用。'}
        Assert-ZHNoLink (Get-ZHChild $root $character.LayoutSourcePath)
        foreach($variant in @($character.Variants)){
            if($variant.Id-notmatch '^[a-z][a-z0-9-]{0,47}$' -or $variants.ContainsKey($variant.Id) -or [string]::IsNullOrWhiteSpace($variant.DisplayName) -or [string]::IsNullOrWhiteSpace($variant.Description) -or $variant.Ready-isnot [bool]){throw '角色外观名称、状态或 ID 无效。'}
            $variants[$variant.Id]=$true
            if($variant.Id-eq 'original'){
                $originals++
                if($variant.Kind-ne 'original' -or-not $variant.Ready -or $variant.SourcePath -or $variant.PreviewPath -or @($variant.Files).Count -or @($variant.OriginalFallback).Count -or $variant.AssetFingerprint){throw '原版选项不能携带替换文件。'}
                continue
            }
            if($variant.Kind-ne 'custom'){throw '未知外观类型。'}
            $expected='Variants/'+$character.Id+'/'+$variant.Id+'/Portraits'
            if($character.Id-eq 'player'){
                if($variant.Id-eq 'natural'){$expected='BepInEx/plugins/ZhaoHuoNatural/Portraits'}
                elseif($variant.Id-in @('handsome','xianxia')){$expected='Variants/'+$variant.Id+'/Portraits'}
            }
            if($variant.SourcePath-cne $expected -or $variant.PreviewPath-cne ($expected+'/normal.png') -or $sources.ContainsKey($expected)){throw '外观图片路径越界、重复或跨角色混用。'}
            $sources[$expected]=$true;Assert-ZHNoLink (Get-ZHChild $root $expected);Assert-ZHNoLink (Get-ZHChild $root $variant.PreviewPath)
            $names=@{}
            foreach($file in @($variant.Files)){
                if($file.Name-cnotmatch '^[a-z0-9_]+\.png$' -or [IO.Path]::GetFileNameWithoutExtension($file.Name)-notin $script:CharacterAssets[$character.Id] -or $names.ContainsKey($file.Name) -or $file.Sha256-notmatch '^[0-9A-Fa-f]{64}$'){throw '角色图片清单含未知名称、重复文件或无效哈希。'}
                $names[$file.Name]=$true
            }
            $fallback=@{}
            foreach($name in @($variant.OriginalFallback)){
                if($name-notin $script:CharacterAssets[$character.Id] -or $fallback.ContainsKey($name) -or $names.ContainsKey($name+'.png')){throw '原图回退清单与替换清单冲突。'}
                $fallback[$name]=$true
            }
            if($variant.Ready){
                if(-not $names.ContainsKey('normal.png') -or $names.Count+$fallback.Count-ne $script:CharacterAssets[$character.Id].Count -or ($character.Id-eq 'player' -and $fallback.Count) -or $variant.AssetFingerprint-ne (Get-ZHCharacterFingerprint $character.Id @($variant.Files))){throw '已就绪外观缺少完整资源声明或指纹不匹配。'}
                if($character.LayoutSha256-notmatch '^[0-9A-Fa-f]{64}$'){throw '已就绪角色缺少布局哈希。'}
            } elseif($catalog.PackageReady){throw '正式可安装包包含尚未就绪的外观。'}
        }
        if($originals-ne 1 -or $variants.Count-lt 2){throw '每个角色必须包含一个原版选项及至少一个自定义外观。'}
    }
    $shared=@{}
    foreach($file in @($catalog.SharedFiles)){
        if($file.Name-notin @('ZhaoHuoNatural.dll','portrait-map.txt','portrait-layout.tsv') -or $shared.ContainsKey($file.Name)){throw '共享插件文件清单无效。'}
        if($catalog.PackageReady -and $file.Sha256-notmatch '^[0-9A-Fa-f]{64}$'){throw '正式包缺少共享插件哈希。'}
        if($catalog.PackageReady -and $file.Sha256-ne $script:CharacterSharedHashes[$file.Name]){throw '共享运行组件不是此管理器认可的版本，不能仅修改目录哈希来替换 DLL。'}
        $shared[$file.Name]=$true
    }
    if($shared.Count-ne 3){throw '共享插件文件不完整。'}
    return $catalog
}
function Get-PortraitCharacters {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$PackageRoot)
    $catalog=Read-ZHCharacterCatalog $PackageRoot
    [pscustomobject]@{SchemaVersion=2;PackageVersion=$catalog.PackageVersion;PackageReady=$catalog.PackageReady;DefaultCharacterId=$catalog.DefaultCharacterId;Characters=@(foreach($character in $catalog.Characters){
        [pscustomobject]@{Id=$character.Id;DisplayName=$character.DisplayName;Variants=@(foreach($variant in $character.Variants){
            [pscustomobject]@{Id=$variant.Id;Kind=$variant.Kind;DisplayName=$variant.DisplayName;Description=$variant.Description;PreviewPath=$variant.PreviewPath;Ready=$variant.Ready;Available=($catalog.PackageReady -and $variant.Ready);AssetCount=@($variant.Files).Count;UnavailableReason=$(if(-not $catalog.PackageReady){'开发准备包，图片或运行组件尚未全部冻结，不能安装。'}elseif(-not $variant.Ready){'该外观尚未准备完成。'}else{$null})}
        })}
    })}
}
function Get-ZHCharacterAssetActions([string]$PackageRoot,[object]$Character,[object]$Variant) {
    if($Variant.Kind-eq 'original'){return @()}
    if(-not $Variant.Ready){throw '所选外观尚未全部准备完成。'}
    $source=Get-ZHChild $PackageRoot $Variant.SourcePath
    $actual=@(Get-ZHFiles $source)
    if($actual.Count-ne @($Variant.Files).Count){throw '所选外观目录包含缺失或未登记文件。'}
    foreach($file in $Variant.Files){
        $path=Get-ZHChild $source $file.Name
        if(-not(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-ZHHash $path)-ne $file.Sha256){throw ('外观图片缺失或校验失败：'+$Character.Id+'/'+$file.Name)}
        [pscustomobject]@{RelativePath=((Get-ZHCharacterFolder $Character.Id)+'\Portraits\'+$file.Name);Source=$path;Content=$null;Sha256=$file.Sha256;NewPresent=$true;Category='CharacterPortrait';CharacterId=$Character.Id}
    }
    if($Character.Id-ne 'player'){
        $layout=Get-ZHChild $PackageRoot $Character.LayoutSourcePath
        if(-not(Test-Path -LiteralPath $layout -PathType Leaf) -or (Get-ZHHash $layout)-ne $Character.LayoutSha256){throw '角色布局缺失或校验失败。'}
        $rows=@(Import-Csv -LiteralPath $layout -Delimiter "`t" -Encoding UTF8);$seen=@{}
        foreach($row in $rows){
            if($row.expression-notin $script:CharacterAssets[$Character.Id] -or $seen.ContainsKey($row.expression)){throw '角色布局含未知或重复表情。'};$seen[$row.expression]=$true
            foreach($field in @('canvasWidth','canvasHeight','x','y','width','height')){if($row.$field-notmatch '^\d+$'){throw '角色布局坐标不是非负整数。'}}
            if([int]$row.canvasWidth-le 0 -or [int]$row.canvasHeight-le 0 -or [int]$row.width-le 0 -or [int]$row.height-le 0 -or [int]$row.x+[int]$row.width-gt [int]$row.canvasWidth -or [int]$row.y+[int]$row.height-gt [int]$row.canvasHeight){throw '角色布局坐标超出画布。'}
        }
        foreach($file in $Variant.Files){if(-not $seen.ContainsKey([IO.Path]::GetFileNameWithoutExtension($file.Name))){throw '所选角色图片没有对应布局。'}}
        [pscustomobject]@{RelativePath=((Get-ZHCharacterFolder $Character.Id)+'\portrait-layout.tsv');Source=$layout;Content=$null;Sha256=$Character.LayoutSha256;NewPresent=$true;Category='CharacterMetadata';CharacterId=$Character.Id}
    }
}
