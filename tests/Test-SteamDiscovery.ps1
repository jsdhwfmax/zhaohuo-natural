#requires -Version 5.1
[CmdletBinding()]
param([string]$OutputPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent $PSScriptRoot
if (-not $OutputPath) { $OutputPath = Join-Path $repo 'verification/steam-discovery-tests.json' }
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($OutputPath)) | Out-Null
function Get-CodeHash([string]$Path) {
    $text = [IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF).Replace("`r`n", "`n").Replace("`r", "`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-', '') }
    finally { $sha.Dispose() }
}
$codeHashes = @(foreach ($path in @('installer/ZhaoHuoInstaller.psm1', 'tests/Test-SteamDiscovery.ps1')) {
    [pscustomobject]@{ Path = $path; Sha256 = Get-CodeHash (Join-Path $repo $path) }
})
$module = Import-Module (Join-Path $repo 'installer/ZhaoHuoInstaller.psm1') -Force -PassThru
$work = Join-Path $PSScriptRoot ('.work/steam-discovery-' + [Guid]::NewGuid().ToString('N'))
$checks = New-Object 'System.Collections.Generic.List[string]'
$start = [DateTime]::UtcNow
$originalProgramFiles = $env:ProgramFiles
$originalProgramFilesX86 = ${env:ProgramFiles(x86)}
$locks = New-Object 'System.Collections.Generic.List[IDisposable]'
function Check([string]$Name, [bool]$Passed) {
    if (-not $Passed) { throw "FAIL: $Name" }
    $checks.Add($Name)
    Write-Host ('PASS: ' + $Name)
}
function New-Library([string]$Name, [string]$InstallDir = 'LegendOfMortal') {
    $root = Join-Path $work $Name
    $game = Join-Path $root ('steamapps/common/' + $InstallDir)
    [IO.Directory]::CreateDirectory($game) | Out-Null
    [IO.File]::WriteAllText((Join-Path $game 'Mortal.exe'), 'discovery fixture; never executed')
    return $root
}
function Assert-Candidates([string]$Name, [string[]]$Roots, [string[]]$Expected) {
    $actual = @(Get-ZhaoHuoSteamCandidates -SteamRoots $Roots)
    $expectedSorted = @($Expected | Sort-Object -Unique)
    Check $Name (($actual.Count -eq $expectedSorted.Count) -and (($actual -join "`n") -ceq ($expectedSorted -join "`n")))
}
function Game-In([string]$Library, [string]$InstallDir = 'LegendOfMortal') { Join-Path $Library ('steamapps/common/' + $InstallDir) }
try {
    $first = New-Library 'Steam A'
    $second = New-Library 'Steam [B] 中文'
    $firstGame = Game-In $first
    $secondGame = Game-In $second
    foreach ($case in @(
        @{Name = 'pipe'; Path = 'C:\bad|path'},
        @{Name = 'quote'; Path = '"C:\bad"'},
        @{Name = 'NUL'; Path = ('C:\bad' + [char]0 + 'path')},
        @{Name = 'newline'; Path = ('C:\bad' + [char]10 + 'path')},
        @{Name = 'invalid colon'; Path = 'C::\bad'},
        @{Name = 'whitespace'; Path = '   '},
        @{Name = 'missing directory'; Path = (Join-Path $work 'does not exist')}
    )) {
        Assert-Candidates ('Bad root is isolated: ' + $case.Name) @($case.Path, $first, $case.Path, $second) @($firstGame, $secondGame)
    }
    Assert-Candidates 'Null and empty roots do not suppress valid candidates' @($null, '', $first) @($firstGame)
    Assert-Candidates 'All malformed roots return no candidates' @('C:\bad|path', '"C:\bad"', '   ') @()
    Assert-Candidates 'Canonical duplicates return one literal Unicode/bracket path' @($second, ($second + '\'), ($second + '\.')) @($secondGame)

    $vdf = Join-Path $first 'steamapps/libraryfolders.vdf'
    $escapedSecond = $second.Replace('\', '\\')
    [IO.File]::WriteAllText($vdf, ('"libraryfolders" { "0" { "path" "C:\bad|path" } "1" { "path" "' + $escapedSecond + '" } "2" "relative\library" }'))
    Assert-Candidates 'Modern VDF keeps valid library after malformed and relative entries' @($first) @($firstGame, $secondGame)
    [IO.File]::WriteAllText($vdf, ('"libraryfolders" { "1" "' + $escapedSecond + '" "2" "C:\bad' + [char]0 + 'path" }'))
    Assert-Candidates 'Legacy VDF keeps valid library before an embedded NUL entry' @($first) @($firstGame, $secondGame)

    $vdfLock = [IO.File]::Open($vdf, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    $locks.Add($vdfLock)
    Assert-Candidates 'Unreadable optional VDF preserves its root and other roots' @($first, $second) @($firstGame, $secondGame)
    $vdfLock.Dispose()

    $custom = New-Library 'Custom Steam' '活侠传 [custom]'
    $customAcf = Join-Path $custom 'steamapps/appmanifest_1859910.acf'
    [IO.File]::WriteAllText($customAcf, '"AppState" { "installdir" "活侠传 [custom]" }')
    Assert-Candidates 'Manifest custom Unicode installation directory remains supported' @($custom) @((Game-In $custom '活侠传 [custom]'))
    [IO.File]::WriteAllText($customAcf, '"AppState" { "installdir" "..\outside" }')
    Assert-Candidates 'Unsafe manifest path is skipped without suppressing another library' @($custom, $second) @($secondGame)
    [IO.File]::WriteAllText($customAcf, '"AppState" { "installdir" "bad|directory" }')
    Assert-Candidates 'Illegal manifest directory is skipped without suppressing another library' @($custom, $second) @($secondGame)
    $acfLock = [IO.File]::Open($customAcf, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    $locks.Add($acfLock)
    Assert-Candidates 'Unreadable manifest does not prevent other library discovery' @($custom, $second) @($secondGame)
    $acfLock.Dispose()

    # Intercept only registry reads in this imported module; never alter the user's registry.
    & $module {
        function script:Get-ItemProperty {
            [CmdletBinding()] param([string]$LiteralPath)
            if ($LiteralPath -eq 'HKCU:\Software\Valve\Steam') { return [pscustomobject]@{ SteamPath = 'C:\bad|path'; InstallPath = $script:DiscoveryRegistryRoot } }
            if ($LiteralPath -eq 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam') { throw [UnauthorizedAccessException]::new('fixture denied registry key') }
            return $null
        }
    }
    & $module { param($path) $script:DiscoveryRegistryRoot = $path } $second
    $env:ProgramFiles = 'C:\bad|programs'
    ${env:ProgramFiles(x86)} = '"C:\bad programs"'
    Assert-Candidates 'Bad registry and environment candidates preserve a valid registry installation' @() @($secondGame)
    $programParent = Join-Path $work 'Program Files 中文'
    $programSteam = New-Library 'Program Files 中文/Steam'
    $env:ProgramFiles = $programParent
    ${env:ProgramFiles(x86)} = 'C:\bad|programs'
    & $module { $script:DiscoveryRegistryRoot = 'C:\bad|registry' }
    Assert-Candidates 'Valid Program Files fallback survives corrupt registry values' @() @((Game-In $programSteam))

    # Explicit game paths still use the strict shared helpers; discovery is the only tolerant boundary.
    Check 'Explicit valid game path is unchanged' ((& $module { param($path) (Get-ZHLocations $path).Game } $secondGame) -ceq $secondGame)
    $rejected = $false
    try { $null = & $module { Get-ZHLocations 'C:\bad|game' } } catch { $rejected = $true }
    Check 'Explicit malformed game path is still rejected' $rejected
    $rejected = $false
    try { $null = & $module { param($path) Get-ZHChild $path '..\outside' } $first } catch { $rejected = $true }
    Check 'Containment checks still reject traversal' $rejected

    foreach ($entry in $codeHashes) { Check ('Tested source unchanged: ' + $entry.Path) ((Get-CodeHash (Join-Path $repo $entry.Path)) -ceq $entry.Sha256) }
    $report = [ordered]@{ Passed = $true; TestsPassed = $checks.Count; PowerShellVersion = $PSVersionTable.PSVersion.ToString(); CodeHashAlgorithm = 'SHA256-UTF8-noBOM-LF-v1'; CodeHashes = $codeHashes; Scope = 'Isolated Steam discovery fixtures and explicit-path rejection; no actual registry, game installation, or game execution'; DurationSeconds = [Math]::Round(([DateTime]::UtcNow - $start).TotalSeconds, 2); Assertions = @($checks.ToArray()) }
    [IO.File]::WriteAllText($OutputPath, ($report | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    Write-Host ('ALL ' + $checks.Count + ' ASSERTIONS PASSED')
} catch {
    $failure = [ordered]@{ Passed = $false; PowerShellVersion = $PSVersionTable.PSVersion.ToString(); TestsPassed = $checks.Count; Error = $_.Exception.Message; CodeHashAlgorithm = 'SHA256-UTF8-noBOM-LF-v1'; CodeHashes = $codeHashes }
    [IO.File]::WriteAllText($OutputPath, ($failure | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    throw
} finally {
    foreach ($fileLock in $locks) { $fileLock.Dispose() }
    $env:ProgramFiles = $originalProgramFiles
    ${env:ProgramFiles(x86)} = $originalProgramFilesX86
    Remove-Module $module -Force
}
