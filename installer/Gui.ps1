#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Install','Uninstall')][string]$InitialAction = 'Install',
    [string]$GamePath,
    [string]$PreviewPath,
    [ValidateSet('Default','Compact')][string]$PreviewSize = 'Default',
    [ValidateRange(1,2)][double]$PreviewScale = 1,
    [string]$PreviewInstalledVariant = 'none',
    [ValidateSet('player','tang-buyi','xiahou-lan')][string]$PreviewCharacterId = 'player',
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
$script:SelectedCharacterId = 'player'
$script:Selections = @{}
$script:RoleButtons = @()
$script:TestRecoveryNext = $false
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
        public bool Original { get; set; }
        public bool Available { get; set; }
        public float UiScale { get; set; }
        private Bitmap portrait;
        private Rectangle source;
        private bool hovered;
        public VariantCard() {
            UiScale = 1f; Available = true;
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
            if(portrait==null) {
                using(var f=new Font("Microsoft YaHei UI",(Original?24:14)*96f/72f*s,FontStyle.Regular,GraphicsUnit.Pixel))
                    TextRenderer.DrawText(g,Original?"原 作":"预览准备中",f,Rectangle.Round(artArea),Color.FromArgb(133,125,104),TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter|TextFormatFlags.NoPadding);
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
                    TextRenderer.DrawText(g,"当前使用",f,badge,Color.White,TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter|TextFormatFlags.NoPadding);
            }
            if(Focused) ControlPaint.DrawFocusRectangle(g,new Rectangle((int)(6*s),(int)(6*s),Width-(int)(12*s),Height-(int)(12*s)),green,paper);
            if(!Enabled) using(var b=new SolidBrush(Color.FromArgb(70,245,240,227)))g.FillRectangle(b,ClientRectangle);
            if(!Available) {
                using(var f=new Font("Microsoft YaHei UI",9*96f/72f*s,FontStyle.Bold,GraphicsUnit.Pixel))
                    TextRenderer.DrawText(g,"暂未就绪",f,new Rectangle((int)(12*s),(int)(45*s),Width-(int)(24*s),(int)(22*s)),Color.FromArgb(151,62,44),TextFormatFlags.Left|TextFormatFlags.NoPadding);
            }
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


$form=New-Object Windows.Forms.Form
$form.Text='活侠传角色美化管理器 · v2.0.0';$form.AutoScaleMode='None';$form.StartPosition='CenterScreen'
$form.Font=New-Object Drawing.Font('Microsoft YaHei UI',[single](10*96/72*$script:UiScale),[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
$form.BackColor=[Drawing.Color]::FromArgb(241,236,223)
$width=if($PreviewSize -eq 'Compact'){920}else{1120};$height=if($PreviewSize -eq 'Compact'){720}else{860}
if(-not $script:PreviewMode){$area=[Windows.Forms.Screen]::PrimaryScreen.WorkingArea;$width=[Math]::Min($width,[Math]::Max(820,($area.Width-40)/$script:UiScale));$height=[Math]::Min($height,[Math]::Max(650,($area.Height-60)/$script:UiScale))}
$form.ClientSize=New-Object Drawing.Size((S $width),(S $height));$form.MinimumSize=New-Object Drawing.Size((S 840),(S 670))
$layout=New-Object Windows.Forms.TableLayoutPanel;$layout.Dock='Fill';$layout.ColumnCount=1;$layout.RowCount=6;$layout.Padding=New-Object Windows.Forms.Padding((S 24),(S 18),(S 24),(S 14))
[void]$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',[single]100)))
foreach($h in @(76,91,-1,111,84,22)){$row=New-Object Windows.Forms.RowStyle;if($h -lt 0){$row.SizeType='Percent';$row.Height=100}else{$row.SizeType='Absolute';$row.Height=S $h};[void]$layout.RowStyles.Add($row)}
$form.Controls.Add($layout)
$header=New-Object Windows.Forms.Panel;$header.Dock='Fill';$header.Margin=New-Object Windows.Forms.Padding(0);$header.Size=New-Object Drawing.Size((S 1072),(S 76))
$seal=New-Label "活`n侠" 12 $true;$seal.BackColor=[Drawing.Color]::FromArgb(151,62,44);$seal.ForeColor=[Drawing.Color]::FromArgb(255,246,220);$seal.TextAlign='MiddleCenter';$seal.SetBounds(0,(S 2),(S 40),(S 52))
$title=New-Label '活侠传角色美化管理器' 21 $true;$title.SetBounds((S 56),0,(S 690),(S 43));$title.Anchor='Top,Left,Right'
$subtitle=New-Label '逐个角色，选你喜欢的江湖模样。' 10;$subtitle.ForeColor=[Drawing.Color]::FromArgb(104,101,87);$subtitle.SetBounds((S 58),(S 47),(S 660),(S 24));$subtitle.Anchor='Top,Left,Right'
$version=New-Label 'v2.0.0 · 离线安装' 9;$version.TextAlign='TopRight';$version.ForeColor=[Drawing.Color]::FromArgb(111,107,90);$version.SetBounds((S 858),(S 17),(S 210),(S 24));$version.Anchor='Top,Right'
$header.Controls.AddRange(@($seal,$title,$subtitle,$version));$layout.Controls.Add($header,0,0)
$pathPanel=New-Object Windows.Forms.Panel;$pathPanel.Dock='Fill';$pathPanel.Margin=New-Object Windows.Forms.Padding(0);$pathPanel.Size=New-Object Drawing.Size((S 1072),(S 91))
$pathLabel=New-Label 'Steam 游戏目录' 10 $true;$pathLabel.SetBounds(0,0,(S 300),(S 24))
$script:PathBox=New-Object Windows.Forms.ComboBox;$script:PathBox.DropDownStyle='DropDown';$script:PathBox.SetBounds(0,(S 29),(S 937),(S 30));$script:PathBox.Anchor='Top,Left,Right';$script:PathBox.AccessibleName='Steam 游戏目录，包含 Mortal.exe'
$browse=New-Button '浏览文件夹';$browse.SetBounds((S 950),(S 27),(S 122),(S 34));$browse.Anchor='Top,Right'
$script:InstalledLabel=New-Label '当前状态：正在读取……' 9.2;$script:InstalledLabel.SetBounds(0,(S 65),(S 1072),(S 23));$script:InstalledLabel.Anchor='Top,Left,Right'
$pathPanel.Controls.AddRange(@($pathLabel,$script:PathBox,$browse,$script:InstalledLabel));$layout.Controls.Add($pathPanel,0,1)
$body=New-Object Windows.Forms.TableLayoutPanel;$body.Dock='Fill';$body.Margin=New-Object Windows.Forms.Padding(0,0,0,(S 8));$body.ColumnCount=2;$body.RowCount=1
[void]$body.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',[single](S 176))));[void]$body.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',[single]100)));$layout.Controls.Add($body,0,2)
$rolePanel=New-Object Windows.Forms.FlowLayoutPanel;$rolePanel.Dock='Fill';$rolePanel.FlowDirection='TopDown';$rolePanel.WrapContents=$false;$rolePanel.AutoScroll=$true;$rolePanel.Margin=New-Object Windows.Forms.Padding(0,0,(S 15),0)
$roleHeading=New-Label '选择角色' 11 $true;$roleHeading.Size=New-Object Drawing.Size((S 153),(S 33));$rolePanel.Controls.Add($roleHeading);$body.Controls.Add($rolePanel,0,0)
$right=New-Object Windows.Forms.TableLayoutPanel;$right.Dock='Fill';$right.Margin=New-Object Windows.Forms.Padding(0);$right.ColumnCount=1;$right.RowCount=2
[void]$right.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',[single](S 39))));[void]$right.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',[single]100)))
$script:CharacterHeading=New-Label '' 12 $true;$script:CharacterHeading.Dock='Fill';$right.Controls.Add($script:CharacterHeading,0,0)
$cardGrid=New-Object Windows.Forms.FlowLayoutPanel;$cardGrid.Dock='Fill';$cardGrid.AutoScroll=$true;$cardGrid.WrapContents=$true;$cardGrid.FlowDirection='LeftToRight';$cardGrid.Margin=New-Object Windows.Forms.Padding(0);$cardGrid.Padding=New-Object Windows.Forms.Padding(0)
$right.Controls.Add($cardGrid,0,1);$body.Controls.Add($right,1,0)
$actions=New-Object Windows.Forms.Panel;$actions.Dock='Fill';$actions.Margin=New-Object Windows.Forms.Padding(0);$actions.Size=New-Object Drawing.Size((S 1072),(S 111))
$script:SelectionLabel=New-Label '' 10 $true;$script:SelectionLabel.SetBounds(0,0,(S 1072),(S 26));$script:SelectionLabel.Anchor='Top,Left,Right'
$script:ApplyButton=New-Button '应用当前角色' $true;$script:ApplyButton.SetBounds(0,(S 32),(S 218),(S 44))
$check=New-Button '仅检查';$check.SetBounds((S 231),(S 32),(S 110),(S 44))
$uninstall=New-Button '全部卸载并恢复';$uninstall.SetBounds((S 354),(S 32),(S 162),(S 44))
$tip=New-Label "应用只更改当前角色。`n请先退出游戏，完成后从 Steam 启动。" 9;$tip.ForeColor=[Drawing.Color]::FromArgb(101,98,84);$tip.SetBounds((S 536),(S 32),(S 536),(S 46));$tip.Anchor='Top,Left,Right'
$script:Status=New-Label '先选择角色，再选择外观。' 9;$script:Status.SetBounds(0,(S 86),(S 1072),(S 23));$script:Status.Anchor='Top,Left,Right'
$actions.Controls.AddRange(@($script:SelectionLabel,$script:ApplyButton,$check,$uninstall,$tip,$script:Status));$layout.Controls.Add($actions,0,3)
$script:OutputBox=New-Object Windows.Forms.TextBox;$script:OutputBox.Dock='Fill';$script:OutputBox.Margin=New-Object Windows.Forms.Padding(0,(S 4),0,(S 7));$script:OutputBox.Multiline=$true;$script:OutputBox.ReadOnly=$true;$script:OutputBox.ScrollBars='Vertical';$script:OutputBox.BackColor=[Drawing.Color]::FromArgb(250,248,242);$script:OutputBox.ForeColor=[Drawing.Color]::FromArgb(65,67,59);$script:OutputBox.AccessibleName='操作结果，可选择复制';$layout.Controls.Add($script:OutputBox,0,4)
$footer=New-Label '非官方美化包 · AI 辅助重绘 · 未覆盖表情保留原画 · 不修改存档' 8.5;$footer.Dock='Fill';$footer.ForeColor=[Drawing.Color]::FromArgb(120,114,96);$layout.Controls.Add($footer,0,5)
$toolTip=New-Object Windows.Forms.ToolTip;$toolTip.SetToolTip($check,'只检查当前角色所选外观，不修改游戏文件。');$toolTip.SetToolTip($uninstall,'卸载全部角色的美化，并按最初安装记录恢复文件。')

function Get-Character([string]$Id){return @($script:Catalog.Characters|Where-Object Id -CEQ $Id)[0]}
function Get-SelectedVariant { $character=Get-Character $script:SelectedCharacterId;return @($character.Variants|Where-Object Id -CEQ $script:Selections[$script:SelectedCharacterId])[0] }
function Get-CharacterState([string]$Id){if($null -eq $script:InstalledState){return $null};return @($script:InstalledState.Characters|Where-Object Id -CEQ $Id)|Select-Object -First 1}
function Add-Output([string]$Message,[string]$Level='Info'){$prefix=if($Level -eq 'Error'){'[错误] '}elseif($Level -eq 'Warning'){'[提示] '}else{''};$script:OutputBox.AppendText($prefix+$Message+[Environment]::NewLine);$script:OutputBox.SelectionStart=$script:OutputBox.TextLength;$script:OutputBox.ScrollToCaret();[Windows.Forms.Application]::DoEvents()}
function Update-ActionControls {
    foreach($control in @($script:PathBox,$browse,$uninstall)+$script:RoleButtons){$control.Enabled=-not $script:Busy}
    foreach($card in $script:Cards){$card.Enabled=(-not $script:Busy -and $card.Available)}
    $variant=Get-SelectedVariant;$available=($null -ne $variant -and $variant.Available)
    $script:ApplyButton.Enabled=(-not $script:Busy -and $available);$check.Enabled=(-not $script:Busy -and $available)
    $script:ActionControls=@($script:PathBox,$browse,$script:ApplyButton,$check,$uninstall)+$script:RoleButtons+$script:Cards
}
function Resize-Cards {
    if(-not $script:Cards.Count){return}
    $available=$cardGrid.ClientSize.Width-[Windows.Forms.SystemInformation]::VerticalScrollBarWidth-(S 6)
    $columns=if($available -ge (S 750)){3}else{2};$cardWidth=[Math]::Max((S 170),[Math]::Floor($available/$columns)-(S 10))
    $cardHeight=[Math]::Min((S 282),[Math]::Max((S 225),$cardGrid.ClientSize.Height-(S 14)))
    foreach($card in $script:Cards){$card.Size=New-Object Drawing.Size($cardWidth,$cardHeight);$card.Margin=New-Object Windows.Forms.Padding(0,0,(S 10),(S 12))}
}
function Resize-Roles {
    $roleWidth=[Math]::Max((S 122),$rolePanel.ClientSize.Width-[Windows.Forms.SystemInformation]::VerticalScrollBarWidth-(S 4))
    $roleHeading.Width=$roleWidth
    foreach($button in $script:RoleButtons){$button.Width=$roleWidth}
}
function Update-Selection {
    $variant=Get-SelectedVariant;$character=Get-Character $script:SelectedCharacterId
    foreach($card in $script:Cards){$card.Selected=($card.VariantId -ceq $variant.Id);$card.Invalidate()}
    $script:SelectionLabel.Text='已选择：'+$character.DisplayName+' / '+$variant.DisplayName+'  ·  点击应用后才会更换'
    if(-not $variant.Available){$script:Status.Text='暂不可应用：'+$variant.UnavailableReason;$toolTip.SetToolTip($script:Status,$script:Status.Text)}
    Update-ActionControls
}
function Select-Variant([string]$Id) {
    if($script:Busy){return};$character=Get-Character $script:SelectedCharacterId;$matches=@($character.Variants|Where-Object Id -CEQ $Id)
    if($matches.Count -ne 1){throw '此角色没有该外观。'}
    if(-not $matches[0].Available){$script:Status.Text='暂不可应用：'+$matches[0].UnavailableReason;return}
    $script:Selections[$script:SelectedCharacterId]=$Id;Update-Selection
}
function Update-CurrentMarkers {
    foreach($button in $script:RoleButtons){$character=Get-Character $button.Tag;$state=Get-CharacterState $button.Tag;$current=if($state -and $state.State -ne 'Unknown'){$state.InstalledDisplayName}else{'状态待确认'};$button.Text=$character.DisplayName+"`n"+$current;$button.BackColor=if($button.Tag -ceq $script:SelectedCharacterId){[Drawing.Color]::FromArgb(43,80,68)}else{[Drawing.Color]::FromArgb(250,247,239)};$button.ForeColor=if($button.Tag -ceq $script:SelectedCharacterId){[Drawing.Color]::White}else{[Drawing.Color]::FromArgb(48,61,52)}}
    $state=Get-CharacterState $script:SelectedCharacterId
    foreach($card in $script:Cards){$card.Installed=($null -ne $state -and $state.State -in @('Custom','Original') -and $card.VariantId -ceq $state.InstalledVariantId);$card.Invalidate()}
}
function Select-Character([string]$Id) {
    if($script:Busy){return};$character=Get-Character $Id;if(-not $character){throw '角色不存在。'}
    $script:SelectedCharacterId=$Id
    if(-not $script:Selections.ContainsKey($Id)){$script:Selections[$Id]='original'}
    $cardGrid.SuspendLayout();try{foreach($card in $script:Cards){$cardGrid.Controls.Remove($card);$card.Dispose()};$script:Cards=@();$cardGrid.AutoScrollPosition=New-Object Drawing.Point(0,0)
      foreach($variant in $character.Variants){
        $card=New-Object ZhaoHuo.Manager.VariantCard;$card.VariantId=$variant.Id;$card.Heading=$variant.DisplayName;$card.Summary=$variant.Description;$card.Original=($variant.Kind -eq 'original');$card.Available=[bool]$variant.Available;$card.UiScale=$script:UiScale;$card.AccessibleName='选择 '+$character.DisplayName+' '+$variant.DisplayName;$card.AccessibleDescription=$variant.Description
        if($variant.PreviewPath){try{$preview=Resolve-PreviewPath $variant.PreviewPath;if(Test-Path -LiteralPath $preview -PathType Leaf){$card.LoadPortrait($preview)}}catch{Add-Output ('预览不可用：'+$variant.DisplayName) 'Warning'}}
        $card.Add_Click({param($sender,$eventArgs)Select-Variant $sender.VariantId});$cardGrid.Controls.Add($card);$script:Cards+=,$card
        if(-not $variant.Available){$toolTip.SetToolTip($card,$variant.UnavailableReason)}
      }
      Resize-Cards
    }finally{$cardGrid.ResumeLayout()}
    $script:CharacterHeading.Text=$character.DisplayName+'  ·  '+$character.Variants.Count+' 种外观  /  向下滚动查看更多'
    Update-CurrentMarkers;Update-Selection
}
function Resolve-PreviewPath([string]$Relative) {
    if([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative) -or $Relative.Contains(':') -or @($Relative -split '[\\/]'|Where-Object {$_ -in @('','..','.')}).Count){throw '无效预览路径。'}
    $base=[IO.Path]::GetFullPath($script:PackageRoot).TrimEnd('\')+'\';$full=[IO.Path]::GetFullPath((Join-Path $base $Relative));if(-not $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){throw '预览路径越界。'}
    for($current=$full;$current;$current=[IO.Path]::GetDirectoryName($current)){if((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw '预览路径不能使用联接。'}}
    return $full
}
function New-MockState {
    $rows=@(foreach($character in $script:Catalog.Characters){$id=$script:MockInstalled[$character.Id];$variant=@($character.Variants|Where-Object Id -CEQ $id)[0];[pscustomobject]@{Id=$character.Id;DisplayName=$character.DisplayName;State=$(if($id -eq 'original'){'Original'}else{'Custom'});SelectedVariantId=$id;InstalledVariantId=$id;InstalledDisplayName=$variant.DisplayName}})
    return [pscustomobject]@{Status='Installed';HasManifest=$true;RequiresMigration=$false;CanApply=$true;Message='界面预览示例';Characters=$rows}
}
function Refresh-InstalledState([switch]$SyncSelection) {
    $path=$script:PathBox.Text.Trim().Trim('"')
    try{
      if($script:PreviewMode){$script:InstalledState=New-MockState}
      elseif([string]::IsNullOrWhiteSpace($path)){$script:InstalledState=[pscustomobject]@{Status='Invalid';HasManifest=$false;Message='请选择游戏目录';Characters=@()}}
      else{$script:InstalledState=Get-PortraitManagerState -GamePath $path -PackageRoot $script:PackageRoot}
      $state=$script:InstalledState;$script:InstalledLabel.Text='当前状态：'+$state.Message
      if($state.Status -eq 'Installed' -and $state.RequiresMigration){$script:InstalledLabel.Text+='  ·  应用时升级管理记录，保留最初备份'}
      $script:InstalledLabel.ForeColor=if($state.Status -in @('Installed','NotInstalled')){[Drawing.Color]::FromArgb(70,98,73)}else{[Drawing.Color]::FromArgb(146,82,43)}
      if($SyncSelection){foreach($row in $state.Characters){if($row.State -in @('Custom','Original') -and $row.InstalledVariantId){$script:Selections[$row.Id]=$row.InstalledVariantId}}}
    }catch{$script:InstalledState=$null;$script:InstalledLabel.Text='当前状态：无法读取，请核对游戏目录。';$script:InstalledLabel.ForeColor=[Drawing.Color]::FromArgb(146,82,43);$toolTip.SetToolTip($script:InstalledLabel,$_.Exception.Message)}
    Update-CurrentMarkers;Update-Selection
}
function Invoke-BackendRequest([string]$Action,[string]$Path,[string]$CharacterId,[string]$VariantId,[scriptblock]$Logger) {
    if($script:PreviewMode){
      if(-not $UiTestReport){throw '预览模式不执行安装、检查或卸载。'}
      $script:MockRequests.Add([pscustomobject]@{Action=$Action;CharacterId=$CharacterId;VariantId=$VariantId;ControlsDisabled=(@($script:ActionControls|Where-Object Enabled).Count -eq 0)})
      if($script:TestFailNext){$script:TestFailNext=$false;throw '模拟错误：游戏仍在运行。'}
      if($script:TestRecoveryNext){$script:TestRecoveryNext=$false;return [pscustomobject]@{Status='RecoveryRequired'}}
      if($Action -eq 'Install'){$script:MockInstalled[$CharacterId]=$VariantId}
      if($Action -eq 'Uninstall'){foreach($id in @($script:MockInstalled.Keys)){$script:MockInstalled[$id]='original'}}
      & $Logger '界面事件测试：未调用真实安装器。' 'Info'
      return [pscustomobject]@{Status=$(if($Action -eq 'Check'){'Checked'}elseif($Action -eq 'Uninstall'){'Uninstalled'}else{'Applied'})}
    }
    if($Action -eq 'Uninstall'){return Uninstall-PortraitManager -GamePath $Path -Log $Logger}
    return Set-PortraitAppearance -GamePath $Path -PackageRoot $script:PackageRoot -CharacterId $CharacterId -VariantId $VariantId -CheckOnly:($Action -eq 'Check') -Log $Logger
}
function Invoke-Action([string]$Action) {
    if($script:Busy){return};$variant=Get-SelectedVariant
    if($Action -ne 'Uninstall' -and -not $variant.Available){$script:Status.Text='此款外观尚未就绪，不能应用。';return}
    $selectedPath=$script:PathBox.Text.Trim().Trim('"');$selectedRole=$script:SelectedCharacterId;$selectedVariant=$variant.Id
    $script:LockedGamePath=$script:PathBox.Text;$script:Busy=$true;$refreshTimer.Stop();Update-ActionControls
    $script:Status.ForeColor=[Drawing.Color]::FromArgb(70,98,73);$script:Status.Text=if($Action -eq 'Check'){'正在只读检查，请稍等……'}else{'正在处理，请等待备份或恢复完成……'}
    try{
      if([string]::IsNullOrWhiteSpace($selectedPath)){throw '请选择游戏目录，或点击浏览文件夹。'}
      Add-Output ('—— '+(Get-Date -Format 'HH:mm:ss')+' ——')
      $logger={param($Message,$Level)Add-Output $Message $Level}
      $result=Invoke-BackendRequest $Action $selectedPath $selectedRole $selectedVariant $logger
      if($result.Status -eq 'RecoveryRequired'){$script:Status.Text='发现待恢复的操作。请点击应用或全部卸载，先恢复上次事务。';Add-Output $script:Status.Text 'Warning'}
      elseif($Action -eq 'Check'){$script:Status.Text='检查完成，游戏文件未改动。'}
      elseif($Action -eq 'Uninstall'){$script:Status.Text='全部角色已卸载并恢复，请查看保留文件说明。'}
      elseif($result.Status -eq 'NoOp'){$script:Status.Text='当前角色已是此款外观，无需改动。'}
      else{$script:Status.Text='当前角色已应用，可以从 Steam 正常启动。'}
    }catch{Add-Output $_.Exception.Message 'Error';$script:Status.ForeColor=[Drawing.Color]::FromArgb(161,57,42);$script:Status.Text='未完成：'+$_.Exception.Message;$toolTip.SetToolTip($script:Status,$_.Exception.ToString())}
    finally{$script:Busy=$false;Refresh-InstalledState;Update-ActionControls}
}
$refreshTimer=New-Object Windows.Forms.Timer;$refreshTimer.Interval=650;$refreshTimer.Add_Tick({$refreshTimer.Stop();if(-not $script:Busy){Refresh-InstalledState -SyncSelection}})
$script:PathBox.Add_TextChanged({if($script:Busy){if($script:PathBox.Text -cne $script:LockedGamePath){$script:PathBox.Text=$script:LockedGamePath};return};if(-not $script:PreviewMode){$refreshTimer.Stop();$refreshTimer.Start()}})
$cardGrid.Add_SizeChanged({Resize-Cards})
$rolePanel.Add_SizeChanged({Resize-Roles})
$browse.Add_Click({$dialog=New-Object Windows.Forms.FolderBrowserDialog;try{$dialog.Description='选择包含 Mortal.exe 的活侠传游戏目录';$dialog.ShowNewFolderButton=$false;if(Test-Path -LiteralPath $script:PathBox.Text -PathType Container){$dialog.SelectedPath=$script:PathBox.Text};if($dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK){$script:PathBox.Text=$dialog.SelectedPath}}finally{$dialog.Dispose()}})
$script:ApplyButton.Add_Click({Invoke-Action 'Install'});$check.Add_Click({Invoke-Action 'Check'});$uninstall.Add_Click({Invoke-Action 'Uninstall'})
$form.Add_FormClosing({param($sender,$eventArgs)if($script:Busy){$eventArgs.Cancel=$true;$script:Status.Text='正在写入或回滚，请等操作完成再关闭。'}})


function Invoke-UiEventTests {
    if(-not $UiTestReport -or -not $script:PreviewMode){throw 'UI tests require the isolated preview backend.'}
    $assertions=New-Object 'System.Collections.Generic.List[string]'
    function Assert-Ui([string]$Name,[bool]$Passed){if(-not $Passed){throw ('UI assertion failed: '+$Name)};$assertions.Add($Name)}
    foreach($character in $script:Catalog.Characters){
      $before=$script:MockRequests.Count;@($script:RoleButtons|Where-Object Tag -CEQ $character.Id)[0].PerformClick()
      Assert-Ui ('select role '+$character.Id+' without writes') ($script:SelectedCharacterId -ceq $character.Id -and $script:MockRequests.Count -eq $before)
      Assert-Ui ('dynamic card count '+$character.Id) ($script:Cards.Count -eq $character.Variants.Count)
      $custom=@($character.Variants|Where-Object {$_.Kind -ne 'original' -and $_.Available})[0]
      $before=$script:MockRequests.Count;$previousCurrent=$script:MockInstalled[$character.Id];@($script:Cards|Where-Object VariantId -CEQ $custom.Id)[0].PerformClick()
      Assert-Ui ('selection not installation '+$character.Id) ($script:Selections[$character.Id] -ceq $custom.Id -and $script:MockRequests.Count -eq $before -and $script:MockInstalled[$character.Id] -ceq $previousCurrent)
      $others=@{};foreach($key in $script:MockInstalled.Keys){$others[$key]=$script:MockInstalled[$key]}
      $script:ApplyButton.PerformClick();$request=$script:MockRequests[-1]
      Assert-Ui ('apply role and variant '+$character.Id) ($request.Action -eq 'Install' -and $request.CharacterId -ceq $character.Id -and $request.VariantId -ceq $custom.Id -and $request.ControlsDisabled)
      Assert-Ui ('current marker updated '+$character.Id) (@($script:Cards|Where-Object {$_.Installed -and $_.VariantId -ceq $custom.Id}).Count -eq 1)
      Assert-Ui ('other roles untouched '+$character.Id) (@($others.Keys|Where-Object {$_ -cne $character.Id -and $others[$_] -cne $script:MockInstalled[$_]}).Count -eq 0)
      $check.PerformClick();$request=$script:MockRequests[-1];Assert-Ui ('check-only dispatch '+$character.Id) ($request.Action -eq 'Check' -and $request.CharacterId -ceq $character.Id -and $request.ControlsDisabled)
      @($script:Cards|Where-Object VariantId -CEQ 'original')[0].PerformClick();$script:ApplyButton.PerformClick();Assert-Ui ('original is per-role '+$character.Id) ($script:MockInstalled[$character.Id] -ceq 'original')
    }
    Select-Character 'player';$blocked=@($script:Cards|Where-Object {-not $_.Available})[0];$before=$script:MockRequests.Count;$selected=$script:Selections['player'];$blocked.PerformClick();Select-Variant $blocked.VariantId
    Assert-Ui 'unready card disabled and not selectable' (-not $blocked.Enabled -and $script:Selections['player'] -ceq $selected -and $script:MockRequests.Count -eq $before)
    $script:LockedGamePath=$script:PathBox.Text;$script:Busy=$true;Update-ActionControls;$before=$script:MockRequests.Count;Select-Character 'xiahou-lan';Select-Variant 'natural';Invoke-Action 'Install';$script:PathBox.Text='X:\changed'
    Assert-Ui 'busy prevents role selection path mutation and duplicate requests' ($script:SelectedCharacterId -ceq 'player' -and $script:PathBox.Text -ceq $script:LockedGamePath -and $script:MockRequests.Count -eq $before -and @($script:ActionControls|Where-Object Enabled).Count -eq 0)
    $script:Busy=$false;Update-ActionControls;$script:TestFailNext=$true;$script:ApplyButton.PerformClick()
    Assert-Ui 'error visible and controls recover' (-not $script:Busy -and $script:PathBox.Enabled -and $script:Status.Text -like '*游戏仍在运行*' -and -not $blocked.Enabled)
    $script:TestRecoveryNext=$true;$check.PerformClick();Assert-Ui 'recovery is not reported as applied or launch ready' ($script:Status.Text -like '*待恢复*' -and $script:Status.Text -notlike '*可以*启动*')
    $uninstall.PerformClick();Assert-Ui 'uninstall all has explicit global dispatch' ($script:MockRequests[-1].Action -eq 'Uninstall' -and @($script:MockInstalled.Values|Where-Object {$_ -ne 'original'}).Count -eq 0)
    $script:InstalledState=[pscustomobject]@{Status='Modified';Characters=@([pscustomobject]@{Id='player';State='Unknown';InstalledVariantId=$null})};Update-CurrentMarkers
    Assert-Ui 'unknown state is not shown as original' (@($script:Cards|Where-Object Installed).Count -eq 0)
    Refresh-InstalledState;$before=$script:MockRequests.Count;$script:PathBox.Text='';$script:ApplyButton.PerformClick();Assert-Ui 'empty path stops dispatch' ($script:MockRequests.Count -eq $before -and $script:Status.Text -like '*选择游戏目录*')
    $script:PathBox.Text='D:\SteamLibrary\steamapps\common\LegendOfMortal'
    Assert-Ui 'player seven cards can scroll' ($script:Cards.Count -eq 7 -and $cardGrid.AutoScroll -and $cardGrid.DisplayRectangle.Height -gt $cardGrid.ClientSize.Height)
    foreach($control in @($title,$subtitle,$version,$script:PathBox,$browse,$script:ApplyButton,$check,$uninstall,$tip)) {Assert-Ui ('control fits '+$control.Text) ($control.Parent.ClientRectangle.Contains($control.Bounds))}
    Assert-Ui 'no horizontal overflow' ($layout.Width -le $form.ClientSize.Width -and $cardGrid.HorizontalScroll.Visible -eq $false -and $rolePanel.HorizontalScroll.Visible -eq $false)
    if($PreviewInstalledVariant -ne 'none'){$script:MockInstalled['player']=$PreviewInstalledVariant}
    $rolePanel.AutoScrollPosition=New-Object Drawing.Point(0,0)
    Select-Character $PreviewCharacterId;Refresh-InstalledState -SyncSelection
    $script:Status.Text='界面事件检查已完成。此窗口为模拟示例，不操作游戏。';$script:Status.ForeColor=[Drawing.Color]::FromArgb(70,98,73);$script:OutputBox.Clear();Add-Output '界面事件测试通过；当前安装状态为模拟示例。'
    $report=[ordered]@{Passed=$true;AssertionCount=$assertions.Count;Scope='WinForms events with isolated mock catalog readiness and mock backend. No game reads or writes.';PowerShell=$PSVersionTable.PSVersion.ToString();PreviewSize=$PreviewSize;UiScale=$script:UiScale;Assertions=@($assertions)}
    $reportPath=[IO.Path]::GetFullPath($UiTestReport);[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($reportPath))|Out-Null;[IO.File]::WriteAllText($reportPath,($report|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
    Write-Output ('UI event assertions passed: '+$assertions.Count)
}

try {
    if(-not (Get-Command Get-PortraitCharacters -ErrorAction SilentlyContinue)){throw '管理器组件尚未完整，请使用完整的 v2.0 安装包。'}
    $script:Catalog=Get-PortraitCharacters -PackageRoot $script:PackageRoot
    # Only the isolated event-test backend uses simulated readiness. Real and
    # image-only preview modes always show the catalog's actual availability.
    if($UiTestReport){$script:Catalog=$script:Catalog|ConvertTo-Json -Depth 20|ConvertFrom-Json;foreach($c in $script:Catalog.Characters){foreach($v in $c.Variants){$v.Ready=$true;$v.Available=$true}};$last=$script:Catalog.Characters[0].Variants[-1];$last.Ready=$false;$last.Available=$false;$last.UnavailableReason='测试：素材尚未就绪。'}
    $script:MockInstalled=@{}
    foreach($character in $script:Catalog.Characters){
      $script:Selections[$character.Id]='original';$script:MockInstalled[$character.Id]='original'
      $button=New-Button $character.DisplayName;$button.Tag=$character.Id;$button.Size=New-Object Drawing.Size((S 153),(S 70));$button.Margin=New-Object Windows.Forms.Padding(0,0,0,(S 8));$button.TextAlign='MiddleLeft';$button.Padding=New-Object Windows.Forms.Padding((S 9),0,0,0);$button.AccessibleName='选择角色 '+$character.DisplayName
      $button.Add_Click({param($sender,$eventArgs)Select-Character $sender.Tag});$rolePanel.Controls.Add($button);$script:RoleButtons+=,$button
    }
    if($PreviewInstalledVariant -ne 'none'){$script:MockInstalled['player']=$PreviewInstalledVariant}
    if($script:PreviewMode){$script:PathBox.Text=if($GamePath){$GamePath}else{'D:\SteamLibrary\steamapps\common\LegendOfMortal'};Add-Output '界面预览：不读取或修改真实游戏；未就绪的素材不能应用。'}
    else{$candidates=@(Get-ZhaoHuoSteamCandidates);foreach($candidate in $candidates){[void]$script:PathBox.Items.Add($candidate)};if($GamePath){$script:PathBox.Text=$GamePath}elseif($candidates.Count -eq 1){$script:PathBox.SelectedIndex=0};Add-Output '先选角色，再选外观。应用只影响当前角色；全部卸载会恢复所有角色。'}
    Select-Character $PreviewCharacterId;Refresh-InstalledState -SyncSelection
    $form.ActiveControl=if($InitialAction -eq 'Uninstall'){$uninstall}else{$script:RoleButtons[0]}
    if($script:PreviewMode){
      $form.ShowInTaskbar=$false;$form.StartPosition='Manual';$form.Location=New-Object Drawing.Point(-20000,-20000);$form.Show();[Windows.Forms.Application]::DoEvents();$form.PerformLayout();Resize-Cards;Resize-Roles
      if($UiTestReport){Invoke-UiEventTests}
      if($PreviewPath){$preview=[IO.Path]::GetFullPath($PreviewPath);[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($preview))|Out-Null;$bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height);try{$form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save($preview,[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()};Write-Output 'GUI preview saved; no game action executed.'}
      $form.Close()
    }else{[void]$form.ShowDialog()}
}finally{$refreshTimer.Dispose();$toolTip.Dispose();$form.Dispose()}
