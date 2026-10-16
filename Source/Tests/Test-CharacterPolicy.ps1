#requires -Version 5.1
param([string]$Repository, [Parameter(Mandatory=$true)][string]$EvidenceRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
if (-not $Repository) { $Repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..')) }
$source = Get-Content -LiteralPath (Join-Path $Repository 'Source\CharacterPolicy.cs') -Raw -Encoding UTF8
$wrapper = @'
namespace ZhaoHuoNatural {
 public static class CharacterPolicyProbe {
  public static string Role(string id,string name) { return CharacterPolicy.RoleForIdentity(id,name); }
  public static string Asset(string id,string name,string path) { return CharacterPolicy.ExpressionForIdentityAsset(id,name,path); }
  public static string Path(string root,string relative) { return CharacterPolicy.ContainedPath(root,relative); }
  public static string Portraits(string id) { return CharacterPolicy.PortraitDirectory(id); }
  public static string Layout(string id) { return CharacterPolicy.LayoutPath(id); }
  public static string[] BoundRoles() { return CharacterPolicy.Bindings.Select(x=>x.Id).ToArray(); }
  public static int ResourceCount(string id) { return CharacterPolicy.BindingFor(id).BaseResourceCount; }
  public static bool Replaceable(string id,string expression) { return CharacterPolicy.AllowsExpression(id,expression); }
  public static string Configuration(int schema,string[] ids,bool[] enabled) {
   var c = new CharacterConfiguration { SchemaVersion=schema, Characters=new CharacterSelection[ids.Length] };
   for(int i=0;i<ids.Length;i++) c.Characters[i]=new CharacterSelection {Id=ids[i],Enabled=enabled[i]};
   var roles=CharacterPolicy.EnabledRoles(c); return string.Join(",",System.Linq.Enumerable.OrderBy(roles,x=>x,System.StringComparer.Ordinal).ToArray());
  }
 }
}
'@
Add-Type -TypeDefinition ($source + "`n" + $wrapper) -Language CSharp
$tests = New-Object 'System.Collections.Generic.List[object]'
function Check([string]$Name,[bool]$Passed) { $tests.Add([pscustomobject]@{Name=$Name;Passed=$Passed}) }
function Reject([string]$Name,[scriptblock]$Body) { $rejected=$false; try { & $Body | Out-Null } catch { $rejected=$true }; Check $Name $rejected }
$rootAsset='assets/__project/images/characters/'
$positive=@(
 @('player','唐門_主角','player','player_主角/normal.png'),
 @('player','唐門_主角_自戀','player','player_自戀/normal.png'),
 @('player_young','唐門_主角_少年','player','player_主角/normal.png'),
 @('brother1','唐門_大師兄','tang-buyi','brother1/normal.png'),
 @('brother1_2','唐門_大師兄2','tang-buyi','brother1/normal.png'),
 @('brother1_0','唐門_大師兄_隱','tang-buyi','brother1/normal.png'),
 @('girl6','崆峒_小蘭','xiahou-lan','girl6_小蘭/normal.png'),
 @('girl6_1','崆峒_小蘭_早','xiahou-lan','girl6_小蘭/normal.png')
)
foreach($row in $positive) {
 Check ('identity '+$row[0]+'/'+$row[1]) ([ZhaoHuoNatural.CharacterPolicyProbe]::Role($row[0],$row[1]) -ceq $row[2])
 Check ('asset '+$row[0]+'/'+$row[1]) ([ZhaoHuoNatural.CharacterPolicyProbe]::Asset($row[0],$row[1],$rootAsset+$row[3]) -ceq 'normal')
}
$negative=@(
 @('player_child','唐門_主角_幼年'),@('player_old','主角_老'),@('player','主角媽'),
 @('brother1_young','唐門_大師兄_少年'),@('brother1_1','唐門_大師兄_蒙面'),
 @('brother1_upper','唐門_大師兄上'),@('brother1_lower','唐門_大師兄下'),
 @('girl6_2','崆峒_小蘭_魂'),@('girl6_3','崆峒_小蘭_幼年'),
 @('brother1','唐門_主角'),@('player','唐門_大師兄'),@('girl6','唐門_大師兄'),
 @('brother1_99','唐門_大師兄99'),@('brother1','唐門_大師兄_未核實'),@('PLAYER','唐門_主角')
)
foreach($row in $negative) { Check ('reject identity '+$row[0]+'/'+$row[1]) ([string]::IsNullOrEmpty([ZhaoHuoNatural.CharacterPolicyProbe]::Role($row[0],$row[1]))) }
foreach($role in @(@('player','唐門_主角'),@('brother1','唐門_大師兄'),@('girl6','崆峒_小蘭'))) {
 foreach($path in @('girl6_小蘭_幼年/normal.png','mask1/normal.png','player_主角_魔/normal.png','CG/normal.png','../brother1/normal.png','brother1/sub/normal.png')) {
  Check ('reject asset '+$role[0]+'/'+$path) ([string]::IsNullOrEmpty([ZhaoHuoNatural.CharacterPolicyProbe]::Asset($role[0],$role[1],$rootAsset+$path)))
 }
}
Check 'different character normal cannot cross role' ([string]::IsNullOrEmpty([ZhaoHuoNatural.CharacterPolicyProbe]::Asset('brother1','唐門_大師兄',$rootAsset+'player_主角/normal.png')))
Check 'normal suffix cannot match unknown asset' ([string]::IsNullOrEmpty([ZhaoHuoNatural.CharacterPolicyProbe]::Asset('girl6','崆峒_小蘭',$rootAsset+'girl6_小蘭/fake_normal.png')))
Check 'player young adult normal only' ([string]::IsNullOrEmpty([ZhaoHuoNatural.CharacterPolicyProbe]::Asset('player_young','唐門_主角_少年',$rootAsset+'player_主角/angry1.png')))
Check 'early Lan rejects nonmember droopy' ([string]::IsNullOrEmpty([ZhaoHuoNatural.CharacterPolicyProbe]::Asset('girl6_1','崆峒_小蘭_早',$rootAsset+'girl6_小蘭/droopy.png')))
Check 'Lan soul is original' ([string]::IsNullOrEmpty([ZhaoHuoNatural.CharacterPolicyProbe]::Asset('girl6','崆峒_小蘭',$rootAsset+'girl6_小蘭/soul.png')))
foreach($name in @('normal','angry1','laugh1','nervous1','nervous3')) { Check ('preserve narcissist '+$name) ([ZhaoHuoNatural.CharacterPolicyProbe]::Asset('player','唐門_主角_自戀',$rootAsset+'player_自戀/'+$name+'.png') -ceq $name) }
$expectations=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'CharacterBindingExpectations.json') -Raw -Encoding UTF8|ConvertFrom-Json
$expandedIds=@('player','tang-buyi','xiahou-lan','tang-moling','long-xiang','yu-xiaomei','tang-zheng')
Check 'Exactly seven compiled role bindings' (([ZhaoHuoNatural.CharacterPolicyProbe]::BoundRoles()-join ',')-ceq($expandedIds-join ','))
foreach($role in $expectations.Roles){
 Check ('Verified base resource count '+$role.Id) ([ZhaoHuoNatural.CharacterPolicyProbe]::ResourceCount($role.Id)-eq$role.BaseAssets.Count)
 Check ('Separate portrait folder '+$role.Id) ([ZhaoHuoNatural.CharacterPolicyProbe]::Portraits($role.Id)-ceq('Characters/'+$role.Id+'/Portraits'))
 Check ('Separate layout file '+$role.Id) ([ZhaoHuoNatural.CharacterPolicyProbe]::Layout($role.Id)-ceq('Characters/'+$role.Id+'/portrait-layout.tsv'))
 foreach($path in $role.BaseAssets){
  $expression=[IO.Path]::GetFileNameWithoutExtension($path)
  Check ('Protected original or replaceable resource '+$role.Id+'/'+$expression) ([ZhaoHuoNatural.CharacterPolicyProbe]::Replaceable($role.Id,$expression)-eq($expression -cnotin $role.OriginalOnlyExpressions))
 }
 foreach($identity in $role.AllowedIdentities){
  $label=$role.Id+'/'+$identity.Id+'/'+$identity.Name
  Check ('Verified exact identity '+$label) ([ZhaoHuoNatural.CharacterPolicyProbe]::Role($identity.Id,$identity.Name)-ceq$role.Id)
  Check ('Wrong object name rejected '+$label) ([string]::IsNullOrEmpty([ZhaoHuoNatural.CharacterPolicyProbe]::Role($identity.Id,($identity.Name+'_unverified'))))
  Check ('Wrong game ID rejected '+$label) ([string]::IsNullOrEmpty([ZhaoHuoNatural.CharacterPolicyProbe]::Role(($identity.Id+'_unverified'),$identity.Name)))
  foreach($path in $role.BaseAssets){
   $actual=[ZhaoHuoNatural.CharacterPolicyProbe]::Asset($identity.Id,$identity.Name,$path)
   $expected=if($path -cin $identity.Assets){[IO.Path]::GetFileNameWithoutExtension($path)}else{$null}
   Check ('Identity resource intersection '+$label+'/'+[IO.Path]::GetFileName($path)) ($actual-ceq$expected)
  }
  foreach($otherRole in @($expectations.Roles|Where-Object{$_.Id-cne$role.Id})){
   foreach($path in $otherRole.BaseAssets){Check ('Cross-role blocked '+$label+'/'+$otherRole.Id+'/'+[IO.Path]::GetFileName($path)) ([string]::IsNullOrEmpty([ZhaoHuoNatural.CharacterPolicyProbe]::Asset($identity.Id,$identity.Name,$path)))}
  }
 }
 foreach($identity in $role.RejectedIdentities){
  $label=$role.Id+'/'+$identity.Id+'/'+$identity.Name
  Check ('Special or juvenile identity excluded '+$label) ([string]::IsNullOrEmpty([ZhaoHuoNatural.CharacterPolicyProbe]::Role($identity.Id,$identity.Name)))
  foreach($path in @(@($identity.Assets)+@($role.BaseAssets)|Sort-Object -Unique)){
   Check ('Excluded identity retains original '+$label+'/'+[IO.Path]::GetFileName($path)) ([string]::IsNullOrEmpty([ZhaoHuoNatural.CharacterPolicyProbe]::Asset($identity.Id,$identity.Name,$path)))
  }
 }
}
$ids=@('player','tang-buyi','xiahou-lan')
Check 'all enabled configuration' ([ZhaoHuoNatural.CharacterPolicyProbe]::Configuration(1,$ids,@($true,$true,$true)) -ceq 'player,tang-buyi,xiahou-lan')
Check 'independent original choice' ([ZhaoHuoNatural.CharacterPolicyProbe]::Configuration(1,$ids,@($false,$true,$false)) -ceq 'tang-buyi')
Check 'all original configuration' ([ZhaoHuoNatural.CharacterPolicyProbe]::Configuration(1,$ids,@($false,$false,$false)) -ceq '')
Reject 'reject unknown schema' { [ZhaoHuoNatural.CharacterPolicyProbe]::Configuration(3,$ids,@($true,$true,$true)) }
Check 'schema 2 all seven independent characters' ([ZhaoHuoNatural.CharacterPolicyProbe]::Configuration(2,$expandedIds,@($true,$true,$true,$true,$true,$true,$true))-ceq 'long-xiang,player,tang-buyi,tang-moling,tang-zheng,xiahou-lan,yu-xiaomei')
Reject 'schema 2 cannot reinterpret legacy three entries' { [ZhaoHuoNatural.CharacterPolicyProbe]::Configuration(2,$ids,@($true,$true,$true)) }
Reject 'schema 1 cannot enable a newly added role' { [ZhaoHuoNatural.CharacterPolicyProbe]::Configuration(1,@('player','tang-buyi','tang-moling'),@($true,$true,$true)) }
Reject 'unknown role cannot choose portrait path' { [ZhaoHuoNatural.CharacterPolicyProbe]::Portraits('../player') }
Reject 'unknown role cannot choose layout path' { [ZhaoHuoNatural.CharacterPolicyProbe]::Layout('girl5') }
Reject 'reject incomplete config' { [ZhaoHuoNatural.CharacterPolicyProbe]::Configuration(1,@('player'),@($true)) }
Reject 'reject duplicate config ID' { [ZhaoHuoNatural.CharacterPolicyProbe]::Configuration(1,@('player','player','xiahou-lan'),@($true,$true,$true)) }
Reject 'reject unknown config ID' { [ZhaoHuoNatural.CharacterPolicyProbe]::Configuration(1,@('player','brother2','xiahou-lan'),@($true,$true,$true)) }
Check 'legacy player path retained' ([ZhaoHuoNatural.CharacterPolicyProbe]::Portraits('player') -ceq 'Portraits')
Check 'NPC directory isolation' ([ZhaoHuoNatural.CharacterPolicyProbe]::Portraits('tang-buyi') -ceq 'Characters/tang-buyi/Portraits')
Check 'NPC layout isolation' ([ZhaoHuoNatural.CharacterPolicyProbe]::Layout('xiahou-lan') -ceq 'Characters/xiahou-lan/portrait-layout.tsv')
$fixture = Join-Path $EvidenceRoot ('fixtures-policy-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
foreach($relative in @('..\x.png','Portraits/../x.png','Portraits//x.png','C:\outside.png','\\server\share\x.png','a:stream','./x.png')) { Reject ('reject file path '+$relative) { [ZhaoHuoNatural.CharacterPolicyProbe]::Path($fixture,$relative) } }
Check 'contained PNG path' ([ZhaoHuoNatural.CharacterPolicyProbe]::Path($fixture,'Portraits/normal.png') -ceq (Join-Path $fixture 'Portraits\normal.png'))
$junctionTarget=Join-Path $fixture 'target'; New-Item -ItemType Directory -Path $junctionTarget | Out-Null
$junction=Join-Path $fixture 'linked'; New-Item -ItemType Junction -Path $junction -Target $junctionTarget | Out-Null
Reject 'reject junction before read' { [ZhaoHuoNatural.CharacterPolicyProbe]::Path($fixture,'linked/normal.png') }
$failed=@($tests | Where-Object {-not $_.Passed})
$status='passed'; if($failed.Count){$status='failed'}
function NormalizedHash([string]$Path){$text=[IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF).Replace("`r`n","`n").Replace("`r","`n");$sha=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','')}finally{$sha.Dispose()}}
$report=[pscustomobject]@{Status=$status;Passed=($failed.Count -eq 0);TestCount=$tests.Count;PassedCount=$tests.Count-$failed.Count;PowerShellVersion=$PSVersionTable.PSVersion.ToString();ActualGameRun=$false;Scope='Production character policy compiled unchanged; verified identity/resource metadata, cross-role exclusion, legacy/new schema and file path validation. No game assemblies executed, no game process started, no game files modified.';CodeHashAlgorithm='SHA256-UTF8-noBOM-LF-v1';CodeHashes=@(foreach($path in @('Source/CharacterPolicy.cs','Source/Tests/Test-CharacterPolicy.ps1','Source/Tests/CharacterBindingExpectations.json')){[pscustomobject]@{Path=$path;Sha256=NormalizedHash (Join-Path $Repository $path)}});Tests=$tests.ToArray()}
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'character-policy-tests.json') -Encoding UTF8
$report | Select-Object Status,TestCount,PassedCount,PowerShellVersion | ConvertTo-Json -Compress
if($failed.Count){$failed | ConvertTo-Json; throw 'Character policy test failure.'}
