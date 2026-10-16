#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Install','Uninstall')][string]$InitialAction = 'Install',
    [string]$GamePath,
    [string]$PreviewPath,
    [ValidateSet('Default','Compact')][string]$PreviewSize = 'Default',
    [ValidateRange(1,2)][double]$PreviewScale = 1,
    [ValidateSet('none','natural','handsome','xianxia')][string]$PreviewInstalledVariant = 'none',
    [string]$UiTestReport
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
Import-Module (Join-Path $PSScriptRoot 'ZhaoHuoInstaller.psm1') -Force
$script:PackageRoot = Split-Path -Parent $PSScriptRoot
$script:PreviewMode = [bool]($PreviewPath -or $UiTestReport)
$script:Busy = $false
$script:SelectedVariantId = 'natural'
$script:InstalledState = $null
$script:MockRequests = New-Object 'System.Collections.Generic.List[object]'
$script:TestFailNext = $false
$script:Cards = @()

# Owner-drawn Buttons retain keyboard activation and accessibility while rendering
# the package's real PNGs. This only draws previews; it never rewrites artwork.
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;
namespace ZhaoHuo.Manager {
    public static class NativeDpi {
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    }
    public sealed class VariantCard : Button {
        public string VariantId { get; set; }
        public string Heading { get; set; }
        public string Summary { get; set; }
        public bool Selected { get; set; }
        public bool Installed { get; set; }
        public float UiScale { get; set; }
        private Bitmap portrait;
        private Rectangle source;
        private bool hovered;
        public VariantCard() {
            UiScale = 1f;
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            FlatStyle = FlatStyle.Flat; FlatAppearance.BorderSize = 0;
            Cursor = Cursors.Hand; TabStop = true;
        }
        public void LoadPortrait(string path) {
            if (portrait != null) portrait.Dispose();
            using (var original = Image.FromFile(path)) portrait = new Bitmap(original);
            var bounds = new Rectangle(0, 0, portrait.Width, portrait.Height);
            var data = portrait.LockBits(bounds, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            try {
                int stride = Math.Abs(data.Stride); byte[] pixels = new byte[stride * data.Height];
                Marshal.Copy(data.Scan0, pixels, 0, pixels.Length);
                int left=portrait.Width, top=portrait.Height, right=0, bottom=0;
                for (int y=0; y<portrait.Height; y+=2) for (int x=0; x<portrait.Width; x+=2) {
                    if (pixels[y*stride+x*4+3] > 16) {
                        left=Math.Min(left,x); top=Math.Min(top,y); right=Math.Max(right,x+2); bottom=Math.Max(bottom,y+2);
                    }
                }
                if (right > left) source = new Rectangle(left,top,Math.Min(right,portrait.Width)-left,
                    Math.Min(bottom-top,(int)((right-left)*1.34f)));
                else source = bounds;
            } finally { portrait.UnlockBits(data); }
            Invalidate();
        }
        protected override void OnMouseEnter(EventArgs e) { hovered=true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hovered=false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
        protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
        protected override void OnPaint(PaintEventArgs e) {
            var g=e.Graphics; float s=UiScale;
            g.SmoothingMode=SmoothingMode.AntiAlias;
            g.InterpolationMode=InterpolationMode.HighQualityBicubic;
            Color ink=Color.FromArgb(39,51,45), green=Color.FromArgb(43,80,68);
            Color paper=Selected?Color.FromArgb(242,244,230):(hovered?Color.FromArgb(252,247,234):Color.FromArgb(249,245,235));
            g.Clear(paper);
            using(var p=new Pen(Selected?green:Color.FromArgb(211,200,177),Selected?2.5f*s:1f*s))
                g.DrawRectangle(p,p.Width/2,p.Width/2,Width-p.Width,Height-p.Width);
            float textTop=Height-100*s;
            var artArea=new RectangleF(12*s,25*s,Width-24*s,Math.Max(60*s,textTop-31*s));
            using(var b=new SolidBrush(Color.FromArgb(231,226,207)))
                g.FillEllipse(b,Width*.16f,artArea.Y+artArea.Height*.11f,Width*.68f,Math.Min(Width*.68f,artArea.Height*.82f));
            if(portrait!=null) {
                float zoom=Math.Min(artArea.Width/source.Width,artArea.Height/source.Height);
                var dest=new RectangleF((Width-source.Width*zoom)/2,artArea.Bottom-source.Height*zoom,source.Width*zoom,source.Height*zoom);
                g.DrawImage(portrait,dest,source,GraphicsUnit.Pixel);
            }
            using(var p=new Pen(Color.FromArgb(221,211,190),s))g.DrawLine(p,16*s,textTop,Width-16*s,textTop);
            using(var h=new Font("Microsoft YaHei UI",12.5f*96f/72f*s,FontStyle.Bold,GraphicsUnit.Pixel))
                TextRenderer.DrawText(g,Heading,h,new Rectangle((int)(17*s),(int)(textTop+11*s),Width-(int)(34*s),(int)(25*s)),ink,
                    TextFormatFlags.Left|TextFormatFlags.NoPadding|TextFormatFlags.EndEllipsis);
            using(var f=new Font("Microsoft YaHei UI",9.3f*96f/72f*s,FontStyle.Regular,GraphicsUnit.Pixel))
                TextRenderer.DrawText(g,Summary,f,new Rectangle((int)(17*s),(int)(textTop+43*s),Width-(int)(34*s),(int)(43*s)),Color.FromArgb(94,91,78),
                    TextFormatFlags.Left|TextFormatFlags.NoPadding|TextFormatFlags.WordBreak);
            using(var fill=new SolidBrush(Selected?green:Color.FromArgb(238,230,211)))g.FillEllipse(fill,13*s,12*s,23*s,23*s);
            using(var f=new Font("Segoe UI",11*96f/72f*s,FontStyle.Bold,GraphicsUnit.Pixel))
                TextRenderer.DrawText(g,Selected?"✓":"",f,new Rectangle((int)(13*s),(int)(11*s),(int)(23*s),(int)(24*s)),Color.White,
                    TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter|TextFormatFlags.NoPadding);
            if(Installed) {
                var badge=new Rectangle(Width-(int)(83*s),(int)(13*s),(int)(68*s),(int)(23*s));
                using(var b=new SolidBrush(green))g.FillRectangle(b,badge);
                using(var f=new Font("Microsoft YaHei UI",9*96f/72f*s,FontStyle.Bold,GraphicsUnit.Pixel))
                    TextRenderer.DrawText(g,"已安装",f,badge,Color.White,TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter|TextFormatFlags.NoPadding);
            }
            if(Focused) ControlPaint.DrawFocusRectangle(g,new Rectangle((int)(6*s),(int)(6*s),Width-(int)(12*s),Height-(int)(12*s)),green,paper);
            if(!Enabled) using(var b=new SolidBrush(Color.FromArgb(90,245,240,227)))g.FillRectangle(b,ClientRectangle);
        }
        protected override void Dispose(bool disposing) { if(disposing && portrait!=null)portrait.Dispose(); base.Dispose(disposing); }
    }
}
'@
[void][ZhaoHuo.Manager.NativeDpi]::SetProcessDPIAware()
$dpi = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
try { $script:UiScale = if ($script:PreviewMode) { $PreviewScale } else { [Math]::Max(1, $dpi.DpiX / 96.0) } } finally { $dpi.Dispose() }
function S([double]$Value) { return [int][Math]::Round($Value * $script:UiScale) }
function New-Label([string]$Text, [double]$Size = 10, [bool]$Bold = $false) {
    $label = New-Object Windows.Forms.Label
    $label.Text = $Text
    $style = if ($Bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }
    $label.Font = New-Object Drawing.Font('Microsoft YaHei UI', [single]($Size * 96 / 72 * $script:UiScale), $style, [Drawing.GraphicsUnit]::Pixel)
    $label.ForeColor = [Drawing.Color]::FromArgb(40,49,43)
    $label.AutoEllipsis = $true
    $label.Margin = New-Object Windows.Forms.Padding(0)
    return $label
}
function New-Button([string]$Text, [bool]$Primary = $false) {
    $button = New-Object Windows.Forms.Button
    $button.Text = $Text
    $button.FlatStyle = 'Flat'
    $button.Cursor = 'Hand'
    $button.BackColor = if ($Primary) { [Drawing.Color]::FromArgb(43,80,68) } else { [Drawing.Color]::FromArgb(250,247,239) }
    $button.ForeColor = if ($Primary) { [Drawing.Color]::White } else { [Drawing.Color]::FromArgb(48,61,52) }
    $button.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(181,179,158)
    $button.Font = New-Object Drawing.Font('Microsoft YaHei UI', [single](10 * 96 / 72 * $script:UiScale), [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
    return $button
}

$form = New-Object Windows.Forms.Form
$form.Text = '赵活美化管理器 · v1.3.0'
$form.AutoScaleMode = 'None'
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI', [single](10 * 96 / 72 * $script:UiScale), [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
$form.BackColor = [Drawing.Color]::FromArgb(241,236,223)
$width = if ($PreviewSize -eq 'Compact') { 900 } else { 1040 }
$height = if ($PreviewSize -eq 'Compact') { 700 } else { 830 }
if (-not $script:PreviewMode) {
    $area = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $width = [Math]::Min($width, [Math]::Max(820, ($area.Width-40)/$script:UiScale))
    $height = [Math]::Min($height, [Math]::Max(650, ($area.Height-60)/$script:UiScale))
}
$form.ClientSize = New-Object Drawing.Size((S $width),(S $height))
$form.MinimumSize = New-Object Drawing.Size((S 840),(S 670))
$layout = New-Object Windows.Forms.TableLayoutPanel
$layout.Dock = 'Fill'; $layout.ColumnCount = 1; $layout.RowCount = 7
[void]$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',[single]100)))
$layout.Padding = New-Object Windows.Forms.Padding((S 25),(S 18),(S 25),(S 16))
foreach($rowHeight in @(74,88,35,-1,110,95,20)) {
    $style = New-Object Windows.Forms.RowStyle
    if($rowHeight -lt 0) { $style.SizeType='Percent'; $style.Height=100 } else { $style.SizeType='Absolute'; $style.Height=S $rowHeight }
    [void]$layout.RowStyles.Add($style)
}
$form.Controls.Add($layout)
$header = New-Object Windows.Forms.Panel; $header.Dock='Fill'; $header.Margin=New-Object Windows.Forms.Padding(0)
$header.Size=New-Object Drawing.Size((S 990),(S 74))
$seal=New-Label "活`n侠" 12 $true; $seal.BackColor=[Drawing.Color]::FromArgb(151,62,44); $seal.ForeColor=[Drawing.Color]::FromArgb(255,246,220); $seal.TextAlign='MiddleCenter'
$seal.SetBounds(0,(S 2),(S 40),(S 52))
$title=New-Label '赵活美化管理器' 22 $true; $title.SetBounds((S 55),0,(S 600),(S 46))
$subtitle=New-Label '同一个江湖，选你喜欢的模样。' 10; $subtitle.ForeColor=[Drawing.Color]::FromArgb(104,101,87); $subtitle.SetBounds((S 58),(S 47),(S 660),(S 24))
$version=New-Label 'v1.3.0  /  离线安装' 9; $version.ForeColor=[Drawing.Color]::FromArgb(111,107,90); $version.TextAlign='TopRight'; $version.SetBounds((S 770),(S 14),(S 215),(S 22)); $version.Anchor='Top,Right'
$header.Controls.AddRange(@($seal,$title,$subtitle,$version)); $layout.Controls.Add($header,0,0)
$pathPanel=New-Object Windows.Forms.Panel; $pathPanel.Dock='Fill'; $pathPanel.Margin=New-Object Windows.Forms.Padding(0)
$pathPanel.Size=New-Object Drawing.Size((S 990),(S 88))
$pathLabel=New-Label 'Steam 游戏目录' 10 $true; $pathLabel.SetBounds(0,0,(S 250),(S 24))
$script:PathBox=New-Object Windows.Forms.ComboBox; $script:PathBox.DropDownStyle='DropDown'; $script:PathBox.SetBounds(0,(S 28),(S 855),(S 30)); $script:PathBox.Anchor='Top,Left,Right'; $script:PathBox.AccessibleName='Steam 游戏目录，包含 Mortal.exe'
$browse=New-Button '浏览文件夹'; $browse.SetBounds((S 868),(S 26),(S 122),(S 34)); $browse.Anchor='Top,Right'
$script:InstalledLabel=New-Label '当前安装：正在读取……' 9.3; $script:InstalledLabel.SetBounds(0,(S 65),(S 990),(S 22)); $script:InstalledLabel.Anchor='Top,Left,Right'
$pathPanel.Controls.AddRange(@($pathLabel,$script:PathBox,$browse,$script:InstalledLabel)); $layout.Controls.Add($pathPanel,0,1)
$section=New-Object Windows.Forms.Panel; $section.Dock='Fill'; $section.Margin=New-Object Windows.Forms.Padding(0)
$section.Size=New-Object Drawing.Size((S 990),(S 35))
$sectionTitle=New-Label '选择形象' 12 $true; $sectionTitle.SetBounds(0,(S 6),(S 240),(S 26))
$sectionNote=New-Label '每种形象 · 47 张成人表情与动作' 9; $sectionNote.ForeColor=[Drawing.Color]::FromArgb(109,105,90); $sectionNote.TextAlign='MiddleRight'; $sectionNote.SetBounds((S 570),(S 6),(S 420),(S 26)); $sectionNote.Anchor='Top,Right'
$section.Controls.AddRange(@($sectionTitle,$sectionNote)); $layout.Controls.Add($section,0,2)
$cardGrid=New-Object Windows.Forms.TableLayoutPanel; $cardGrid.Dock='Fill'; $cardGrid.ColumnCount=3; $cardGrid.RowCount=1; $cardGrid.Margin=New-Object Windows.Forms.Padding(0,0,0,(S 10))
for($i=0;$i -lt 3;$i++){[void]$cardGrid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',[single](100/3))))}
$layout.Controls.Add($cardGrid,0,3)
$script:Variants=@()
if(Get-Command Get-ZhaoHuoVariants -ErrorAction SilentlyContinue) { $script:Variants=@(Get-ZhaoHuoVariants -PackageRoot $script:PackageRoot) }
elseif($script:PreviewMode) {
    $script:Variants=@(
        [pscustomobject]@{Id='natural';DisplayName='赵活自然版';Description='自然耐看，保留草根少年的质朴。';PreviewPath='BepInEx\plugins\ZhaoHuoNatural\Portraits\normal.png'},
        [pscustomobject]@{Id='handsome';DisplayName='赵活帅气版';Description='眉目俊朗，保留原作的江湖气。';PreviewPath='Variants\handsome\Portraits\normal.png'},
        [pscustomobject]@{Id='xianxia';DisplayName='赵活修仙小师弟版';Description='清俊小师弟，灰靛布袍与自然头身比例。';PreviewPath='Variants\xianxia\Portraits\normal.png'}
    )
} else { throw '管理器文件不完整，请重新解压完整 v1.3.0 包后打开。' }
for($i=0;$i -lt $script:Variants.Count;$i++) {
    $variant=$script:Variants[$i]
    $card=New-Object ZhaoHuo.Manager.VariantCard
    $card.VariantId=$variant.Id; $card.Heading=$variant.DisplayName; $card.Summary=$variant.Description; $card.UiScale=$script:UiScale
    $card.Dock='Fill'; $card.Margin=New-Object Windows.Forms.Padding($(if($i -eq 0){0}else{S 7}),0,$(if($i -eq 2){0}else{S 7}),0)
    $card.AccessibleName='选择 '+$variant.DisplayName; $card.AccessibleDescription=$variant.Description; $card.Tag=$variant.Id
    $card.LoadPortrait((Join-Path $script:PackageRoot $variant.PreviewPath))
    $card.Add_Click({param($sender,$eventArgs) Select-Variant $sender.VariantId})
    $cardGrid.Controls.Add($card,$i,0); $script:Cards+=,$card
}
$actions=New-Object Windows.Forms.Panel; $actions.Dock='Fill'; $actions.Margin=New-Object Windows.Forms.Padding(0)
$actions.Size=New-Object Drawing.Size((S 990),(S 110))
$script:SelectionLabel=New-Label '' 10 $true; $script:SelectionLabel.SetBounds(0,0,(S 990),(S 25)); $script:SelectionLabel.Anchor='Top,Left,Right'
$script:ApplyButton=New-Button '应用所选形象' $true; $script:ApplyButton.SetBounds(0,(S 31),(S 240),(S 44))
$check=New-Button '仅检查'; $check.SetBounds((S 253),(S 31),(S 105),(S 44))
$uninstall=New-Button '卸载并恢复'; $uninstall.SetBounds((S 371),(S 31),(S 144),(S 44))
$tip=New-Label "请先退出游戏，原文件会自动备份。`n应用后从 Steam 正常启动。" 9; $tip.ForeColor=[Drawing.Color]::FromArgb(101,98,84); $tip.SetBounds((S 536),(S 34),(S 454),(S 44)); $tip.Anchor='Top,Left,Right'
$script:Status=New-Label '就绪。选择卡片后，点击“应用所选形象”。' 9; $script:Status.SetBounds(0,(S 84),(S 990),(S 24)); $script:Status.Anchor='Top,Left,Right'
$actions.Controls.AddRange(@($script:SelectionLabel,$script:ApplyButton,$check,$uninstall,$tip,$script:Status)); $layout.Controls.Add($actions,0,4)
$script:OutputBox=New-Object Windows.Forms.TextBox; $script:OutputBox.Dock='Fill'; $script:OutputBox.Margin=New-Object Windows.Forms.Padding(0,(S 4),0,(S 7)); $script:OutputBox.Multiline=$true; $script:OutputBox.ReadOnly=$true; $script:OutputBox.ScrollBars='Vertical'; $script:OutputBox.WordWrap=$true; $script:OutputBox.BackColor=[Drawing.Color]::FromArgb(250,248,242); $script:OutputBox.ForeColor=[Drawing.Color]::FromArgb(65,67,59); $script:OutputBox.BorderStyle='FixedSingle'; $script:OutputBox.Font=New-Object Drawing.Font('Microsoft YaHei UI',[single](9*96/72*$script:UiScale),[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel); $script:OutputBox.AccessibleName='操作结果，可选择复制'
$layout.Controls.Add($script:OutputBox,0,5)
$footer=New-Label '非官方美化包 · AI 辅助重绘 · 不修改存档' 8.5; $footer.Dock='Fill'; $footer.ForeColor=[Drawing.Color]::FromArgb(120,114,96); $layout.Controls.Add($footer,0,6)
$script:ActionControls=@($script:PathBox,$browse,$script:ApplyButton,$check,$uninstall)+$script:Cards
$toolTip=New-Object Windows.Forms.ToolTip
$toolTip.SetToolTip($check,'检查所选形象的安装或切换条件，不改动游戏文件。')
$toolTip.SetToolTip($uninstall,'按安装记录恢复原文件；不会删除存档。')
$toolTip.SetToolTip($script:ApplyButton,'安装、更新或切换到所选形象。已经应用同一套文件时不会重复覆盖。')

function Add-Output([string]$Message,[string]$Level='Info') {
    $prefix=if($Level -eq 'Error'){'[错误] '}elseif($Level -eq 'Warning'){'[提示] '}else{''}
    $script:OutputBox.AppendText($prefix+$Message+[Environment]::NewLine)
    $script:OutputBox.SelectionStart=$script:OutputBox.TextLength; $script:OutputBox.ScrollToCaret()
    [Windows.Forms.Application]::DoEvents()
}
function Select-Variant([string]$Id) {
    if($script:Busy){return}
    $variant=@($script:Variants | Where-Object Id -eq $Id)[0]
    if(-not $variant){throw "形象不存在：$Id"}
    $script:SelectedVariantId=$Id
    foreach($card in $script:Cards){$card.Selected=($card.VariantId -eq $Id);$card.Invalidate()}
    $script:SelectionLabel.Text='已选择：'+$variant.DisplayName+'  ·  点击应用后才会更换'
}
function Refresh-InstalledState([switch]$SyncSelection) {
    $selectedPath=$script:PathBox.Text.Trim().Trim('"')
    try {
        if($script:PreviewMode) {
            $id=$script:MockInstalledId
            $v=@($script:Variants | Where-Object Id -eq $id)
            $script:InstalledState=if($v.Count){[pscustomobject]@{Status='Installed';VariantId=$id;DisplayName=$v[0].DisplayName;Message='预览示例';HasManifest=$true}}else{[pscustomobject]@{Status='NotInstalled';VariantId=$null;DisplayName=$null;Message='尚未安装';HasManifest=$false}}
        } elseif([string]::IsNullOrWhiteSpace($selectedPath)) {
            $script:InstalledState=[pscustomobject]@{Status='Invalid';VariantId=$null;DisplayName=$null;Message='请选择游戏目录';HasManifest=$false}
        } else {$script:InstalledState=Get-ZhaoHuoInstalledVariant -GamePath $selectedPath -PackageRoot $script:PackageRoot}
        $state=$script:InstalledState
        $script:InstalledLabel.ForeColor=[Drawing.Color]::FromArgb(70,98,73)
        if($state.Status -eq 'Installed') {$script:InstalledLabel.Text='当前已安装：'+$state.DisplayName}
        elseif($state.Status -eq 'NotInstalled') {$script:InstalledLabel.Text='当前安装：尚未安装美化包'}
        else {$script:InstalledLabel.Text='当前安装：'+$state.Message; $script:InstalledLabel.ForeColor=[Drawing.Color]::FromArgb(146,82,43)}
        $toolTip.SetToolTip($script:InstalledLabel,$script:InstalledLabel.Text)
        foreach($card in $script:Cards){$card.Installed=($state.Status -eq 'Installed' -and $card.VariantId -eq $state.VariantId);$card.Invalidate()}
        if($SyncSelection -and $state.Status -eq 'Installed'){Select-Variant $state.VariantId}
    } catch {
        $script:InstalledState=$null
        $script:InstalledLabel.Text='当前安装：无法读取，请点击“仅检查”查看详情。'
        $script:InstalledLabel.ForeColor=[Drawing.Color]::FromArgb(146,82,43)
        $toolTip.SetToolTip($script:InstalledLabel,$_.Exception.Message)
        foreach($card in $script:Cards){$card.Installed=$false;$card.Invalidate()}
    }
}
function Invoke-BackendRequest([string]$Action,[string]$Path,[string]$VariantId,[scriptblock]$Logger) {
    if($script:PreviewMode) {
        if(-not $UiTestReport){throw '预览模式不执行安装、检查或卸载操作。'}
        [void]$script:MockRequests.Add([pscustomobject]@{Action=$Action;GamePath=$Path;VariantId=$VariantId;ControlsDisabled=(@($script:ActionControls|Where-Object Enabled).Count -eq 0)})
        if($script:TestFailNext){$script:TestFailNext=$false;throw '模拟错误：游戏仍在运行。'}
        if($Action -eq 'Install'){$script:MockInstalledId=$VariantId}
        if($Action -eq 'Uninstall'){$script:MockInstalledId=$null}
        & $Logger '界面测试已记录请求，未调用安装器。' 'Info'
        return
    }
    if($Action -eq 'Uninstall'){Uninstall-ZhaoHuo -GamePath $Path -Log $Logger | Out-Null}
    else {Install-ZhaoHuo -GamePath $Path -PackageRoot $script:PackageRoot -VariantId $VariantId -CheckOnly:($Action -eq 'Check') -Log $Logger | Out-Null}
}
function Invoke-Action([string]$Action) {
    if($script:Busy){return}
    $script:Busy=$true; $refreshTimer.Stop()
    foreach($control in $script:ActionControls){$control.Enabled=$false}
    $script:Status.ForeColor=[Drawing.Color]::FromArgb(70,98,73)
    $script:Status.Text=if($Action -eq 'Check'){'正在只读检查，首次兼容检查可能需要稍等……'}else{'正在处理，请保留此窗口，等待备份或恢复完成……'}
    try {
        Add-Output ('—— '+(Get-Date -Format 'HH:mm:ss')+' ——')
        $selectedPath=$script:PathBox.Text.Trim().Trim('"')
        if([string]::IsNullOrWhiteSpace($selectedPath)){throw '请从下拉列表选择游戏目录，或点击“浏览文件夹”。'}
        $logger={param($Message,$Level)Add-Output $Message $Level}
        Invoke-BackendRequest $Action $selectedPath $script:SelectedVariantId $logger
        $script:Status.Text=if($Action -eq 'Check'){'检查完成，游戏文件未改动。请查看下方结果。'}elseif($Action -eq 'Uninstall'){'恢复完成。请查看下方结果与保留文件说明。'}else{'应用完成，可以从 Steam 正常启动游戏。'}
    } catch {
        Add-Output $_.Exception.Message 'Error'
        $script:Status.ForeColor=[Drawing.Color]::FromArgb(161,57,42)
        $script:Status.Text='未完成：'+$_.Exception.Message
        $toolTip.SetToolTip($script:Status,$_.Exception.ToString())
    } finally {
        $script:Busy=$false
        foreach($control in $script:ActionControls){$control.Enabled=$true}
        Refresh-InstalledState
    }
}
$refreshTimer=New-Object Windows.Forms.Timer; $refreshTimer.Interval=650
$refreshTimer.Add_Tick({$refreshTimer.Stop();if(-not $script:Busy){Refresh-InstalledState -SyncSelection}})
$script:PathBox.Add_TextChanged({if(-not $script:Busy -and -not $script:PreviewMode){$refreshTimer.Stop();$refreshTimer.Start()}})
$browse.Add_Click({
    $dialog=New-Object Windows.Forms.FolderBrowserDialog
    try {
        $dialog.Description='请选择活侠传本地文件目录（包含 Mortal.exe）。';$dialog.ShowNewFolderButton=$false
        if(Test-Path -LiteralPath $script:PathBox.Text -PathType Container){$dialog.SelectedPath=$script:PathBox.Text}
        if($dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK){$script:PathBox.Text=$dialog.SelectedPath}
    } finally {$dialog.Dispose()}
})
$script:ApplyButton.Add_Click({Invoke-Action 'Install'});$check.Add_Click({Invoke-Action 'Check'});$uninstall.Add_Click({Invoke-Action 'Uninstall'})
$form.Add_FormClosing({param($sender,$eventArgs)if($script:Busy){$eventArgs.Cancel=$true;$script:Status.Text='正在写入或回滚文件，请等操作完成后再关闭。'}})
$script:MockInstalledId=if($PreviewInstalledVariant -eq 'none'){$null}else{$PreviewInstalledVariant}

try {
    if($script:PreviewMode){$script:PathBox.Text=if($GamePath){$GamePath}else{'D:\SteamLibrary\steamapps\common\LegendOfMortal'};Add-Output '窗口示例：选择形象后点击应用。预览模式不会读取或修改游戏。'}
    else {
        $candidates=@(Get-ZhaoHuoSteamCandidates)
        foreach($candidate in $candidates){[void]$script:PathBox.Items.Add($candidate)}
        if($GamePath){$script:PathBox.Text=$GamePath}elseif($candidates.Count -eq 1){$script:PathBox.SelectedIndex=0}
        if($candidates.Count -gt 1 -and -not $GamePath){Add-Output "找到 $($candidates.Count) 个目录，请选择要管理的 Steam 游戏目录。"}
        elseif(-not $script:PathBox.Text){Add-Output '未自动找到活侠传，请点击“浏览文件夹”选择游戏目录。'}
        else{Add-Output '已读取游戏目录。选择形象，再点击“应用所选形象”；仅检查不会改动文件。'}
    }
    Select-Variant 'natural';Refresh-InstalledState -SyncSelection
$form.ActiveControl=if($InitialAction -eq 'Uninstall'){$uninstall}else{@($script:Cards|Where-Object VariantId -eq $script:SelectedVariantId)[0]}
    if($script:PreviewMode) {
        $form.ShowInTaskbar=$false;$form.StartPosition='Manual';$form.Location=New-Object Drawing.Point(-20000,-20000)
        $form.Show();[Windows.Forms.Application]::DoEvents();$form.PerformLayout()
        if($UiTestReport) {
            $assertions=New-Object 'System.Collections.Generic.List[string]'
            foreach($id in @('natural','handsome','xianxia')) {
                $card=@($script:Cards|Where-Object VariantId -eq $id)[0];$before=$script:MockRequests.Count;$installedBefore=$script:MockInstalledId
                $card.PerformClick()
                if($script:SelectedVariantId -ne $id -or $script:MockRequests.Count -ne $before -or $script:MockInstalledId -ne $installedBefore){throw "卡片选择状态错误：$id"};$assertions.Add("Select $id without writes")
                $script:ApplyButton.PerformClick();$request=$script:MockRequests[$script:MockRequests.Count-1]
                if($request.Action -ne 'Install' -or $request.VariantId -ne $id -or -not $request.ControlsDisabled -or $script:MockInstalledId -ne $id){throw "应用派发错误：$id"};$assertions.Add("Apply $id dispatch and installed state")
                $check.PerformClick();$request=$script:MockRequests[$script:MockRequests.Count-1]
                if($request.Action -ne 'Check' -or $request.VariantId -ne $id -or -not $request.ControlsDisabled){throw "只读派发错误：$id"};$assertions.Add("Check $id dispatch")
            }
            $before=$script:MockRequests.Count;$script:Busy=$true;Invoke-Action 'Install';Select-Variant 'natural';$script:Busy=$false
            if($script:MockRequests.Count -ne $before -or $script:SelectedVariantId -ne 'xianxia'){throw '忙碌状态未阻止重复操作。'};$assertions.Add('Busy state prevents duplicate dispatch and selection')
            $script:TestFailNext=$true;$script:ApplyButton.PerformClick()
            if($script:Busy -or @($script:ActionControls|Where-Object { -not $_.Enabled }).Count -or $script:Status.Text -notlike '*游戏仍在运行*'){throw '失败后未恢复界面或错误未显示。'};$assertions.Add('Failure is visible and controls recover')
            $uninstall.PerformClick();$request=$script:MockRequests[$script:MockRequests.Count-1]
            if($request.Action -ne 'Uninstall' -or $script:MockInstalledId -or @($script:Cards|Where-Object Installed).Count){throw '卸载派发或安装标记清理错误。'};$assertions.Add('Uninstall dispatch clears installed state')
            $before=$script:MockRequests.Count;$script:PathBox.Text='';$script:ApplyButton.PerformClick()
            if($script:MockRequests.Count -ne $before -or $script:Status.Text -notlike '*选择游戏目录*'){throw '空目录未阻止操作。'};$assertions.Add('Empty path blocks dispatch')
            foreach($control in @($title,$version,$pathLabel,$script:PathBox,$browse,$sectionNote,$script:ApplyButton,$check,$uninstall,$tip)+$script:Cards) {
                if(-not $control.Parent.ClientRectangle.Contains($control.Bounds)){throw ('控件超出容器：'+$control.AccessibleName+' '+$control.Text)}
            };$assertions.Add('Key controls and all three cards stay inside their containers')
            if($layout.Width -gt $form.ClientSize.Width -or $cardGrid.Width -gt $layout.ClientSize.Width){throw '主布局横向溢出。'};$assertions.Add('Main layout does not overflow client width')
            foreach($control in @($title,$version,$subtitle,$script:ApplyButton,$check,$uninstall)) {
                if($control.Font.Unit -ne [Drawing.GraphicsUnit]::Pixel -or $control.Font.Height -gt $control.Height){throw '字体单位或高度不正确。'}
            };$assertions.Add('Pixel fonts avoid double DPI scaling and fit key controls')
            $screenGraphics=[Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
            try{$actualDpi=$screenGraphics.DpiX}finally{$screenGraphics.Dispose()}
            $report=[ordered]@{Passed=$true;AssertionCount=$assertions.Count;Scope='WinForms button events with isolated mock backend; no game writes';PowerShell=$PSVersionTable.PSVersion.ToString();PreviewSize=$PreviewSize;UiScale=$script:UiScale;ActualSystemDpi=$actualDpi;Assertions=@($assertions)}
            $reportPath=[IO.Path]::GetFullPath($UiTestReport);[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($reportPath))|Out-Null
            [IO.File]::WriteAllText($reportPath,($report|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
            Write-Output ('UI dispatch assertions passed: '+$assertions.Count)
        }
        if($PreviewPath) {
            $preview=[IO.Path]::GetFullPath($PreviewPath);[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($preview))|Out-Null
            $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
            try{$form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save($preview,[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}
            Write-Output 'GUI preview saved; no game installation action was executed.'
        }
        $form.Close()
    } else {[void]$form.ShowDialog()}
} finally {$refreshTimer.Dispose();$toolTip.Dispose();$form.Dispose()}
