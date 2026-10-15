#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Install','Uninstall')][string]$InitialAction = 'Install',
    [string]$GamePath,
    [string]$PreviewPath
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
Import-Module (Join-Path $PSScriptRoot 'ZhaoHuoInstaller.psm1') -Force
$script:PackageRoot = Split-Path -Parent $PSScriptRoot
$script:Busy = $false
$form = New-Object Windows.Forms.Form
$form.Text = '赵活自然美化包 · 安装工具'
$form.ClientSize = New-Object Drawing.Size(900, 660)
$form.MinimumSize = New-Object Drawing.Size(800, 620)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10)
$form.BackColor = [Drawing.Color]::FromArgb(246, 247, 249)
$title = New-Object Windows.Forms.Label
$title.Text = '赵活自然美化包'
$title.Font = New-Object Drawing.Font('Microsoft YaHei UI', 21, [Drawing.FontStyle]::Bold)
$title.Location = New-Object Drawing.Point(26, 20)
$title.Size = New-Object Drawing.Size(700, 44)
$subtitle = New-Object Windows.Forms.Label
$subtitle.Text = '选择 Steam 游戏目录，安装后从 Steam 库正常启动。'
$subtitle.Location = New-Object Drawing.Point(29, 75)
$subtitle.Size = New-Object Drawing.Size(830, 26)
$subtitle.ForeColor = [Drawing.Color]::FromArgb(80, 87, 99)
$label = New-Object Windows.Forms.Label
$label.Text = '游戏目录（包含 Mortal.exe）'
$label.Location = New-Object Drawing.Point(29, 118)
$label.Size = New-Object Drawing.Size(500, 25)
$script:PathBox = New-Object Windows.Forms.ComboBox
$script:PathBox.Location = New-Object Drawing.Point(30, 149)
$script:PathBox.Size = New-Object Drawing.Size(714, 30)
$script:PathBox.Anchor = 'Top,Left,Right'
$script:PathBox.DropDownStyle = 'DropDown'
$browse = New-Object Windows.Forms.Button
$browse.Text = '浏览文件夹'
$browse.Location = New-Object Drawing.Point(756, 147)
$browse.Size = New-Object Drawing.Size(113, 33)
$browse.Anchor = 'Top,Right'
$install = New-Object Windows.Forms.Button
$install.Text = '安装美化包'
$install.Location = New-Object Drawing.Point(30, 204)
$install.Size = New-Object Drawing.Size(170, 43)
$install.BackColor = [Drawing.Color]::FromArgb(34, 93, 158)
$install.ForeColor = [Drawing.Color]::White
$install.FlatStyle = 'Flat'
$uninstall = New-Object Windows.Forms.Button
$uninstall.Text = '卸载并恢复'
$uninstall.Location = New-Object Drawing.Point(214, 204)
$uninstall.Size = New-Object Drawing.Size(170, 43)
$check = New-Object Windows.Forms.Button
$check.Text = '仅检查'
$check.Location = New-Object Drawing.Point(398, 204)
$check.Size = New-Object Drawing.Size(140, 43)
$tip = New-Object Windows.Forms.Label
$tip.Text = '安装前退出游戏。原文件自动备份；仅检查不会改动文件。'
$tip.Location = New-Object Drawing.Point(30, 264)
$tip.Size = New-Object Drawing.Size(830, 29)
$tip.ForeColor = [Drawing.Color]::FromArgb(80, 87, 99)
$logLabel = New-Object Windows.Forms.Label
$logLabel.Text = '执行结果'
$logLabel.Location = New-Object Drawing.Point(30, 308)
$logLabel.Size = New-Object Drawing.Size(200, 26)
$script:OutputBox = New-Object Windows.Forms.TextBox
$script:OutputBox.Location = New-Object Drawing.Point(30, 339)
$script:OutputBox.Size = New-Object Drawing.Size(840, 264)
$script:OutputBox.Anchor = 'Top,Bottom,Left,Right'
$script:OutputBox.Multiline = $true
$script:OutputBox.ReadOnly = $true
$script:OutputBox.ScrollBars = 'Both'
$script:OutputBox.WordWrap = $false
$script:OutputBox.BackColor = [Drawing.Color]::White
$script:OutputBox.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
$script:Status = New-Object Windows.Forms.Label
$script:Status.Text = '就绪'
$script:Status.Location = New-Object Drawing.Point(30, 620)
$script:Status.Size = New-Object Drawing.Size(840, 25)
$script:Status.Anchor = 'Bottom,Left,Right'
$form.Controls.AddRange(@($title,$subtitle,$label,$script:PathBox,$browse,$install,$uninstall,$check,$tip,$logLabel,$script:OutputBox,$script:Status))
$script:ActionControls = @($script:PathBox,$browse,$install,$uninstall,$check)
function Add-Output([string]$Message, [string]$Level = 'Info') {
    $prefix = ''
    if ($Level -eq 'Error') { $prefix = '[错误] ' }
    if ($Level -eq 'Warning') { $prefix = '[提示] ' }
    $script:OutputBox.AppendText($prefix + $Message + [Environment]::NewLine)
    $script:OutputBox.SelectionStart = $script:OutputBox.TextLength
    $script:OutputBox.ScrollToCaret()
    [Windows.Forms.Application]::DoEvents()
}
function Invoke-Action([string]$Action) {
    if ($script:Busy) { return }
    $script:Busy = $true
    foreach ($control in $script:ActionControls) { $control.Enabled = $false }
    $script:Status.Text = '正在处理，请保留此窗口……'
    Add-Output ('----- ' + (Get-Date -Format 'HH:mm:ss') + ' -----')
    try {
        $selectedPath = $script:PathBox.Text.Trim().Trim('"')
        if ([string]::IsNullOrWhiteSpace($selectedPath)) { throw '请从下拉列表选择游戏目录，或点击“浏览文件夹”。' }
        $logger = { param($Message,$Level) Add-Output $Message $Level }
        if ($Action -eq 'Uninstall') { Uninstall-ZhaoHuo -GamePath $selectedPath -Log $logger | Out-Null }
        else { Install-ZhaoHuo -GamePath $selectedPath -PackageRoot $script:PackageRoot -CheckOnly:($Action -eq 'Check') -Log $logger | Out-Null }
        $script:Status.Text = '操作完成，请查看上方结果。'
    } catch {
        Add-Output $_.Exception.ToString() 'Error'
        if ($_.ScriptStackTrace) { Add-Output $_.ScriptStackTrace 'Error' }
        $script:Status.Text = '操作未完成。错误详情已完整保留在上方，可选中复制。'
    } finally {
        $script:Busy = $false
        foreach ($control in $script:ActionControls) { $control.Enabled = $true }
    }
}
$browse.Add_Click({
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    $dialog.Description = '请选择 Steam 中活侠传的本地文件目录（包含 Mortal.exe）。'
    $dialog.ShowNewFolderButton = $false
    if (Test-Path -LiteralPath $script:PathBox.Text -PathType Container) { $dialog.SelectedPath = $script:PathBox.Text }
    if ($dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) { $script:PathBox.Text = $dialog.SelectedPath }
    $dialog.Dispose()
})
$install.Add_Click({ Invoke-Action 'Install' })
$uninstall.Add_Click({ Invoke-Action 'Uninstall' })
$check.Add_Click({ Invoke-Action 'Check' })
$form.Add_FormClosing({ param($sender,$eventArgs) if ($script:Busy) { $eventArgs.Cancel = $true; $script:Status.Text = '正在写入或回滚文件，请等操作完成后再关闭。' } })
try {
    $candidates = @(Get-ZhaoHuoSteamCandidates)
    foreach ($candidate in $candidates) { [void]$script:PathBox.Items.Add($candidate) }
    if ($GamePath) { $script:PathBox.Text = $GamePath }
    elseif ($candidates.Count -eq 1) { $script:PathBox.SelectedIndex = 0 }
    elseif ($candidates.Count -gt 1) { Add-Output "找到 $($candidates.Count) 个游戏目录，请从下拉列表选择本次要处理的位置。" }
    else { Add-Output '未自动找到活侠传，请点击“浏览文件夹”选择本地游戏目录。' }
    if ($candidates.Count -eq 1) { Add-Output '已自动识别 Steam 游戏目录。可以先点击“仅检查”。' }
    Add-Output '本工具使用包内离线依赖，不会下载运行库，也不会修改存档。'
    if ($InitialAction -eq 'Uninstall') { $form.ActiveControl = $uninstall } else { $form.ActiveControl = $check }
    if ($PreviewPath) {
        $preview = [IO.Path]::GetFullPath($PreviewPath)
        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($preview)) -Force | Out-Null
        $form.ShowInTaskbar = $false
        $form.StartPosition = 'Manual'
        $form.Location = New-Object Drawing.Point(-20000,-20000)
        $form.Show()
        [Windows.Forms.Application]::DoEvents()
        $form.PerformLayout()
        $bitmap = New-Object Drawing.Bitmap($form.Width,$form.Height)
        try { $form.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height))); $bitmap.Save($preview,[Drawing.Imaging.ImageFormat]::Png) }
        finally { $bitmap.Dispose(); $form.Close() }
        Write-Output 'GUI preview saved; no installation action was executed.'
    } else { [void]$form.ShowDialog() }
} finally { $form.Dispose() }
