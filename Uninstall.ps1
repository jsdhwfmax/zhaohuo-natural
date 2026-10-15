#requires -Version 5.1
[CmdletBinding()]
param([string]$GamePath, [switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'installer\ZhaoHuoInstaller.psm1') -Force
if ([string]::IsNullOrWhiteSpace($GamePath)) {
    $candidates = @(Get-ZhaoHuoSteamCandidates)
    if ($candidates.Count -ne 1) { throw '未能唯一确定游戏目录。请双击 Uninstall.cmd 在窗口中选择，或使用 -GamePath 指定。' }
    $GamePath = $candidates[0]
}
Uninstall-ZhaoHuo -GamePath $GamePath -CheckOnly:$CheckOnly | Out-Null
