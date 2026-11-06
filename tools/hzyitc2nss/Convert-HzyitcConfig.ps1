<#
.SYNOPSIS
  Convert an OpenWrt configuration backup taken on an hzyitc ipq50xx build
  (swconfig based) into a configuration for the DSA based Xiaomi CR8806 /
  Redmi AX3000 NSS build.

.DESCRIPTION
  hzyitc/openwrt-redmi-ax3000 uses OpenWrt 23.05.3 with its own "ipq50xx"
  target and a QSDK style switch driver, so /etc/config/network describes the
  switch with "config switch" + "config switch_vlan" and interfaces named
  eth0.N / eth1.N.  The NSS build is upstream qualcommax with DSA: ports are
  named lan1..lan3 and wan, VLANs live in "config bridge-vlan" on br-lan and
  the CPU side is a "conduit".

  Restoring the old backup directly therefore produces a box with no working
  network.  This script reads the backup and writes

      etc/config/network    a complete, converted file
      etc/config/wireless   a complete, converted file
      apply-on-router.sh    one script to run on the router (keeps a backup
                            of the old /etc/config first)
      report.md             what was carried over, dropped, or needs a
                            manual decision

  Nothing is sent anywhere and the router is not touched: the script only
  reads the backup and writes files into -OutDir.

.PARAMETER Backup
  Path to the backup produced by "sysupgrade -b" or by LuCI
  (System > Backup/Flash firmware > Generate archive), e.g.
  backup-OpenWrt-2026-11-06.tar.gz

.PARAMETER OutDir
  Where to write the result.  Default: .\hzyitc2nss-out

.PARAMETER SourceBoard
  Which hzyitc board the backup came from.  "auto" (default) guesses it from
  the switch sections.  redmi-ax3000 covers the Xiaomi CR880x M79 and the
  Redmi AX3000 / CR880x M81.

.PARAMETER Radio2gPath / Radio5gPath
  The "path" of the two radios on the TARGET build.  The defaults are the
  values of the CR8806 NSS build.  Read them on the new firmware with
      uci show wireless | grep path
  after the first boot if your target build differs.

.PARAMETER DropMacAddr
  Do not carry any "macaddr" over.  By default they are kept: the backup
  comes from the same physical unit, and keeping them means the upstream
  DHCP server keeps handing out the same addresses.

.PARAMETER WanConduit
  Which CPU link the standalone wan port uses on the target build: eth1 (the
  board default, shared with the LAN ports) or eth0, the second CPU link, so
  that WAN traffic does not share the LAN conduit.  eth0 only works on a
  build that opens the PHY-to-PHY conduit (this NSS build does); on an
  untouched upstream build the port may stay down.

.PARAMETER WithFirewall
  Also carry /etc/config/firewall (zones, forwardings, rules, redirects).
  Off by default, because the AP style setups this build is used for run
  without a firewall.

.PARAMETER WithCredentials
  Also carry the root password hash (/etc/shadow) and the SSH
  authorized_keys from the backup into apply-on-router.sh, so the new slot
  keeps the same login.  Off by default: it puts the password hash into a
  file on your PC.

.EXAMPLE
  .\Convert-HzyitcConfig.ps1 -Backup .\backup-OpenWrt-2026-11-06.tar.gz

.NOTES
  Windows PowerShell 5.1 or newer, and tar.exe (part of Windows 10 1803+).
  The generated apply-on-router.sh contains the Wi-Fi passphrases from the
  backup: treat it like the backup itself, do not commit or share it.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Backup,
    [string]$OutDir = ".\hzyitc2nss-out",
    [ValidateSet('auto', 'redmi-ax3000', 'cr881x', 'rax3000q')][string]$SourceBoard = 'auto',
    [string]$Radio2gPath = 'platform/soc@0/c000000.wifi',
    [string]$Radio5gPath = 'platform/soc@0/b00a040.wifi',
    [switch]$DropMacAddr,
    [ValidateSet('eth1', 'eth0')][string]$WanConduit = 'eth1',
    [switch]$WithFirewall,
    [switch]$WithCredentials,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# ---------------------------------------------------------------- utilities

$script:Notes = New-Object System.Collections.ArrayList
$script:Warns = New-Object System.Collections.ArrayList

function Add-Note { param([string]$Text) [void]$script:Notes.Add($Text) }
function Add-Warn { param([string]$Text) [void]$script:Warns.Add($Text); Write-Host "  ! $Text" -ForegroundColor Yellow }

function Remove-UciQuotes {
    param([string]$Value)
    $v = $Value.Trim()
    if ($v.Length -ge 2) {
        $f = $v[0]; $l = $v[$v.Length - 1]
        if (($f -eq "'" -and $l -eq "'") -or ($f -eq '"' -and $l -eq '"')) {
            $v = $v.Substring(1, $v.Length - 2)
        }
    }
    return $v.Replace("'\''", "'")
}

function Read-UciFile {
    param([string]$Path)
    $sections = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $Path)) { return $sections }
    $cur = $null
    $counters = @{}
    foreach ($raw in [IO.File]::ReadAllLines($Path)) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        if ($line -match "^config\s+'?([A-Za-z0-9_-]+)'?(?:\s+(.+))?$") {
            $type = $Matches[1]
            $name = $null
            if ($Matches.Count -gt 2 -and $Matches[2]) { $name = Remove-UciQuotes $Matches[2] }
            if (-not $counters.ContainsKey($type)) { $counters[$type] = 0 }
            $idx = $counters[$type]
            $counters[$type] = $idx + 1
            $cur = [ordered]@{
                Type    = $type
                Name    = $name
                Index   = $idx
                Options = [ordered]@{}
                Lists   = [ordered]@{}
            }
            [void]$sections.Add($cur)
            continue
        }
        if ($null -eq $cur) { continue }
        if ($line -match "^(option|list)\s+'?([A-Za-z0-9_.:-]+)'?\s+(.+)$") {
            $kind = $Matches[1]; $key = $Matches[2]; $val = Remove-UciQuotes $Matches[3]
            if ($kind -eq 'option') {
                $cur.Options[$key] = $val
            } else {
                if (-not $cur.Lists.Contains($key)) { $cur.Lists[$key] = (New-Object System.Collections.ArrayList) }
                [void]$cur.Lists[$key].Add($val)
            }
        }
    }
    return $sections
}

function Get-Sections { param($Config, [string]$Type) @($Config | Where-Object { $_.Type -eq $Type }) }
function Get-Opt {
    param($Section, [string]$Key, $Default = $null)
    if ($null -ne $Section -and $Section.Options.Contains($Key)) { return $Section.Options[$Key] }
    return $Default
}
function Get-List {
    param($Section, [string]$Key)
    if ($null -ne $Section -and $Section.Lists.Contains($Key)) { return @($Section.Lists[$Key]) }
    return @()
}
function Quote-Uci { param([string]$Value) "'" + $Value.Replace("'", "'\''") + "'" }

# A "gateway" that the kernel can never install as a next hop on that device is
# worth dropping rather than copying: the old config on the source machine had
# one on a spare port (a leftover of how that box was once wired), it shows up
# in LuCI as "IPv4 Upstream" on an interface that carries nothing, and it turns
# into a second default route the day someone plugs a cable into that port.
function Get-PrefixMask {
    param([int]$Bits)
    $b = @(0, 0, 0, 0)
    for ($j = 0; $j -lt 4; $j++) {
        $take = [Math]::Min(8, [Math]::Max(0, $Bits - 8 * $j))
        $b[$j] = [int](256 - [Math]::Pow(2, 8 - $take)) % 256
        if ($take -eq 0) { $b[$j] = 0 }
    }
    ($b -join '.')
}
function Test-SameSubnet {
    param([string]$A, [string]$B, [string]$Mask)
    try {
        $ab = ([System.Net.IPAddress]::Parse($A)).GetAddressBytes()
        $bb = ([System.Net.IPAddress]::Parse($B)).GetAddressBytes()
        $mb = ([System.Net.IPAddress]::Parse($Mask)).GetAddressBytes()
        for ($j = 0; $j -lt 4; $j++) {
            if (($ab[$j] -band $mb[$j]) -ne ($bb[$j] -band $mb[$j])) { return $false }
        }
        return $true
    } catch { return $true }
}
function Test-KeepGateway {
    param($Section, [string]$Name)
    $gw = Get-Opt $Section 'gateway' ''
    if (-not $gw) { return $false }
    $proto = Get-Opt $Section 'proto' ''
    if ($proto -ne 'static') {
        Add-Note "Interface '$Name' (proto $proto) carried 'option gateway $gw'; netifd does not use it with this proto, so it was left out."
        return $false
    }
    $ip = Get-Opt $Section 'ipaddr' ''
    $mask = Get-Opt $Section 'netmask' ''
    if ($ip -match '^(.+)/(\d+)$') { $ip = $Matches[1]; $mask = Get-PrefixMask ([int]$Matches[2]) }
    if (-not $ip -or -not $mask) { return $true }
    if (Test-SameSubnet $ip $gw $mask) { return $true }
    Add-Note "Interface '$Name': 'option gateway $gw' was left out - it is outside this interface's own subnet ($ip/$mask), so the kernel cannot use it as a next hop on this device. It only showed up as a dead 'IPv4 Upstream' entry, and it would become a second default route if a cable were ever plugged into that port. On an AP the default route comes from the uplink interface (proto dhcp). Put it back by hand if this interface really is the uplink."
    return $false
}

# ------------------------------------------------------------- board tables
# Taken from hzyitc/openwrt-redmi-ax3000,
# target/linux/ipq50xx/base-files/etc/board.d/02_network:
#   redmi,ax3000   : switch1  "6u@eth1" "5u@eth0"  1:lan1 2:lan2 3:lan3 4:wan
#   xiaomi,cr881x  : switch0  "8u@eth1" "4u@eth0"  0:lan1 1:lan2 2:lan3 3:wan
#   cmcc,rax3000q  : switch1  "6u@eth1" "3u@eth0"  2:lan1 4:lan2 5:lan3 1:wan

$BoardMaps = [ordered]@{
    'redmi-ax3000' = @{
        Label  = 'redmi,ax3000 (Xiaomi CR880x M79 / Redmi AX3000 M81)'
        Switch = 'switch1'
        Ports  = @{ '1' = 'lan1'; '2' = 'lan2'; '3' = 'lan3'; '4' = 'wan' }
        CpuDev = @{ '6' = 'eth1'; '5' = 'eth0' }
    }
    'cr881x'       = @{
        Label  = 'xiaomi,cr881x'
        Switch = 'switch0'
        Ports  = @{ '0' = 'lan1'; '1' = 'lan2'; '2' = 'lan3'; '3' = 'wan' }
        CpuDev = @{ '8' = 'eth1'; '4' = 'eth0' }
    }
    'rax3000q'     = @{
        Label  = 'cmcc,rax3000q'
        Switch = 'switch1'
        Ports  = @{ '2' = 'lan1'; '4' = 'lan2'; '5' = 'lan3'; '1' = 'wan' }
        CpuDev = @{ '6' = 'eth1'; '3' = 'eth0' }
    }
}

# Options carried over verbatim per section type.  Anything else is reported.
$IfaceOptions = @(
    'proto', 'ipaddr', 'netmask', 'broadcast', 'gateway', 'metric', 'mtu',
    'ip6addr', 'ip6gw', 'ip6assign', 'ip6hint', 'ip6prefix', 'ip6class',
    'reqaddress', 'reqprefix', 'delegate', 'defaultroute', 'peerdns',
    'auto', 'force_link', 'disabled', 'hostname', 'clientid', 'vendorid',
    'username', 'password', 'ac', 'service', 'keepalive', 'pppd_options',
    'ipv6', 'sourcefilter', 'zone'
)
$IfaceLists = @('dns', 'dns_search', 'ipaddr', 'ip6addr')
$RadioOptions = @(
    'band', 'hwmode', 'channel', 'channels', 'htmode', 'country', 'cell_density',
    'disabled', 'txpower', 'legacy_rates', 'noscan', 'beacon_int', 'distance',
    'log_level', 'country_ie', 'he_bss_color', 'mu_beamformer', 'rts_threshold'
)
$IfaceWifiOptions = @(
    'mode', 'ssid', 'encryption', 'key', 'network', 'ifname', 'hidden', 'isolate',
    'wmm', 'macaddr', 'disabled', 'wpa_disable_eapol_key_retries', 'ieee80211r',
    'ieee80211k', 'ieee80211v', 'ft_over_ds', 'ft_psk_generate_local', 'mobility_domain',
    'bss_transition', 'wnm_sleep_mode', 'time_advertisement', 'dtim_period',
    'max_inactivity', 'short_preamble', 'skip_inactivity_poll', 'multicast_to_unicast',
    'proxy_arp', 'sae_pwe', 'ocv', 'key_mgmt', 'auth_cache', 'ppsk'
)
$DnsmasqOptions = @(
    'domainneeded', 'boguspriv', 'filterwin2k', 'localise_queries', 'rebind_protection',
    'rebind_localhost', 'local', 'domain', 'expandhosts', 'nonegcache', 'cachesize',
    'authoritative', 'readethers', 'leasefile', 'localservice', 'ednspacket_max',
    'filter_aaaa', 'filter_a', 'localuse', 'logqueries', 'noresolv', 'quietdhcp',
    'sequential_ip', 'allservers', 'dnsforwardmax', 'port'
)
$DhcpPoolOptions = @(
    'interface', 'start', 'limit', 'leasetime', 'dynamicdhcp', 'ignore', 'force',
    'ra', 'ra_management', 'ra_default', 'dhcpv6', 'ndp', 'master', 'ra_slaac',
    'networkid', 'dhcpv4'
)
$SystemOptions = @(
    'hostname', 'description', 'notes', 'timezone', 'zonename', 'conloglevel',
    'cronloglevel', 'log_proto', 'log_ip', 'log_port', 'log_size', 'log_file',
    'log_remote', 'log_hostname', 'ttylogin', 'urandom_seed', 'compat_version'
)

# ---------------------------------------------------------------- extraction

Write-Host "hzyitc -> CR8806 NSS config converter" -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $Backup)) { throw "Backup not found: $Backup" }
$BackupItem = Get-Item -LiteralPath $Backup
$tar = Get-Command tar.exe -ErrorAction SilentlyContinue
if (-not $tar) { throw "tar.exe not found. Windows 10 1803 or newer has it in C:\Windows\system32." }

if (Test-Path -LiteralPath $OutDir) {
    if (-not $Force) {
        $existing = @(Get-ChildItem -LiteralPath $OutDir -Force -ErrorAction SilentlyContinue)
        if ($existing.Count -gt 0) { throw "$OutDir is not empty. Use -Force to overwrite, or pick another -OutDir." }
    }
} else {
    [void](New-Item -ItemType Directory -Path $OutDir)
}
$OutDir = (Get-Item -LiteralPath $OutDir).FullName
if ($OutDir -like '\\\\*') {
    Write-Host "  note      $OutDir is a network/WSL path; tar.exe cannot extract into one." -ForegroundColor Yellow
    throw "Run the script with -OutDir on a local drive (e.g. C:\temp\out) - tar.exe cannot chdir into a UNC path."
}
$srcDir = Join-Path $OutDir 'source-config'
if (Test-Path -LiteralPath $srcDir) { Remove-Item -LiteralPath $srcDir -Recurse -Force }
[void](New-Item -ItemType Directory -Path $srcDir)

Write-Host "  reading   $($BackupItem.Name) ($([math]::Round($BackupItem.Length/1KB,1)) KB)"
& $tar.Source -x -z -f $BackupItem.FullName -C $srcDir 2>$null
if ($LASTEXITCODE -ne 0) {
    & $tar.Source -x -f $BackupItem.FullName -C $srcDir
    if ($LASTEXITCODE -ne 0) { throw "tar could not extract $Backup" }
}

$cfgDir = $null
foreach ($cand in @((Join-Path $srcDir 'etc\config'), (Join-Path $srcDir '.\etc\config'))) {
    if (Test-Path -LiteralPath $cand) { $cfgDir = (Get-Item -LiteralPath $cand).FullName; break }
}
if (-not $cfgDir) {
    $hit = Get-ChildItem -LiteralPath $srcDir -Recurse -Directory -Filter 'config' |
        Where-Object { $_.Parent.Name -eq 'etc' } | Select-Object -First 1
    if ($hit) { $cfgDir = $hit.FullName }
}
if (-not $cfgDir) { throw "No etc/config directory inside the backup - is this an OpenWrt backup?" }

$net = @(Read-UciFile (Join-Path $cfgDir 'network'))
$wifi = @(Read-UciFile (Join-Path $cfgDir 'wireless'))
$dhcp = @(Read-UciFile (Join-Path $cfgDir 'dhcp'))
$sys = @(Read-UciFile (Join-Path $cfgDir 'system'))
$drop = @(Read-UciFile (Join-Path $cfgDir 'dropbear'))
$fw = @(Read-UciFile (Join-Path $cfgDir 'firewall'))

$relFile = Join-Path $srcDir 'etc\openwrt_release'
$srcRelease = 'unknown'
if (Test-Path -LiteralPath $relFile) {
    $rel = (Get-Content -LiteralPath $relFile) -join "`n"
    if ($rel -match "DISTRIB_DESCRIPTION='([^']+)'") { $srcRelease = $Matches[1] }
    elseif ($rel -match "DISTRIB_RELEASE='([^']+)'") { $srcRelease = $Matches[1] }
}
$srcHost = Get-Opt (@(Get-Sections $sys 'system') | Select-Object -First 1) 'hostname' 'OpenWrt'
Write-Host "  source    $srcRelease, hostname '$srcHost'"

# ------------------------------------------------------------ board guessing

$switchSections = @(Get-Sections $net 'switch')
$vlanSections = @(Get-Sections $net 'switch_vlan')
if ($vlanSections.Count -eq 0) {
    Add-Warn "The backup has no 'config switch_vlan': either it is not from a swconfig build, or the switch was left at its defaults. The VLAN plan below is then only a guess - check it."
}

$observedPorts = New-Object System.Collections.ArrayList
foreach ($v in $vlanSections) {
    foreach ($tok in ((Get-Opt $v 'ports' '') -split '\s+')) {
        if ($tok -match '^(\d+)') { [void]$observedPorts.Add($Matches[1]) }
    }
}
$observedPorts = @($observedPorts | Sort-Object -Unique)

$board = $SourceBoard
if ($board -eq 'auto') {
    $switchName = Get-Opt ($switchSections | Select-Object -First 1) 'name' (Get-Opt ($switchSections | Select-Object -First 1) 'device' '')
    $cands = @()
    foreach ($k in $BoardMaps.Keys) {
        $m = $BoardMaps[$k]
        $known = @($m.Ports.Keys) + @($m.CpuDev.Keys)
        $bad = @($observedPorts | Where-Object { $known -notcontains $_ })
        $nameOk = ($switchName -eq '' -or $switchName -eq $m.Switch -or ($vlanSections | Where-Object { (Get-Opt $_ 'device' '') -eq $m.Switch }))
        if ($bad.Count -eq 0 -and $nameOk) { $cands += $k }
    }
    if ($cands.Count -eq 1) { $board = $cands[0] }
    elseif ($cands.Count -gt 1) {
        $board = $cands[0]
        Add-Warn "The switch layout fits more than one hzyitc board ($($cands -join ', ')) - a backup does not say which board it came from. Assuming '$board'; if the unit is not a CR880x/AX3000, re-run with -SourceBoard and check the port table in report.md."
    } else {
        $board = 'redmi-ax3000'
        Add-Warn "Could not recognise the switch layout (ports: $($observedPorts -join ' ')); assuming '$board'. Check the VLAN table in report.md."
    }
}
$bm = $BoardMaps[$board]
Write-Host "  board     $($bm.Label)"

# ------------------------------------------------------- source VLAN mapping

# vlan -> @{ Ports = @{ ourName = $true(tagged)/$false }, Cpu = @{ dev = tagged } }
$vlans = [ordered]@{}
foreach ($v in $vlanSections) {
    # "vlan" is the switch's VLAN table slot; the real 802.1Q id is "vid" when present
    $vid = Get-Opt $v 'vid'
    $slot = Get-Opt $v 'vlan'
    if (-not $vid) { $vid = $slot }
    if (-not $vid) { continue }
    if ($slot -and $vid -ne $slot) { Add-Note "Switch VLAN slot $slot carries 802.1Q id $vid; the id was used." }
    if (-not $vlans.Contains($vid)) { $vlans[$vid] = @{ Ports = [ordered]@{}; Cpu = [ordered]@{} } }
    foreach ($tok in ((Get-Opt $v 'ports' '') -split '\s+')) {
        if ($tok -notmatch '^(\d+)([tu]?)\*?$') { continue }
        $p = $Matches[1]; $tagged = ($Matches[2] -eq 't')
        if ($bm.CpuDev.ContainsKey($p)) {
            $vlans[$vid].Cpu[$bm.CpuDev[$p]] = $tagged
        } elseif ($bm.Ports.ContainsKey($p)) {
            $vlans[$vid].Ports[$bm.Ports[$p]] = $tagged
        } else {
            Add-Warn "VLAN $vid refers to switch port $p, which is not a port of $($bm.Label). Skipped."
        }
    }
}

# Which source netdev name belongs to which VLAN (eth1.68, eth1, ...)
$devToVlan = @{}
foreach ($vid in $vlans.Keys) {
    foreach ($cpuDev in $vlans[$vid].Cpu.Keys) {
        $name = if ($vlans[$vid].Cpu[$cpuDev]) { "$cpuDev.$vid" } else { $cpuDev }
        $devToVlan[$name] = $vid
        $devToVlan["$cpuDev.$vid"] = $vid   # some configs tag anyway
    }
}

$srcDevices = Get-Sections $net 'device'
function Resolve-SourceVlans {
    param([string]$DeviceName)
    $out = New-Object System.Collections.ArrayList
    if (-not $DeviceName) { return @() }
    foreach ($d in $DeviceName -split '\s+') {
        $dev = $srcDevices | Where-Object { (Get-Opt $_ 'name' '') -eq $d } | Select-Object -First 1
        if ($dev -and (Get-Opt $dev 'type' '') -eq 'bridge') {
            foreach ($p in (Get-List $dev 'ports')) { foreach ($x in (Resolve-SourceVlans $p)) { [void]$out.Add($x) } }
            continue
        }
        if ($dev -and (Get-Opt $dev 'type' '') -eq '8021q') {
            $base = Get-Opt $dev 'ifname' ''
            $vid = Get-Opt $dev 'vid' ''
            if ($vid -and $base) { [void]$out.Add($vid); continue }
        }
        if ($devToVlan.ContainsKey($d)) { [void]$out.Add($devToVlan[$d]); continue }
        if ($d -match '^(eth\d)\.(\d+)$') { [void]$out.Add($Matches[2]); continue }
        if ($d -match '^br-') { continue }
        if ($vlans.Count -gt 0) { Add-Warn "Could not work out which VLAN device '$d' belongs to." }
    }
    return @($out | Sort-Object -Unique)
}

function Get-LeafDevices {
    param([string]$DeviceName)
    $out = New-Object System.Collections.ArrayList
    if (-not $DeviceName) { return @() }
    foreach ($d in $DeviceName -split '\s+') {
        $dev = $srcDevices | Where-Object { (Get-Opt $_ 'name' '') -eq $d } | Select-Object -First 1
        if ($dev -and (Get-Opt $dev 'type' '') -eq 'bridge') {
            foreach ($p in (Get-List $dev 'ports')) { foreach ($x in (Get-LeafDevices $p)) { [void]$out.Add($x) } }
            continue
        }
        [void]$out.Add($d)
    }
    return @($out | Sort-Object -Unique)
}

# Without any switch VLAN (a stock dumb-AP style config) there is nothing to
# map, so fall back on which CPU port the old device hung off: the LAN CPU
# (eth1) becomes br-lan, the WAN CPU (eth0) becomes the wan port.
function Get-FallbackDevice {
    param([string]$DeviceName)
    $lanCpu = @($bm.CpuDev.Keys | Where-Object { $bm.CpuDev[$_] -eq 'eth1' } | ForEach-Object { $bm.CpuDev[$_] })
    $leaves = @(Get-LeafDevices $DeviceName)
    $hasLan = @($leaves | Where-Object { $_ -match '^eth1(\.|$)' }).Count -gt 0
    $hasWan = @($leaves | Where-Object { $_ -match '^eth0(\.|$)' }).Count -gt 0
    if ($hasLan -and $hasWan) { return 'br-lan+wan' }
    if ($hasLan) { return 'br-lan' }
    if ($hasWan) { return 'wan' }
    return $null
}

# Which VLAN is a pure WAN VLAN (its only user port is the wan port)?
$wanVlans = New-Object System.Collections.ArrayList
foreach ($vid in $vlans.Keys) {
    $ports = @($vlans[$vid].Ports.Keys)
    if ($ports.Count -eq 1 -and $ports[0] -eq 'wan') { [void]$wanVlans.Add($vid) }
}

# ------------------------------------------------- build the target network

$srcIfaces = @(Get-Sections $net 'interface' | Where-Object { $_.Name -and $_.Name -ne 'loopback' })
$ifacePlan = New-Object System.Collections.ArrayList   # name, vlan, fallback, section, proto
$script:bridgeWanPort = $false
foreach ($i in $srcIfaces) {
    $devName = Get-Opt $i 'device' (Get-Opt $i 'ifname' '')
    $proto = Get-Opt $i 'proto' 'none'
    if ($devName -match '^(wg|tun|tap|@|6in4|ppp)') {
        Add-Warn "Interface '$($i.Name)' uses device '$devName' (tunnel/overlay) and was skipped - recreate it by hand."
        continue
    }
    $vl = @(Resolve-SourceVlans $devName)
    if ($vl.Count -eq 0) {
        $fb = Get-FallbackDevice $devName
        if (-not $fb) {
            if (-not $devName) {
                Add-Note "Interface '$($i.Name)' (proto $proto) has no device at all in the backup - a leftover default that did nothing; skipped."
            } else {
                Add-Warn "Interface '$($i.Name)' (device '$devName', proto $proto) could not be mapped to a port and was skipped."
            }
            continue
        }
        if ($fb -eq 'br-lan+wan') {
            $script:bridgeWanPort = $true
            $fb = 'br-lan'
            Add-Note "Interface '$($i.Name)' bridged the LAN and the WAN port on the old build, so the wan port was added to br-lan."
        }
        Add-Note "Interface '$($i.Name)' has no switch VLAN in the backup; it was put on '$fb'."
        [void]$ifacePlan.Add(@{ Name = $i.Name; Vlan = $null; Fallback = $fb; Section = $i; Proto = $proto })
        continue
    }
    if ($vl.Count -gt 1) {
        Add-Warn "Interface '$($i.Name)' spans VLANs $($vl -join ','); using the first one ($($vl[0]))."
    }
    [void]$ifacePlan.Add(@{ Name = $i.Name; Vlan = $vl[0]; Fallback = $null; Section = $i; Proto = $proto })
}

$usedVlans = @($ifacePlan | Where-Object { $_.Vlan } | ForEach-Object { $_.Vlan } | Sort-Object -Unique)
$bridgeVlans = @($usedVlans | Where-Object { $wanVlans -notcontains $_ })
# a VLAN with no interface but with user ports is still a trunk member worth keeping
foreach ($vid in $vlans.Keys) {
    if ($usedVlans -notcontains $vid -and @($vlans[$vid].Ports.Keys).Count -gt 0 -and $wanVlans -notcontains $vid) {
        $bridgeVlans += $vid
        Add-Note "VLAN $vid has switch ports but no interface in the backup; it was kept on br-lan as a trunk member."
    }
}
$bridgeVlans = @($bridgeVlans | Sort-Object -Unique)

$bridgePorts = New-Object System.Collections.ArrayList
foreach ($vid in $bridgeVlans) {
    foreach ($p in $vlans[$vid].Ports.Keys) { if ($bridgePorts -notcontains $p) { [void]$bridgePorts.Add($p) } }
}
if ($bridgePorts.Count -eq 0) { foreach ($p in @('lan1', 'lan2', 'lan3')) { [void]$bridgePorts.Add($p) } ; Add-Note "No LAN ports were found in the backup, so br-lan was given the default lan1 lan2 lan3." }
if ($script:bridgeWanPort -and $bridgePorts -notcontains 'wan') { [void]$bridgePorts.Add('wan') }
$portOrder = @{ 'lan1' = 1; 'lan2' = 2; 'lan3' = 3; 'wan' = 4 }
$bridgePorts = @($bridgePorts | Sort-Object { $portOrder[$_] })

$needVlanFiltering = ($bridgeVlans.Count -gt 1)
if (-not $needVlanFiltering) {
    foreach ($vid in $bridgeVlans) { foreach ($p in $vlans[$vid].Ports.Keys) { if ($vlans[$vid].Ports[$p]) { $needVlanFiltering = $true } } }
}

# macaddr of the old bridge / VLAN devices, to keep DHCP leases stable
function Get-SourceMac {
    param([string]$IfaceName, [string]$Vlan)
    if ($DropMacAddr) { return $null }
    $i = $srcIfaces | Where-Object { $_.Name -eq $IfaceName } | Select-Object -First 1
    $m = Get-Opt $i 'macaddr'
    if ($m) { return $m }
    foreach ($d in $srcDevices) {
        $n = Get-Opt $d 'name' ''
        $mm = Get-Opt $d 'macaddr'
        if (-not $mm) { continue }
        if ($n -match "\.$Vlan`$" -or ($devToVlan.ContainsKey($n) -and $devToVlan[$n] -eq $Vlan)) { return $mm }
    }
    return $null
}

$sb = New-Object System.Text.StringBuilder
function W { param([string]$Text = '') [void]$sb.AppendLine($Text) }

W "# Generated by Convert-HzyitcConfig.ps1 from $($BackupItem.Name)"
W "# Source: $srcRelease on $($bm.Label) (swconfig) -> DSA"
W ""
W "config interface 'loopback'"
W "`toption device 'lo'"
W "`toption proto 'static'"
W "`toption ipaddr '127.0.0.1'"
W "`toption netmask '255.0.0.0'"
W ""
$g = @(Get-Sections $net 'globals') | Select-Object -First 1
$globalOpts = @(@('ula_prefix', 'packet_steering') | Where-Object { Get-Opt $g $_ })
if ($globalOpts.Count -gt 0) {
    W "config globals 'globals'"
    foreach ($k in $globalOpts) { W "`toption $k $(Quote-Uci (Get-Opt $g $k))" }
    W ""
}
W "config device"
W "`toption name 'br-lan'"
W "`toption type 'bridge'"
foreach ($p in $bridgePorts) { W "`tlist ports '$p'" }
$brMac = $null
foreach ($d in $srcDevices) { if ((Get-Opt $d 'name' '') -eq 'br-lan' -and (Get-Opt $d 'macaddr')) { $brMac = Get-Opt $d 'macaddr' } }
if ($brMac -and -not $DropMacAddr) { W "`toption macaddr '$brMac'" }
W ""

$emittedVlanDev = New-Object System.Collections.ArrayList
if ($needVlanFiltering) {
    foreach ($vid in $bridgeVlans) {
        W "config bridge-vlan"
        W "`toption device 'br-lan'"
        W "`toption vlan '$vid'"
        foreach ($p in $bridgePorts) {
            if (-not $vlans[$vid].Ports.Contains($p)) { continue }
            if ($vlans[$vid].Ports[$p]) { W "`tlist ports '${p}:t'" } else { W "`tlist ports '${p}:u*'" }
        }
        W ""
    }
    foreach ($plan in $ifacePlan) {
        if (-not $plan.Vlan -or ($wanVlans -contains $plan.Vlan)) { continue }
        $devName = "br-lan.$($plan.Vlan)"
        if ($emittedVlanDev -contains $devName) { continue }
        [void]$emittedVlanDev.Add($devName)
        W "config device"
        W "`toption name '$devName'"
        W "`toption type '8021q'"
        W "`toption ifname 'br-lan'"
        W "`toption vid '$($plan.Vlan)'"
        $mac = Get-SourceMac $plan.Name $plan.Vlan
        if ($mac) { W "`toption macaddr '$mac'" }
        else { W "`t# option macaddr 'xx:xx:xx:xx:xx:xx'  # see report.md: one MAC per VLAN keeps DHCP sane" }
        W ""
    }
}

if (@($ifacePlan | Where-Object { ($wanVlans -contains $_.Vlan) -or ($_.Fallback -eq 'wan') }).Count -gt 0 -or $bridgePorts -notcontains 'wan') {
    W "config device"
    W "`toption name 'wan'"
    W "`toption conduit '$WanConduit'"
    W ""
    Add-Note "The wan port is standalone and was given 'option conduit $WanConduit'. eth1 is the board default; -WanConduit eth0 gives WAN its own CPU link (2 x 1 Gbit total), which needs a build that brings the PHY-to-PHY conduit up."
}

# MAC overrides that belong to a netdev of their own (typically the Wi-Fi
# interfaces, "config device" + "option macaddr" with no type): carry them, the
# name is chosen by the wireless config and survives the conversion.
if (-not $DropMacAddr) {
    foreach ($d in $srcDevices) {
        $n = Get-Opt $d 'name' ''
        $m = Get-Opt $d 'macaddr'
        if (-not $n -or -not $m) { continue }
        if ((Get-Opt $d 'type' '') -ne '') { continue }
        if ($n -match '^(br-|eth\d|lan\d|wan$|lo$)') {
            Add-Note "MAC override for device '$n' was left out: that name belongs to the hardware layout, which differs between the two builds."
            continue
        }
        W "config device"
        W "`toption name '$n'"
        W "`toption macaddr '$m'"
        W ""
    }
}

foreach ($plan in $ifacePlan) {
    $i = $plan.Section
    $dev = if (-not $plan.Vlan) { $plan.Fallback }
           elseif ($wanVlans -contains $plan.Vlan) { 'wan' }
           elseif ($needVlanFiltering) { "br-lan.$($plan.Vlan)" }
           else { 'br-lan' }
    W "config interface '$($plan.Name)'"
    W "`toption device '$dev'"
    foreach ($k in $IfaceOptions) {
        if (-not $i.Options.Contains($k)) { continue }
        if ($k -eq 'gateway' -and -not (Test-KeepGateway $i $plan.Name)) { continue }
        W "`toption $k $(Quote-Uci $i.Options[$k])"
    }
    foreach ($k in $IfaceLists) {
        foreach ($v in (Get-List $i $k)) { W "`tlist $k $(Quote-Uci $v)" }
    }
    $skipped = @($i.Options.Keys | Where-Object { $IfaceOptions -notcontains $_ -and @('device', 'ifname', 'type', 'macaddr') -notcontains $_ })
    if ($skipped.Count -gt 0) { Add-Note "Interface '$($plan.Name)': options not carried over: $($skipped -join ', ')." }
    if ((Get-Opt $i 'proto' '') -eq 'pppoe') { Add-Note "Interface '$($plan.Name)' uses PPPoE; the NSS build ships ppp and ppp-mod-pppoe, so it works, but check username/password." }
    W ""
}

$netText = $sb.ToString()

# ------------------------------------------------- build the target wireless

$sb = New-Object System.Text.StringBuilder
W "# Generated by Convert-HzyitcConfig.ps1 from $($BackupItem.Name)"
W "# Radios are matched by band, never by their old radio number or path."
W ""

$srcRadios = @(Get-Sections $wifi 'wifi-device')
$bandOf = @{}
foreach ($r in $srcRadios) {
    $band = Get-Opt $r 'band'
    if (-not $band) {
        $hw = Get-Opt $r 'hwmode' ''
        $ch = Get-Opt $r 'channel' ''
        if ($hw -match '11a' -or ($ch -match '^\d+$' -and [int]$ch -gt 14)) { $band = '5g' } else { $band = '2g' }
    }
    $bandOf[$r.Name] = $band
}
$radioName = @{}   # old radio name -> new radio name
$byBand = @{}
foreach ($r in $srcRadios) { if (-not $byBand.ContainsKey($bandOf[$r.Name])) { $byBand[$bandOf[$r.Name]] = $r } }
if (-not $byBand.ContainsKey('2g')) { Add-Warn "No 2.4 GHz radio found in the backup; radio0 was left out." }
if (-not $byBand.ContainsKey('5g')) { Add-Warn "No 5 GHz radio found in the backup; radio1 was left out." }

$targets = @(
    @{ New = 'radio0'; Band = '2g'; Path = $Radio2gPath; DefHt = 'HE20'; DefCh = '1' },
    @{ New = 'radio1'; Band = '5g'; Path = $Radio5gPath; DefHt = 'HE80'; DefCh = '36' }
)
foreach ($t in $targets) {
    if (-not $byBand.ContainsKey($t.Band)) { continue }
    $r = $byBand[$t.Band]
    $radioName[$r.Name] = $t.New
    W "config wifi-device '$($t.New)'"
    W "`toption type 'mac80211'"
    W "`toption path '$($t.Path)'"
    W "`toption band '$($t.Band)'"
    $ht = Get-Opt $r 'htmode' $t.DefHt
    $htNew = $ht -replace '^(VHT|HT)', 'HE'
    if ($htNew -ne $ht) { Add-Note "Radio $($t.New): htmode $ht -> $htNew (ath11k is 802.11ax; keep the old value if you prefer)." }
    W "`toption htmode '$htNew'"
    W "`toption channel $(Quote-Uci (Get-Opt $r 'channel' $t.DefCh))"
    foreach ($k in $RadioOptions) {
        if (@('band', 'hwmode', 'htmode', 'channel') -contains $k) { continue }
        if (-not $r.Options.Contains($k)) { continue }
        W "`toption $k $(Quote-Uci $r.Options[$k])"
    }
    if (-not $r.Options.Contains('country')) { Add-Warn "Radio $($t.New) has no country code; set one (e.g. VN) or 160 MHz and the upper channels stay unavailable." }
    W ""
}

$ifaceCount = 0
foreach ($w in @(Get-Sections $wifi 'wifi-iface')) {
    $oldDev = Get-Opt $w 'device' ''
    if (-not $radioName.ContainsKey($oldDev)) {
        Add-Warn "SSID '$(Get-Opt $w 'ssid' '(unnamed)')' belongs to radio '$oldDev', which has no counterpart on the target; skipped."
        continue
    }
    $name = if ($w.Name) { $w.Name } else { "wifinet$ifaceCount" }
    $ifaceCount++
    W "config wifi-iface '$name'"
    W "`toption device '$($radioName[$oldDev])'"
    foreach ($k in $IfaceWifiOptions) {
        if (-not $w.Options.Contains($k)) { continue }
        if ($k -eq 'macaddr' -and $DropMacAddr) { continue }
        W "`toption $k $(Quote-Uci $w.Options[$k])"
    }
    $netRef = Get-Opt $w 'network' ''
    foreach ($n in ($netRef -split '\s+')) {
        if ($n -and -not ($ifacePlan | Where-Object { $_.Name -eq $n })) {
            Add-Warn "SSID '$(Get-Opt $w 'ssid' '(unnamed)')' is attached to network '$n', which does not exist in the converted network config."
        }
    }
    W ""
}
$wifiText = $sb.ToString()

# ------------------------------------------------------------- apply script

$sb = New-Object System.Text.StringBuilder
W "#!/bin/sh"
W "# Generated by Convert-HzyitcConfig.ps1 from $($BackupItem.Name)."
W "# Run this ON the router, after flashing the NSS build and WITHOUT"
W "# restoring the old backup.  It keeps a copy of the current /etc/config."
W "#"
W "# It does NOT restart the network by itself: check the files first, then"
W "# run the two commands it prints at the end."
W ""
W "set -e"
W '[ -f /etc/config/network ] || { echo "This is not an OpenWrt box"; exit 1; }'
W 'B=/root/config-before-convert-$(date +%Y%m%d-%H%M%S)'
W 'mkdir -p "$B"'
W 'cp -a /etc/config "$B"/'
W 'echo "old config saved in $B"'
W ""
W "cat > /etc/config/network <<'EOF_NETWORK'"
[void]$sb.Append($netText)
W "EOF_NETWORK"
W ""
W "cat > /etc/config/wireless <<'EOF_WIRELESS'"
[void]$sb.Append($wifiText)
W "EOF_WIRELESS"
W ""
W "chmod 600 /etc/config/wireless"
W ""

# system
$sysSec = @(Get-Sections $sys 'system') | Select-Object -First 1
if ($sysSec) {
    W "# --- system"
    foreach ($k in $SystemOptions) {
        if (-not $sysSec.Options.Contains($k)) { continue }
        W "uci set system.@system[0].$k=$(Quote-Uci $sysSec.Options[$k])"
    }
    W "uci commit system"
    W ""
}
$ntp = @(Get-Sections $sys 'timeserver') | Select-Object -First 1
if ($ntp) {
    $servers = @(Get-List $ntp 'server')
    if ($servers.Count -gt 0) {
        W "# --- ntp"
        W "uci -q delete system.ntp.server"
        foreach ($s in $servers) { W "uci add_list system.ntp.server=$(Quote-Uci $s)" }
        W "uci commit system"
        W ""
    }
}

# dhcp: dnsmasq options, pools for interfaces that exist, static leases
$dnsmasqSec = @(Get-Sections $dhcp 'dnsmasq') | Select-Object -First 1
if ($dnsmasqSec) {
    W "# --- dnsmasq"
    foreach ($k in $DnsmasqOptions) {
        if (-not $dnsmasqSec.Options.Contains($k)) { continue }
        W "uci set dhcp.@dnsmasq[0].$k=$(Quote-Uci $dnsmasqSec.Options[$k])"
    }
    foreach ($k in @('server', 'address', 'ipset', 'rebind_domain', 'notinterface')) {
        $vals = @(Get-List $dnsmasqSec $k)
        if ($vals.Count -eq 0) { continue }
        W "uci -q delete dhcp.@dnsmasq[0].$k"
        foreach ($v in $vals) { W "uci add_list dhcp.@dnsmasq[0].$k=$(Quote-Uci $v)" }
    }
    W ""
}
$poolCount = 0
foreach ($d in @(Get-Sections $dhcp 'dhcp')) {
    $iface = Get-Opt $d 'interface' ''
    if ($iface -and -not ($ifacePlan | Where-Object { $_.Name -eq $iface })) {
        Add-Note "DHCP pool for '$iface' was skipped: that interface does not exist after the conversion."
        continue
    }
    $sec = if ($d.Name) { "dhcp.$($d.Name)" } else { "dhcp.pool$poolCount" }
    $poolCount++
    W "# --- dhcp pool $iface"
    W "uci -q delete $sec"
    W "uci set $sec=dhcp"
    foreach ($k in $DhcpPoolOptions) {
        if (-not $d.Options.Contains($k)) { continue }
        W "uci set $sec.$k=$(Quote-Uci $d.Options[$k])"
    }
    foreach ($v in (Get-List $d 'dhcp_option')) { W "uci add_list $sec.dhcp_option=$(Quote-Uci $v)" }
    W ""
}
$hostCount = 0
$hosts = @(Get-Sections $dhcp 'host')
if ($hosts.Count -gt 0) {
    W "# --- static leases ($($hosts.Count))"
    foreach ($h in $hosts) {
        $sec = if ($h.Name) { "dhcp.$($h.Name)" } else { "dhcp.lease$hostCount" }
        $hostCount++
        W "uci -q delete $sec"
        W "uci set $sec=host"
        foreach ($k in @('name', 'ip', 'mac', 'dns', 'leasetime', 'duid', 'hostid', 'tag', 'instance')) {
            if (-not $h.Options.Contains($k)) { continue }
            W "uci set $sec.$k=$(Quote-Uci $h.Options[$k])"
        }
        foreach ($v in (Get-List $h 'mac')) { W "uci add_list $sec.mac=$(Quote-Uci $v)" }
    }
    W ""
}
if ($dhcp.Count -gt 0) { W "uci commit dhcp"; W "" }

# dropbear
$dropSec = @(Get-Sections $drop 'dropbear') | Select-Object -First 1
if ($dropSec) {
    W "# --- dropbear"
    foreach ($k in @('enable', 'Port', 'PasswordAuth', 'RootPasswordAuth', 'Interface', 'GatewayPorts', 'IdleTimeout', 'MaxAuthTries')) {
        if (-not $dropSec.Options.Contains($k)) { continue }
        W "uci set dropbear.@dropbear[0].$k=$(Quote-Uci $dropSec.Options[$k])"
    }
    W "uci commit dropbear"
    W ""
}

if ($WithFirewall -and $fw.Count -gt 0) {
    W "# --- firewall (carried over because -WithFirewall was given)"
    $idx = @{}
    foreach ($s in $fw) {
        if ($s.Type -eq 'defaults') {
            foreach ($k in $s.Options.Keys) { W "uci set firewall.@defaults[0].$k=$(Quote-Uci $s.Options[$k])" }
            continue
        }
        if (-not $idx.ContainsKey($s.Type)) { $idx[$s.Type] = 0 }
        $n = $idx[$s.Type]; $idx[$s.Type] = $n + 1
        $sec = if ($s.Name) { "firewall.$($s.Name)" } else { "firewall.cv_$($s.Type)_$n" }
        W "uci -q delete $sec"
        W "uci set $sec=$($s.Type)"
        foreach ($k in $s.Options.Keys) { W "uci set $sec.$k=$(Quote-Uci $s.Options[$k])" }
        foreach ($k in $s.Lists.Keys) {
            foreach ($v in (Get-List $s $k)) {
                if ($k -eq 'network' -and -not ($ifacePlan | Where-Object { $_.Name -eq $v })) {
                    Add-Note "Firewall $($s.Type) '$($s.Name)': network '$v' does not exist after the conversion and was left out."
                    continue
                }
                W "uci add_list $sec.$k=$(Quote-Uci $v)"
            }
        }
    }
    W "uci commit firewall"
    W ""
} elseif ($fw.Count -gt 0) {
    Add-Note "The backup contains a firewall config. It was NOT carried over (pass -WithFirewall if you want it); the AP style setup of this build runs with the firewall service disabled."
}

if ($WithCredentials) {
    $shadowFile = Join-Path $srcDir 'etc\shadow'
    $rootHash = $null
    $rootAge = ''
    if (Test-Path -LiteralPath $shadowFile) {
        foreach ($l in [IO.File]::ReadAllLines($shadowFile)) {
            if ($l -match '^root:([^:]*):([^:]*):') { $rootHash = $Matches[1]; $rootAge = $Matches[2] }
        }
    }
    if ($rootHash -and $rootHash -ne '' -and $rootHash -ne '*' -and $rootHash -ne '!') {
        W "# --- root password (same as on the old build)"
        $hashEsc = $rootHash.Replace('|', '\|')
        W "sed -i 's|^root:[^:]*:[^:]*:|root:${hashEsc}:${rootAge}:|' /etc/shadow"
        W ""
        Add-Note "The root password hash was copied into apply-on-router.sh (-WithCredentials). Keep that file private."
    } else {
        Add-Warn "-WithCredentials was given but no usable root hash was found in the backup (etc/shadow)."
    }
    $akFile = Join-Path $srcDir 'etc\dropbear\authorized_keys'
    if (Test-Path -LiteralPath $akFile) {
        $keys = @([IO.File]::ReadAllLines($akFile) | Where-Object { $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') })
        if ($keys.Count -gt 0) {
            W "# --- SSH authorized_keys ($($keys.Count))"
            W "mkdir -p /etc/dropbear"
            W "touch /etc/dropbear/authorized_keys"
            foreach ($k in $keys) {
                $q = $k.Replace("'", "'\''")
                W "grep -qxF '$q' /etc/dropbear/authorized_keys || echo '$q' >> /etc/dropbear/authorized_keys"
            }
            W "chmod 600 /etc/dropbear/authorized_keys"
            W ""
            Add-Note "$($keys.Count) SSH key(s) from the backup are added by apply-on-router.sh."
        }
    }
    Add-Note "The dropbear HOST keys were not touched: a new host key only makes your SSH client warn once. Copy source-config\etc\dropbear\dropbear_*_host_key by hand if you want the old fingerprint."
} else {
    Add-Note "Root password and SSH keys were NOT carried over (pass -WithCredentials for that). They are in source-config\etc\shadow and source-config\etc\dropbear\."
}

W 'echo'
W 'echo "Done. Nothing has been restarted yet. Check:"'
W 'echo "  cat /etc/config/network"'
W 'echo "  cat /etc/config/wireless"'
W 'echo "Then apply:"'
W 'echo "  /etc/init.d/network restart && sleep 5 && wifi reload"'
W 'echo "If you lose access, boot the other slot:"'
W 'echo "  fw_setenv flag_last_success <other>; fw_setenv flag_boot_rootfs <other>; reboot"'
$applyText = $sb.ToString()

# ------------------------------------------------------------------- report

$sb = New-Object System.Text.StringBuilder
W "# hzyitc -> CR8806 NSS: config conversion report"
W ""
W "- Backup: ``$($BackupItem.Name)``"
W "- Source build: $srcRelease"
W "- Source board: $($bm.Label) (switch: $($bm.Switch))"
W "- Hostname: $srcHost"
W "- Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
W ""
W "## Port mapping"
W ""
W "| hzyitc switch port | this build |"
W "|---|---|"
foreach ($p in ($bm.Ports.Keys | Sort-Object)) { W "| $p | $($bm.Ports[$p]) |" }
foreach ($p in ($bm.CpuDev.Keys | Sort-Object)) { W "| $p (CPU, $($bm.CpuDev[$p])) | conduit, handled by DSA |" }
W ""
W "## VLAN plan"
W ""
if ($vlans.Count -eq 0) {
    W "The backup has no switch VLANs."
} else {
    W "| VLAN | ports in the backup | result |"
    W "|---|---|---|"
    foreach ($vid in $vlans.Keys) {
        $pl = @()
        foreach ($p in $vlans[$vid].Ports.Keys) { $pl += ($p + $(if ($vlans[$vid].Ports[$p]) { ':t' } else { ':u' })) }
        foreach ($c in $vlans[$vid].Cpu.Keys) { $pl += ($c + $(if ($vlans[$vid].Cpu[$c]) { '(tagged CPU)' } else { '(CPU)' })) }
        $res = if ($wanVlans -contains $vid) { "interface on device ``wan`` (conduit eth0)" }
               elseif ($bridgeVlans -contains $vid) { if ($needVlanFiltering) { "bridge-vlan $vid on br-lan" } else { "plain br-lan, no VLAN filtering" } }
               else { "not used" }
        W "| $vid | $($pl -join ' ') | $res |"
    }
}
W ""
W "## Interfaces"
W ""
if ($ifacePlan.Count -eq 0) { W "None could be mapped - check the warnings." } else {
    W "| name | proto | device after conversion |"
    W "|---|---|---|"
    foreach ($plan in $ifacePlan) {
        $dev = if (-not $plan.Vlan) { $plan.Fallback }
               elseif ($wanVlans -contains $plan.Vlan) { 'wan' }
               elseif ($needVlanFiltering) { "br-lan.$($plan.Vlan)" }
               else { 'br-lan' }
        W "| $($plan.Name) | $($plan.Proto) | $dev |"
    }
}
W ""
W "## Wi-Fi"
W ""
W "| SSID | mode | encryption | radio before | radio after |"
W "|---|---|---|---|---|"
foreach ($w in @(Get-Sections $wifi 'wifi-iface')) {
    $oldDev = Get-Opt $w 'device' ''
    $new = if ($radioName.ContainsKey($oldDev)) { $radioName[$oldDev] } else { 'skipped' }
    W "| $(Get-Opt $w 'ssid' '(unnamed)') | $(Get-Opt $w 'mode' '') | $(Get-Opt $w 'encryption' '') | $oldDev | $new |"
}
W ""
W "Passphrases were carried over into ``apply-on-router.sh`` and are not printed here."
W ""
W "## Not carried over"
W ""
W "- ``config switch`` / ``config switch_vlan``: swconfig does not exist on a DSA build; the VLANs became ``bridge-vlan`` sections."
W "- ``/etc/config/system`` LED sections and ``/etc/config/led``: the LED names differ between the two builds."
W "- ``/etc/shadow`` (root password), ``/etc/dropbear/`` (host keys and authorized_keys), ``/etc/rc.local``, ``/etc/hosts``, ``/etc/sysctl.conf``, ``/etc/crontabs``: these are in the backup and were extracted to ``source-config\etc\``. They do not depend on the config format, so copy them by hand, or re-run with ``-WithCredentials`` to have the root hash and authorized_keys put into the apply script."
W "- Package configs that only exist on the old build (qca-ssdk/NSS knobs, old luci settings)."
W ""
if ($script:Warns.Count -gt 0) {
    W "## Warnings"
    W ""
    foreach ($w in $script:Warns) { W "- $w" }
    W ""
}
if ($script:Notes.Count -gt 0) {
    W "## Notes"
    W ""
    foreach ($n in $script:Notes) { W "- $n" }
    W ""
}
W "## How to use the result"
W ""
W "1. Flash the NSS build into the slot that is **not** running (``ubiformat`` + ``fw_setenv``), do **not** restore the old backup."
W "2. Copy the script to the router (OpenWrt has no sftp-server, so ``scp`` does not work):"
W ""
W '   ```'
W '   cmd /c "ssh root@192.168.1.1 ""cat > /root/apply.sh"" < apply-on-router.sh"'
W '   ```'
W ""
W "3. On the router: ``sh /root/apply.sh``, read the two files it wrote, then"
W "   ``/etc/init.d/network restart && sleep 5 && wifi reload``."
W "4. Keep the other slot as the way back until the new one has proven itself."
W ""
W "One MAC per VLAN interface matters: if every VLAN interface answers DHCP with the"
W "same MAC, an upstream DHCP server hands out overlapping or changing leases. The"
W "converter keeps the MACs from the backup; where it found none it leaves a commented"
W "``option macaddr`` in ``network`` for you to fill in."
$reportText = $sb.ToString()

# -------------------------------------------------------------------- write

$utf8 = New-Object System.Text.UTF8Encoding $false
$etcDir = Join-Path $OutDir 'etc\config'
if (-not (Test-Path -LiteralPath $etcDir)) { [void](New-Item -ItemType Directory -Path $etcDir -Force) }
[IO.File]::WriteAllText((Join-Path $etcDir 'network'), ($netText -replace "`r`n", "`n"), $utf8)
[IO.File]::WriteAllText((Join-Path $etcDir 'wireless'), ($wifiText -replace "`r`n", "`n"), $utf8)
[IO.File]::WriteAllText((Join-Path $OutDir 'apply-on-router.sh'), ($applyText -replace "`r`n", "`n"), $utf8)
[IO.File]::WriteAllText((Join-Path $OutDir 'report.md'), ($reportText -replace "`r`n", "`n"), $utf8)

Write-Host ""
Write-Host "Written to $OutDir" -ForegroundColor Green
Write-Host "  etc\config\network      converted network config"
Write-Host "  etc\config\wireless     converted wireless config"
Write-Host "  apply-on-router.sh      run this on the router (contains Wi-Fi keys)"
Write-Host "  report.md               what was carried over and what was not"
Write-Host "  source-config\          the extracted backup, for reference"
Write-Host ""
Write-Host "Warnings: $($script:Warns.Count), notes: $($script:Notes.Count). Read report.md before applying." -ForegroundColor Cyan
