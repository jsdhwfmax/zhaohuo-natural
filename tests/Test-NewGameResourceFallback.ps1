#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PackageRoot,
    [Parameter(Mandatory=$true)][string]$ReportPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if (-not $PackageRoot) { $PackageRoot = Split-Path -Parent $PSScriptRoot }
$source = Get-Content -LiteralPath (Join-Path $PackageRoot 'Source/CharacterPolicy.cs') -Raw -Encoding UTF8
$wrapper = @'
namespace ZhaoHuoNatural {
    public static class NewGameFallbackProbe {
        public static bool[] Run() {
            string name = "\u5d06\u5cd2_\u5c0f\u6885";
            string root = "assets/__project/images/characters/girl5_\u5c0f\u6885/";
            return new[] {
                CharacterPolicy.RoleForIdentity("girl5", name) == "yu-xiaomei",
                CharacterPolicy.ExpressionForIdentityAsset("girl5", name, root + "doubt.png") == null,
                CharacterPolicy.ExpressionForIdentityAsset("girl5", name, (root + "doubt.png").ToUpperInvariant()) == null,
                !CharacterPolicy.AllowsExpression("yu-xiaomei", "doubt"),
                CharacterPolicy.ExpressionForAsset("yu-xiaomei", root + "doubt.png") == null,
                CharacterPolicy.ExpressionForIdentityAsset("girl5", name, root + "normal.png") == "normal",
                CharacterPolicy.AllowsExpression("yu-xiaomei", "normal"),
                CharacterPolicy.ExpressionForIdentityAsset("girl5", name, "assets/__project/images/characters/player_\u4e3b\u89d2/doubt.png") == null,
                !CharacterPolicy.AllowsExpression("yu-xiaomei", "black"),
                !CharacterPolicy.AllowsExpression("yu-xiaomei", "special5"),
                !CharacterPolicy.AllowsExpression("yu-xiaomei", "special5_2")
            };
        }
    }
}
'@
Add-Type -TypeDefinition ($source + [Environment]::NewLine + $wrapper) -Language CSharp
$names = @(
    'Exact adult Yu identity remains supported',
    'New doubt canonical is outside identity whitelist',
    'Case normalization cannot admit new doubt',
    'New doubt expression is not replaceable',
    'Role-only canonical lookup also rejects doubt',
    'Existing normal canonical remains supported',
    'Existing normal expression stays replaceable',
    'Player doubt cannot cross into Yu role',
    'Black silhouette still original',
    'Composite special5 still original',
    'Composite special5_2 still original'
)
$values = [ZhaoHuoNatural.NewGameFallbackProbe]::Run()
$tests = @(for ($i=0; $i -lt $names.Count; $i++) { [pscustomobject]@{Name=$names[$i]; Passed=$values[$i]} })
function Get-NormalizedHash([string]$Path) {
    $text = [IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF).Replace(([string][char]13+[char]10),[string][char]10)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','') }
    finally { $sha.Dispose() }
}
$codePaths = @('Source/CharacterPolicy.cs','tests/Test-NewGameResourceFallback.ps1')
$codeHashes = @(foreach ($relative in $codePaths) { [pscustomobject]@{Path=$relative; Sha256=(Get-NormalizedHash (Join-Path $PackageRoot $relative))} })
$passed = @($tests | Where-Object {-not $_.Passed}).Count -eq 0
$report = [pscustomobject][ordered]@{
    Passed = $passed
    ActualGameRun = $false
    Scope = 'Frozen production policy compiled unchanged with an isolated test wrapper. No game assembly is executed and no game process is started. The newly added Yu Xiaomei doubt resource remains original.'
    PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    PluginSha256 = (Get-FileHash -LiteralPath (Join-Path $PackageRoot 'BepInEx/plugins/ZhaoHuoNatural/ZhaoHuoNatural.dll') -Algorithm SHA256).Hash
    CodeHashAlgorithm = 'SHA256-UTF8-noBOM-LF-v1'
    CodeHashes = $codeHashes
    TestCount = $tests.Count
    Tests = $tests
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
if (-not $passed) { throw 'New resource fallback policy test failed' }
Write-Host ('PASS ' + $tests.Count + ' focused production policy checks; no game process used.')
