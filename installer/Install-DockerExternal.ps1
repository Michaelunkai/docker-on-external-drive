[CmdletBinding()]
param(
    [string]$Root = '',
    [switch]$Check,
    [switch]$DryRun,
    [string]$VmName = 'dockerce-hv',
    [string]$SwitchName = 'dockerce-hv-nat',
    [string]$NatName = 'dockerce-hv-nat',
    [string]$HostIp = '10.99.0.1',
    [string]$GuestIp = '10.99.0.2',
    [int]$Prefix = 24,
    [string]$ShareName = 'docker-engine-hv',
    [string]$Snapshot = 'pristine'
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Message) Write-Host ('[install] ' + $Message) -ForegroundColor Cyan }
function Write-Good { param([string]$Message) Write-Host ('[install] OK   ' + $Message) -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host ('[install] WARN ' + $Message) -ForegroundColor Yellow }
function Fail { param([string]$Message) Write-Host ('[install] FAIL ' + $Message) -ForegroundColor Red; throw $Message }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $Check -and -not $DryRun) {
    $extra = ''
    if ($MyInvocation.Line -match '^[^ ]+\s+(.*)$') { $extra = $Matches[1] }
    $argsLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" ' + $extra
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $argsLine -Verb RunAs -Wait | Out-Null
    return
}

$apply = (-not $Check) -and (-not $DryRun)
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
if ([string]::IsNullOrWhiteSpace($Root)) { Fail 'root folder was not supplied and could not be derived from the script path' }
$rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
$backendPath = Join-Path $rootFull 'hv\backend.json'
if (Test-Path -LiteralPath $backendPath -PathType Leaf) {
    try {
        $cfg = Get-Content -LiteralPath $backendPath -Raw | ConvertFrom-Json
        if ($cfg.vm) { $VmName = [string]$cfg.vm }
        if ($cfg.switch) { $SwitchName = [string]$cfg.switch }
        if ($cfg.guest) { $GuestIp = [string]$cfg.guest }
        if ($cfg.share) { $ShareName = [string]$cfg.share }
        if ($cfg.snapshot) { $Snapshot = [string]$cfg.snapshot }
    } catch { Write-Warn ('backend.json could not be read: ' + $_.Exception.Message) }
}

$required = @(
    'bin\dk.exe', 'bin\docker.exe', 'bin\docker-compose.exe', 'bin\docker-credential-desktop.exe',
    'cli\docker.exe', 'cli\config\config.json', 'cli\cli-plugins\docker-compose.exe',
    'cli\cli-plugins\docker-buildx.exe', 'hv\backend.json',
    'hv\disks\dockerce-hv.vhdx', 'hv\disks\dockerce-hv-seed.vhdx',
    'hv\seedfiles\user-data', 'hv\seedfiles\meta-data', 'hv\seedfiles\network-config'
)
foreach ($rel in $required) {
    $full = Join-Path $rootFull $rel
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { Fail ('missing required file: ' + $full) }
}
Write-Good ('all required files present under ' + $rootFull)

$mainVhdx = Join-Path $rootFull 'hv\disks\dockerce-hv.vhdx'
$seedVhdx = Join-Path $rootFull 'hv\disks\dockerce-hv-seed.vhdx'
$vmStore = Join-Path $rootFull 'hv\vm'
$diskStore = Join-Path $rootFull 'hv\disks'
$dk = Join-Path $rootFull 'bin\dk.exe'
$dockerCli = Join-Path $rootFull 'bin\docker.exe'
$env:DOCKER_CONFIG = Join-Path $rootFull 'cli\config'

$credText = Get-Content -LiteralPath (Join-Path $rootFull 'hv\seedfiles\user-data') -Raw
$accountMatch = [regex]::Match($credText, '(?m)^[ \t]*username=([^\r\n]+)')
$passwordMatch = [regex]::Match($credText, '(?m)^[ \t]*password=([^\r\n]+)')
if (-not $accountMatch.Success -or -not $passwordMatch.Success) { Fail 'hv\seedfiles\user-data has no username/password for the guest share' }
$account = $accountMatch.Groups[1].Value.Trim()
$securePassword = ConvertTo-SecureString -String $passwordMatch.Groups[1].Value.Trim() -AsPlainText -Force

Write-Step ('1/9 Hyper-V features and VMMS service, root=' + $rootFull)
$needReboot = $false
foreach ($featureName in @('Microsoft-Hyper-V-All', 'Microsoft-Hyper-V-Hypervisor', 'Microsoft-Hyper-V-Management-PowerShell')) {
    $feature = Get-WindowsOptionalFeature -Online -FeatureName $featureName -ErrorAction SilentlyContinue
    if ($null -eq $feature -or $feature.State -ne 'Enabled') {
        if ($apply) {
            $result = Enable-WindowsOptionalFeature -Online -FeatureName $featureName -NoRestart
            if ($result.RestartNeeded) { $needReboot = $true }
            Write-Good ('enabled ' + $featureName)
        } else { Write-Warn ('would enable ' + $featureName) }
    } else { Write-Good ($featureName + ' already enabled') }
}
$vmms = Get-Service -Name vmms -ErrorAction Stop
if ($vmms.StartType -ne 'Automatic') {
    if ($apply) { Set-Service -Name vmms -StartupType Automatic; Write-Good 'vmms startup set to Automatic' } else { Write-Warn 'would set vmms to Automatic' }
}
if ($vmms.Status -ne 'Running') {
    if ($apply) { Start-Service -Name vmms; Write-Good 'vmms started' } else { Write-Warn 'would start vmms' }
}
if ($needReboot -and $apply) { Write-Warn 'Hyper-V changes need a reboot; run this script again after restart'; exit 3010 }

Write-Step '2/9 VM storage stays on the external drive'
if ($apply) {
    Set-VMHost -VirtualMachinePath $vmStore -VirtualHardDiskPath $diskStore
    Write-Good ('VM path ' + $vmStore)
    Write-Good ('disk path ' + $diskStore)
} else { Write-Warn ('would set VM path ' + $vmStore + ' and disk path ' + $diskStore) }

Write-Step '3/9 internal switch, NAT and localhost forwarding'
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    if ($apply) { New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null; Write-Good ('switch ' + $SwitchName + ' created') } else { Write-Warn ('would create switch ' + $SwitchName) }
}
$vSwitchAdapter = Get-NetAdapter -Name ('vEthernet (' + $SwitchName + ')') -ErrorAction SilentlyContinue
if ($null -eq $vSwitchAdapter) { Fail ('switch adapter vEthernet (' + $SwitchName + ') not found') }
if (-not (Get-NetIPAddress -IPAddress $HostIp -ErrorAction SilentlyContinue)) {
    if ($apply) { New-NetIPAddress -InterfaceIndex $vSwitchAdapter.ifIndex -IPAddress $HostIp -PrefixLength $Prefix | Out-Null; Write-Good ('host ip ' + $HostIp) } else { Write-Warn ('would assign ' + $HostIp) }
} else { Write-Good ('host ip ' + $HostIp + ' already set') }
$natPrefix = $HostIp.Substring(0, $HostIp.LastIndexOf('.')) + '.0/' + $Prefix
if (-not (Get-NetNat -Name $NatName -ErrorAction SilentlyContinue)) {
    if ($apply) { New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $natPrefix | Out-Null; Write-Good ('NAT ' + $natPrefix) } else { Write-Warn ('would create NAT ' + $natPrefix) }
}
$forwardText = (& netsh interface portproxy show v4tov4 2>&1 | Out-String)
if ($forwardText -notmatch [regex]::Escape($GuestIp)) {
    $portproxy = 'interface portproxy add v4tov4 listenaddress=127.0.0.1 listenport=2375 connectaddress=' + $GuestIp + ' connectport=2375'
    if ($apply) { & netsh $portproxy.Split(' ') | Out-Null; Write-Good ('portproxy 127.0.0.1:2375 -> ' + $GuestIp + ':2375') } else { Write-Warn ('would add portproxy to ' + $GuestIp) }
} else { Write-Good 'portproxy already present' }

Write-Step '4/9 guest share account and SMB share (credentials stay on the external drive)'
if (-not (Get-LocalUser -Name $account -ErrorAction SilentlyContinue)) {
    if ($apply) { New-LocalUser -Name $account -Password $securePassword -PasswordNeverExpires -UserMayNotChangePassword | Out-Null; Write-Good ('local account ' + $account + ' created') } else { Write-Warn ('would create local account ' + $account) }
} else {
    if ($apply) { Set-LocalUser -Name $account -Password $securePassword | Out-Null }
    Write-Good ('local account ' + $account + ' present')
}
if (-not (Get-LocalGroupMember -Group Users -Member $account -ErrorAction SilentlyContinue)) {
    if ($apply) { Add-LocalGroupMember -Group Users -Member $account | Out-Null }
}
if ($apply) {
    & icacls $rootFull /grant "${account}:(OI)(CI)F" | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail ('icacls grant failed with exit ' + $LASTEXITCODE) }
}
if (-not (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue)) {
    if ($apply) { New-SmbShare -Name $ShareName -Path $rootFull -FullAccess $account | Out-Null; Write-Good ('share ' + $ShareName + ' created') } else { Write-Warn ('would create share ' + $ShareName) }
} else {
    if ($apply) { Grant-SmbShareAccess -Name $ShareName -AccountName $account -AccessRight Full -Force | Out-Null }
    Write-Good ('share ' + $ShareName + ' present')
}

Write-Step ('5/9 Hyper-V VM ' + $VmName)
$vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
if ($null -eq $vm) {
    if ($apply) {
        New-VM -Name $VmName -Generation 2 -MemoryStartupBytes 2GB -VHDPath $mainVhdx -SwitchName $SwitchName | Out-Null
        Add-VMHardDiskDrive -VMName $VmName -Path $seedVhdx | Out-Null
        Set-VMProcessor -VMName $VmName -Count 2
        Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $false
        Set-VMFirmware -VMName $VmName -EnableSecureBoot Off
        $bootDisk = Get-VMHardDiskDrive -VMName $VmName | Where-Object { $_.Path -ieq $mainVhdx } | Select-Object -First 1
        if ($null -ne $bootDisk) { Set-VMFirmware -VMName $VmName -FirstBootDevice $bootDisk }
        Set-VM -Name $VmName -AutomaticCheckpointsEnabled $false -AutomaticStartAction Start -AutomaticStartDelay 0
        Write-Good ('VM ' + $VmName + ' created from the external-drive disks')
    } else { Write-Warn ('would create VM ' + $VmName + ' from ' + $mainVhdx) }
} else {
    $adapter = Get-VMNetworkAdapter -VMName $VmName -ErrorAction SilentlyContinue
    if ($null -ne $adapter -and $adapter.SwitchName -ne $SwitchName) {
        if ($apply) { Connect-VMNetworkAdapter -VMName $VmName -SwitchName $SwitchName; Write-Good ('VM attached to ' + $SwitchName) } else { Write-Warn ('would attach VM to ' + $SwitchName) }
    } else { Write-Good ('VM ' + $VmName + ' already on ' + $SwitchName) }
    if ($apply) { Set-VM -Name $VmName -AutomaticStartAction Start -AutomaticStartDelay 0 -AutomaticCheckpointsEnabled $false }
}

Write-Step '6/9 global PATH points to the external bin folder only'
$binPath = Join-Path $rootFull 'bin'
foreach ($scope in @('User', 'Machine')) {
    $currentPath = [Environment]::GetEnvironmentVariable('Path', $scope)
    if ([string]::IsNullOrWhiteSpace($currentPath)) { $currentPath = '' }
    $parts = @($currentPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $kept = @($parts | Where-Object { $_.TrimEnd('\') -ine $binPath })
    $newPath = $binPath + ';' + ($kept -join ';')
    if (($parts.Count -gt 0) -and ($parts[0].TrimEnd('\') -ieq $binPath)) { $newPath = $currentPath }
    if ($newPath -ne $currentPath) {
        if ($apply) { [Environment]::SetEnvironmentVariable('Path', $newPath, $scope); Write-Good ($scope + ' PATH updated') } else { Write-Warn ('would update ' + $scope + ' PATH') }
    } else { Write-Good ($scope + ' PATH already correct') }
}
foreach ($name in @('DOCKER_CONFIG', 'DOCKER_HOST')) {
    if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($name, 'User'))) {
        if ($apply) { [Environment]::SetEnvironmentVariable($name, $null, 'User'); Write-Good ('removed user env ' + $name) } else { Write-Warn ('would remove user env ' + $name) }
    }
}

Write-Step '7/9 start VM and wait for the engine'
if ($apply) {
    $liveVm = Get-VM -Name $VmName -ErrorAction Stop
    if ($liveVm.State -ne 'Running') { Start-VM -Name $VmName; Write-Good 'VM started' }
    $deadline = (Get-Date).AddSeconds(240)
    $version = ''
    while ((Get-Date) -lt $deadline) {
        $out = & $dockerCli version --format '{{.Server.Version}}' 2>&1
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$out)) { $version = ([string]$out).Trim(); break }
        Start-Sleep -Seconds 3
    }
    if ([string]::IsNullOrWhiteSpace($version)) { Fail 'Docker did not answer within 240 seconds' }
    Write-Good ('Docker engine ' + $version + ' ready')
} else { Write-Warn 'would start VM and wait for docker version' }

Write-Step '8/9 pristine checkpoint for dkill'
if ($apply) {
    $snap = Get-VMSnapshot -VMName $VmName -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $Snapshot } | Select-Object -First 1
    if ($null -eq $snap) {
        & $dockerCli system prune -af --volumes 2>&1 | Out-Null
        Checkpoint-VM -Name $VmName -SnapshotName $Snapshot
        Write-Good ('snapshot ' + $Snapshot + ' created')
    } else { Write-Good ('snapshot ' + $Snapshot + ' already present') }
} else { Write-Warn ('would ensure snapshot ' + $Snapshot) }

Write-Step '9/9 verification'
$setupOut = & $dk setup --check 2>&1
$setupRc = $LASTEXITCODE
$setupOut | ForEach-Object { Write-Host $_ }
if ($setupRc -ne 0) { Fail 'dk setup --check failed with exit ' + $setupRc }
$versionOut = & $dockerCli version --format '{{.Server.Version}}' 2>&1
if ($LASTEXITCODE -ne 0) { Fail 'docker version failed: ' + ($versionOut -join ' ') }
Write-Good ('Docker ready: YES (server ' + ([string]$versionOut).Trim() + ')')
Write-Good 'installation verified; run dkill to free space and restore the engine in under 10 seconds'
