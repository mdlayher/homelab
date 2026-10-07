# Applies the configuration in config.json beside this script to the machine
# it runs on: winget packages at their pinned versions, the exporter services
# and firewall rules, HWiNFO's settings and logon task. Run by
# windows/deploy as an administrator over SSH.
#
# With -Check, prints how the machine differs and changes nothing, exiting 1
# if it does.
param([switch]$Check)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$config = Get-Content (Join-Path $here 'config.json') -Raw | ConvertFrom-Json
$drift = New-Object System.Collections.Generic.List[string]

# Records a difference, and in apply mode runs the block that fixes it.
function Fix([string]$what, [scriptblock]$action) {
    $drift.Add($what)
    if ($Check) { "would: $what" } else { "apply: $what"; & $action }
}

# The installed version of a winget package, or $null. Some installers
# register their version with a leading v (Alloy's v1.20.1), which is
# dropped to compare with the pinned version.
function Installed-Version([string]$id) {
    $out = winget list --id $id --exact --accept-source-agreements --disable-interactivity 2>$null | Out-String
    if ($out -match "\s$([regex]::Escape($id))\s+v?(\S+)") { return $Matches[1] }
    return $null
}

# Packages.
foreach ($p in $config.packages) {
    $have = Installed-Version $p.id
    if ($have -eq $p.version) { continue }
    $verb = if ($have) { 'upgrade' } else { 'install' }
    Fix "$verb $($p.id) $have -> $($p.version)" {
        foreach ($s in $p.services) { Stop-Service $s -ErrorAction SilentlyContinue }
        foreach ($n in $p.processes) { Stop-Process -Name $n -Force -ErrorAction SilentlyContinue }
        try {
            winget $verb --id $p.id --exact --version $p.version --scope machine --silent `
                --accept-package-agreements --accept-source-agreements --disable-interactivity
            if ($LASTEXITCODE -ne 0) { throw "winget $verb $($p.id) failed: $LASTEXITCODE" }
        } finally {
            # Services stopped for the upgrade start again even when it fails.
            foreach ($s in $p.services) { Start-Service $s -ErrorAction SilentlyContinue }
        }
    }
}

# The HWiNFO exporter's executable, built by this repository.
$hwinfoExe = 'C:\Program Files\hwinfo_exporter\hwinfo_exporter.exe'
$newExe = Join-Path $here 'hwinfo_exporter.exe'
if (-not (Test-Path $hwinfoExe) -or (Get-FileHash $hwinfoExe).Hash -ne (Get-FileHash $newExe).Hash) {
    Fix 'update hwinfo_exporter.exe' {
        Stop-Service hwinfo_exporter -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force (Split-Path $hwinfoExe) | Out-Null
        Copy-Item $newExe $hwinfoExe -Force
    }
}

# Services winget's packages do not register, restarted by the service
# manager after a failure.
foreach ($s in $config.services.PSObject.Properties) {
    $svc = Get-CimInstance Win32_Service -Filter "Name='$($s.Name)'"
    if (-not $svc) {
        Fix "create service $($s.Name)" {
            New-Service -Name $s.Name -DisplayName $s.Value.displayName -BinaryPathName $s.Value.path -StartupType Automatic | Out-Null
            sc.exe failure $s.Name reset= 86400 actions= restart/5000 | Out-Null
        }
    } elseif ($svc.PathName -ne $s.Value.path -or $svc.StartMode -ne 'Auto') {
        # Set in the registry: Windows PowerShell strips the quotes from an
        # argument it passes to sc.exe, and the path needs them.
        Fix "reconfigure service $($s.Name)" {
            Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$($s.Name)" -Name ImagePath -Value $s.Value.path
            Set-Service $s.Name -StartupType Automatic
        }
    }
}

# Configuration files from this tree, each replaced when it differs and its
# service restarted, once the package that reads it is installed.
foreach ($f in $config.files) {
    $new = Join-Path $here $f.source
    if (-not (Test-Path (Split-Path $f.path))) { continue }
    if (-not (Test-Path $f.path) -or (Get-FileHash $f.path).Hash -ne (Get-FileHash $new).Hash) {
        Fix "update $($f.path)" {
            Copy-Item $new $f.path -Force
            if (Get-Service $f.service -ErrorAction SilentlyContinue) { Restart-Service $f.service }
        }
    }
}

# Alloy's service arguments, read from the registry when the service starts.
$alloyKey = 'HKLM:\SOFTWARE\GrafanaLabs\Alloy'
if (Test-Path $alloyKey) {
    $have = @((Get-ItemProperty $alloyKey).Arguments)
    if (($have -join "`n") -ne ($config.alloyArguments -join "`n")) {
        Fix 'Alloy service arguments' {
            Set-ItemProperty $alloyKey -Name Arguments -Type MultiString -Value ([string[]]$config.alloyArguments)
            Restart-Service Alloy
        }
    }
}

# The clock, synced from the anycast NTP address rather than
# time.windows.com, by a time service that runs at boot instead of on
# demand.
$w32 = Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters
$peer = "$($config.ntp),0x8"
$w32svc = Get-CimInstance Win32_Service -Filter "Name='W32Time'"
if ($w32.NtpServer -ne $peer -or $w32.Type -ne 'NTP' -or $w32svc.StartMode -ne 'Auto') {
    Fix "time from $($config.ntp)" {
        Set-Service W32Time -StartupType Automatic
        Start-Service W32Time
        w32tm /config /manualpeerlist:$peer /syncfromflags:manual /update | Out-Null
        w32tm /resync /nowait | Out-Null
    }
}

# Inbound firewall rules, on every profile: TCP ports, and ICMP by type.
foreach ($r in $config.firewall) {
    $rule = Get-NetFirewallRule -DisplayName $r.name -ErrorAction SilentlyContinue | Select-Object -First 1
    $filter = if ($rule) { $rule | Get-NetFirewallPortFilter } else { $null }
    $ok = $rule -and $rule.Enabled -eq 'True' -and $rule.Direction -eq 'Inbound' -and
        $rule.Action -eq 'Allow' -and $rule.Profile -eq 'Any' -and $filter.Protocol -eq $r.protocol -and
        $(if ($r.port) { "$($filter.LocalPort)" -eq "$($r.port)" } else { "$($filter.IcmpType)" -eq $r.icmpType })
    if (-not $ok) {
        $what = if ($r.port) { "$($r.protocol) $($r.port)" } else { "$($r.protocol) type $($r.icmpType)" }
        Fix "firewall rule $($r.name) on $what" {
            Get-NetFirewallRule -DisplayName $r.name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
            $match = if ($r.port) { @{ LocalPort = $r.port } } else { @{ IcmpType = $r.icmpType } }
            New-NetFirewallRule -DisplayName $r.name -Direction Inbound -Action Allow -Protocol $r.protocol `
                -Profile Any @match | Out-Null
        }
    }
}

# sshd: the admin's keys, password logins off, PowerShell as the shell. A
# deploy logs in with these keys, so the new file is checked before it
# replaces the old one.
$keys = "$env:ProgramData\ssh\administrators_authorized_keys"
$wantKeys = @($config.sshKeys)
$haveKeys = @(if (Test-Path $keys) { Get-Content $keys })
$acl = if (Test-Path $keys) { Get-Acl $keys } else { $null }
$aclOk = $acl -and $acl.AreAccessRulesProtected -and
    (@($acl.Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } | Sort-Object -Unique) -join ',') -eq 'S-1-5-18,S-1-5-32-544'
if (($haveKeys -join "`n") -ne ($wantKeys -join "`n") -or -not $aclOk) {
    Fix 'SSH authorized keys' {
        if ($wantKeys.Count -eq 0 -or @($wantKeys | Where-Object { $_ -notmatch '^sk-' }).Count -gt 0) {
            throw 'refusing to write SSH keys that are not all FIDO2 keys'
        }
        $tmp = "$keys.new"
        Set-Content -Path $tmp -Value $wantKeys -Encoding ascii
        icacls.exe $tmp /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
        Move-Item $tmp $keys -Force
    }
}

# sshd takes the first value it reads, so these sit above the Match block
# its default configuration ends with.
$sshdConfig = "$env:ProgramData\ssh\sshd_config"
$sshdLines = @(Get-Content $sshdConfig)
$matchAt = [array]::FindIndex([string[]]$sshdLines, [Predicate[string]] { param($l) $l -match '^\s*Match\s' })
$head = if ($matchAt -ge 0) { @($sshdLines[0..([Math]::Max($matchAt - 1, 0))]) } else { $sshdLines }
$restartSshd = $false
$needed = @('PasswordAuthentication no', 'KbdInteractiveAuthentication no' | Where-Object { $head -notcontains $_ })
if ($needed.Count -gt 0) {
    Fix "sshd_config: $($needed -join ', ')" {
        Set-Content -Path $sshdConfig -Value (@($needed) + $sshdLines) -Encoding ascii
        $script:restartSshd = $true
    }
}
$shell = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
if ((Get-ItemProperty HKLM:\SOFTWARE\OpenSSH -Name DefaultShell -ErrorAction SilentlyContinue).DefaultShell -ne $shell) {
    Fix 'sshd default shell' {
        New-ItemProperty -Path HKLM:\SOFTWARE\OpenSSH -Name DefaultShell -Value $shell -PropertyType String -Force | Out-Null
    }
}

# IPv6 addresses from the adapter's MAC (EUI-64), which the inventory's
# records for these machines are built from, rather than a random
# identifier. Both the running value and the one used after a reboot; an
# adapter picks up the running value when its link next comes up.
foreach ($store in 'active', 'persistent') {
    $line = netsh interface ipv6 show global store=$store | Select-String 'Randomize Identifiers'
    if ("$line" -notmatch ':\s*disabled') {
        Fix "IPv6 random identifiers off ($store)" {
            netsh interface ipv6 set global randomizeidentifiers=disabled store=$store | Out-Null
        }
    }
}

# Tailscale's subnet routes off. The router advertises the house's networks
# to personal devices, and these machines reach them on the LAN; the policy
# grants them none of those addresses, so a route through the tailnet would
# only drop their traffic.
$tailscale = 'C:\Program Files\Tailscale\tailscale.exe'
if ((Test-Path $tailscale) -and (& $tailscale debug prefs | ConvertFrom-Json).RouteAll) {
    Fix 'Tailscale subnet routes off' {
        & $tailscale set --accept-routes=false
        if ($LASTEXITCODE -ne 0) { throw "tailscale set failed: $LASTEXITCODE" }
    }
}

# HWiNFO's settings, merged into its INI file. HWiNFO writes the file back
# when it exits, so it keeps these as long as they match what it runs with.
# Lines that are neither a section, a setting nor blank are dropped.
$ini = 'C:\Program Files\HWiNFO64\HWiNFO64.INI'
$have = @(if (Test-Path $ini) { Get-Content $ini })
$keys = @($config.hwinfo.PSObject.Properties | ForEach-Object Name)
$kept = @($have | Where-Object {
    ($_ -match '^\[.+\]$' -or $_ -match '^[^=\[]+=' -or $_ -eq '') -and
    ($keys -notcontains ($_ -split '=', 2)[0])
})
if ($kept -notcontains '[Settings]') { $kept = @('[Settings]') + $kept }
$at = [array]::IndexOf([string[]]$kept, '[Settings]')
$want = @($kept[0..$at]) + @($config.hwinfo.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) +
    @(if ($at + 1 -lt $kept.Count) { $kept[($at + 1)..($kept.Count - 1)] })
$missing = @($want | Where-Object { $have -notcontains $_ })
if ($missing.Count -gt 0 -or $have.Count -ne $want.Count) {
    $what = if ($missing.Count -gt 0) { ($missing | ForEach-Object { ($_ -split '=', 2)[0] }) -join ', ' } else { 'drop unrecognized lines' }
    Fix "HWiNFO settings: $what" {
        Set-Content -Path $ini -Value $want -Encoding ascii
    }
}

# The HWiNFO license key, from windows/secrets.yaml.
$newKey = Join-Path $here 'HWiNFO64_KEY.txt'
$key = 'C:\Program Files\HWiNFO64\HWiNFO64_KEY.txt'
if ((Test-Path $newKey) -and (-not (Test-Path $key) -or (Get-FileHash $key).Hash -ne (Get-FileHash $newKey).Hash)) {
    Fix 'HWiNFO license key' { Copy-Item $newKey $key -Force }
}

# HWiNFO runs in the deploying admin's session from a logon task, named as
# the one its own Autorun setting creates, since its sensors need a desktop
# session. HWiNFO points its task at a launcher it writes itself; a task
# whose program is missing is replaced with one starting HWiNFO directly.
$task = Get-ScheduledTask -TaskName HWiNFO -ErrorAction SilentlyContinue
$program = if ($task) { $task.Actions[0].Execute.Trim('"') } else { $null }
if (-not $program -or -not (Test-Path $program)) {
    Fix 'HWiNFO logon task' {
        # The login's own identity; over SSH, USERDOMAIN reads WORKGROUP.
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $action = New-ScheduledTaskAction -Execute 'C:\Program Files\HWiNFO64\HWiNFO64.EXE' -WorkingDirectory 'C:\Program Files\HWiNFO64\'
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        $trigger.Delay = 'PT5S'
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0
        Register-ScheduledTask -TaskName HWiNFO -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    }
}

# Everything above in place: start what is stopped. HWiNFO starts only when
# someone is logged on, which its logon task otherwise covers.
$running = @($config.packages | ForEach-Object { $_.services }) + @($config.services.PSObject.Properties | ForEach-Object Name) + 'W32Time'
foreach ($s in $running) {
    $svc = Get-Service $s -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') { Fix "start $s" { Start-Service $s } }
}
if (-not (Get-Process HWiNFO64 -ErrorAction SilentlyContinue) -and (Get-CimInstance Win32_ComputerSystem).UserName) {
    Fix 'start HWiNFO' { Start-ScheduledTask -TaskName HWiNFO }
}

# Last, since it can drop the session running this script.
if ($restartSshd) { Restart-Service sshd }

if ($drift.Count -eq 0) { 'no changes' }
if ($Check -and $drift.Count -gt 0) { exit 1 }
