#requires -Version 5.1
# Frozen release inventories, separate from editable catalog readiness and hashes.
$releaseVersion='2.2.4'
$releaseRuntimeVersion='2.1.0'
$releaseArtworkPatchPath='scripts/artwork-patch-v2.2.1.json'
$releaseArtworkPatch=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'artwork-patch-v2.2.1.json') -Raw -Encoding UTF8|ConvertFrom-Json
$releaseGameBuildId='26237817'
$releaseGameVersion='release_1.0.6001.0'
$releaseRoleIds=@('player','tang-buyi','xiahou-lan','tang-moling','long-xiang','yu-xiaomei','tang-zheng')
$releasePortraitCount=447;$releaseCustomCount=14;$releaseChoiceCount=21
$releaseCounts=@{
    'player/natural'=47;'player/handsome'=47;'player/xianxia'=47
    'player/hardman'=47;'player/white'=47;'player/black'=47;'player/veteran'=47
    'tang-buyi/refined'=15;'xiahou-lan/refined'=15
    'tang-buyi/female'=15;'tang-moling/refined'=15;'long-xiang/refined'=21;'yu-xiaomei/refined'=25;'tang-zheng/female'=12
}
$releaseFallbacks=@{
    player=@();'tang-buyi'=@('hand');'xiahou-lan'=@('white');'tang-moling'=@('one_hand')
    'long-xiang'=@('black');'yu-xiaomei'=@('black','special5','special5_2');'tang-zheng'=@()
}
$frozenV20Fingerprints=@{
    'player/natural'='7E3062599926AC9266A7F5CCA3C9B073E5B66FBBA3205B8FED7A8DA3B21E2A71'
    'player/handsome'='63434840DC201BA14765C38AE8996674A07CF64E76518A7E3A85D55F59443D05'
    'player/xianxia'='E8EB408F31283581605425055AD742753C3E76D7C2D78065473117CB19794DBA'
    'player/white'='D73A135D523F3D71894AC0B2BC8C560FD1D55279C06203506177F9205537D804'
    'player/black'='283C31F74579B8E13AFD2803AA23121110E2D2F84F5900E0608E87C2F4E59824'
    'player/veteran'='56F870EC73F6D5A83A192B54FAFDE4A8E020BAD55C9056E99C2A117A3E11347D'
    'tang-buyi/refined'='C0F88BDF7A033C08519910BA44F8FF2643B6325C1B6EB985E391139D89038C68'
    'xiahou-lan/refined'='DDA8E47B85FAD60AB97B6A3FD9617062A4D08F84F5D1F81D84E9F1625E0DF282'
}
$frozenV21Fingerprints=@{
    'player/natural'='7E3062599926AC9266A7F5CCA3C9B073E5B66FBBA3205B8FED7A8DA3B21E2A71'
    'player/handsome'='63434840DC201BA14765C38AE8996674A07CF64E76518A7E3A85D55F59443D05'
    'player/xianxia'='E8EB408F31283581605425055AD742753C3E76D7C2D78065473117CB19794DBA'
    'player/white'='D73A135D523F3D71894AC0B2BC8C560FD1D55279C06203506177F9205537D804'
    'player/black'='283C31F74579B8E13AFD2803AA23121110E2D2F84F5900E0608E87C2F4E59824'
    'player/veteran'='56F870EC73F6D5A83A192B54FAFDE4A8E020BAD55C9056E99C2A117A3E11347D'
    'tang-buyi/refined'='C0F88BDF7A033C08519910BA44F8FF2643B6325C1B6EB985E391139D89038C68'
    'tang-buyi/female'='3DE6E1944779A6DFADEA26A8631CECFD09FE29D750F97A4AEFF39FF82BF003A8'
    'xiahou-lan/refined'='DDA8E47B85FAD60AB97B6A3FD9617062A4D08F84F5D1F81D84E9F1625E0DF282'
    'tang-moling/refined'='14A2135E12355E2573DB89C04E2E70624C9601D00279FAD5F984CD39E8909439'
    'long-xiang/refined'='6C8C80E689B18BF53B08BC7C361C03F1DE4CFDE2079EF4310CD0E0CA075E022E'
    'yu-xiaomei/refined'='FF0EE32DD3B0EE440BAAD042CCC409B31FD40B99DF2B6A63CB3D137973132E8E'
    'tang-zheng/female'='311251159B1B6D6D46324D686EC3FDF5314906318A2904203DD24818FEE944ED'
}
$releasePromptGroups=@(
    [pscustomobject]@{Path='Prompts/hardman/index.json';Count=47;Variants=@('player/hardman')},
    [pscustomobject]@{Path='Prompts/multichar/index.json';Count=171;Variants=@('player/white','player/black','player/veteran','tang-buyi/refined','xiahou-lan/refined')},
    [pscustomobject]@{Path='Prompts/expansion-v2.1/index.json';Count=88;Variants=@('tang-buyi/female','tang-moling/refined','long-xiang/refined','yu-xiaomei/refined','tang-zheng/female');HistoricalVariants=@('tang-buyi/female')},
    [pscustomobject]@{Path='Prompts/hand-fix-v2.2.1/index.json';Count=15;Variants=@('tang-buyi/female')}
)
$releaseFrozenFingerprints=@{}
foreach($key in $frozenV21Fingerprints.Keys){if($key-ne 'tang-buyi/female'){$releaseFrozenFingerprints[$key]=$frozenV21Fingerprints[$key]}}
$releaseFrozenFingerprints['player/hardman']='0D768B89EF22EFC38EA9CCE994120EFC77FFDD3A762DBD2FB2F1745CEF4A7A5E'
function Assert-ReleaseArtworkRevision([string]$Key,[object]$Variant){
    if($Key-ne 'tang-buyi/female'){
        if(-not $releaseFrozenFingerprints.ContainsKey($Key)-or $Variant.AssetFingerprint-ne $releaseFrozenFingerprints[$Key]){throw ('Previously released v2.2 artwork changed: '+$Key)}
        return
    }
    $patch=$releaseArtworkPatch
    if($patch.SchemaVersion-ne 1-or $patch.FromPackageVersion-ne '2.2.0'-or $patch.ToPackageVersion-ne '2.2.1'-or $patch.CharacterId-ne 'tang-buyi'-or $patch.VariantId-ne 'female'-or $patch.PortraitCount-ne 15-or $patch.BeforeFingerprint-ne $frozenV21Fingerprints[$Key]-or $patch.AfterFingerprint-notmatch '^[0-9A-F]{64}$'-or $Variant.AssetFingerprint-ne $patch.AfterFingerprint-or $patch.AfterFingerprint-eq $patch.BeforeFingerprint){throw 'Final approved fifteen-portrait patch fingerprint is missing or differs.'}
    if(@($patch.BeforeFiles).Count-ne 15-or @($Variant.Files).Count-ne 15){throw 'Patch inventory must contain exactly fifteen old and new portraits.'}
    $lines=[string[]]@($patch.BeforeFiles|ForEach-Object{'tang-buyi/'+([string]$_.Name).ToLowerInvariant()+'='+([string]$_.Sha256).ToUpperInvariant()});[Array]::Sort($lines,[StringComparer]::Ordinal)
    $sha=[Security.Cryptography.SHA256]::Create();try{$before=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines-join "`n"))))).Replace('-','')}finally{$sha.Dispose()}
    if($before-ne $patch.BeforeFingerprint){throw 'Published pre-repair file list differs from its complete fingerprint.'}
    $seen=@{}
    foreach($entry in $patch.BeforeFiles){
        $current=@($Variant.Files|Where-Object Name -eq $entry.Name)
        if($seen.ContainsKey($entry.Name)-or $entry.Sha256-notmatch '^[0-9A-F]{64}$'-or $current.Count-ne 1-or $current[0].Sha256-eq $entry.Sha256){throw ('Every declared female portrait must be repaired exactly once: '+$entry.Name)}
        $seen[$entry.Name]=$true
    }
}
function Get-ReleasePromptExpectation([object]$Group,[string]$Key,[string]$Name,[string]$CurrentHash){
    $historical=$Group.PSObject.Properties['HistoricalVariants']-and $Key-in @($Group.HistoricalVariants)
    if($historical){
        $entry=@($releaseArtworkPatch.BeforeFiles|Where-Object Name -eq $Name)
        if($Key-ne 'tang-buyi/female'-or $entry.Count-ne 1){throw 'Unknown superseded prompt/image identity.'}
        return [pscustomobject]@{Identity=('historical-v2.1/'+$Key+'/'+$Name);Sha256=$entry[0].Sha256;Historical=$true}
    }
    return [pscustomobject]@{Identity=($Key+'/'+$Name);Sha256=$CurrentHash;Historical=$false}
}
