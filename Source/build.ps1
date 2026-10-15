param(
    [Parameter(Mandatory=$true)][string]$GamePath,
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\BepInEx\plugins\ZhaoHuoNatural')
)
$ErrorActionPreference = 'Stop'
$sdkLine = @(& dotnet --list-sdks) | Select-Object -Last 1
if (-not $sdkLine -or $sdkLine -notmatch '^([^ ]+) \[(.+)\]$') { throw 'A .NET SDK is required to rebuild. Installing the supplied package does not require it.' }
$compiler = Join-Path (Join-Path $Matches[2] $Matches[1]) 'Roslyn\bincore\csc.dll'
if (-not (Test-Path -LiteralPath $compiler)) { throw 'Could not locate the .NET SDK C# compiler.' }
$managed = Join-Path $GamePath 'Mortal_Data\Managed'
$bep = Join-Path $GamePath 'BepInEx\core'
$refs = @(
    'mscorlib','System','System.Core','netstandard','UnityEngine','UnityEngine.CoreModule',
    'UnityEngine.UI','UnityEngine.UIModule','UnityEngine.ImageConversionModule',
    'UnityEngine.TextRenderingModule','UnityEngine.ScreenCaptureModule',
    'Unity.Addressables','Unity.ResourceManager','Mortal.Core','Mortal.Story','Fungus','OBB.Framework'
)
$argsFile = Join-Path ([IO.Path]::GetTempPath()) ('zhaohuo-build-' + [Guid]::NewGuid().ToString('N') + '.rsp')
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$argsLines = @('/nologo','/target:library','/optimize+','/debug:portable','/deterministic+','/nostdlib+',('/pathmap:"' + $PSScriptRoot + '=/src/ZhaoHuoNatural"'),('/out:"' + (Join-Path $OutputPath 'ZhaoHuoNatural.dll') + '"'))
foreach ($ref in $refs) { $argsLines += '/reference:"' + (Join-Path $managed ($ref + '.dll')) + '"' }
foreach ($ref in @('BepInEx.Core','BepInEx.Unity.Mono','0Harmony')) { $argsLines += '/reference:"' + (Join-Path $bep ($ref + '.dll')) + '"' }
$argsLines += '"' + (Join-Path $PSScriptRoot 'Plugin.cs') + '"'
[System.IO.File]::WriteAllLines($argsFile, $argsLines, [System.Text.UTF8Encoding]::new($false))
try {
    & dotnet $compiler ('@' + $argsFile)
    if ($LASTEXITCODE -ne 0) { throw 'Compilation failed.' }
} finally {
    if (Test-Path -LiteralPath $argsFile -PathType Leaf) { Remove-Item -LiteralPath $argsFile }
}
Get-FileHash -LiteralPath (Join-Path $OutputPath 'ZhaoHuoNatural.dll') -Algorithm SHA256
