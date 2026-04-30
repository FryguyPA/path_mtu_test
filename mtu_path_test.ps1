# ============================================================================
#  mtu_path_test.ps1 — dual-probe MTU path tester (PowerShell)
#
#  Project : path_mtu_test
#  Author  : Jeff Fry <jeff@fryguy.net>
#  Repo    : https://github.com/FryguyPA/path_mtu_test
#  License : MIT (see LICENSE)
#  Version : 0.6.0
#  Date    : 2026-04-30
#
#  Per hop, per packet size, sends:
#    1. ping -f (DF set)  — finds the no-frag ceiling and parses any returned
#       "Packet needs to be fragmented but DF set" message for the offending
#       router IP.
#    2. ping    (DF clear) — confirms the path actually delivers the size when
#       fragmentation is allowed.
#
#  Targets Windows PowerShell 5.1+ and PowerShell 7+ on Windows. Uses
#  ping.exe and tracert.exe.
# ============================================================================

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $Targets = @(),

    [Alias('f')]
    [string] $File = '',

    [int] $Start = 1300,
    [int] $End = 9000,
    [int] $Step = 500,
    [int] $FineStep = 1,
    [int] $FinePivot = 1500,
    [int] $MaxHops = 30,
    [int] $TimeoutMs = 1500,
    [int] $Retries = 2,
    [string] $Iface = '',
    [switch] $NoColor,
    [switch] $NoSave,
    [string] $OutDir = '.',
    [string] $OutExt = 'log',

    [Alias('V')]
    [switch] $Version,

    [Alias('?')]
    [switch] $ShowHelp
)

$Script:VersionString = '0.6.0'
$Script:Author = 'Jeff Fry <jeff@fryguy.net>'
$Script:Repo   = 'https://github.com/FryguyPA/path_mtu_test'
$Script:IcmpOverhead = 28
$Script:BarWidth = 28

$ErrorActionPreference = 'Stop'


# ---------------------------------------------------------------- platform ---

$IsWin = $env:OS -eq 'Windows_NT' `
    -or [System.Environment]::OSVersion.Platform -eq 'Win32NT' `
    -or ($PSVersionTable.PSVersion.Major -ge 6 -and $IsWindows)

if (-not $IsWin) {
    Write-Error ("mtu_path_test.ps1 targets Windows. " +
                 "On macOS / Linux use mtu_path_test.sh or mtu_path_test.py instead.")
    exit 2
}


# ------------------------------------------------------------------- usage ---

function Show-Usage {
@"
mtu_path_test.ps1 $Script:VersionString  —  $Script:Author
$Script:Repo

USAGE
    .\mtu_path_test.ps1 [options] target [target ...]

OPTIONS
    -Targets <hosts>      One or more destination IPs/hostnames (positional).
    -File <path>          File with one target per line (# comments allowed).
    -Start <int>          Smallest tested size           (default 1300)
    -End <int>            Largest tested size            (default 9000)
    -Step <int>           Coarse step above FinePivot    (default 500)
    -FineStep <int>       Fine step under FinePivot      (default 1)
    -FinePivot <int>      Boundary fine ↔ coarse         (default 1500)
    -MaxHops <int>        Traceroute hop cap             (default 30)
    -TimeoutMs <int>      Per-probe wait in ms           (default 1500)
    -Retries <int>        Retries per probe              (default 2)
    -Iface <name|ip>      Bind probes to interface alias OR source IP
    -NoColor              Disable ANSI colors
    -NoSave               Don't save per-target output to a file
    -OutDir <path>        Directory for saved logs       (default: cwd)
    -OutExt <ext>         Extension for saved logs       (default: log)
    -Version, -V          Print version and exit
    -ShowHelp, -?         Show this help

SWEEP SCHEDULE (defaults)
    1300, 1301, 1302, ..., 1500   (fine step = 1 byte)
    2000, 2500, 3000, ..., 9000   (coarse step = 500 bytes)

EXAMPLES
    .\mtu_path_test.ps1 8.8.8.8
    .\mtu_path_test.ps1 8.8.8.8 1.1.1.1 www.example.com
    .\mtu_path_test.ps1 -File targets.txt -Start 1300 -End 9000
    .\mtu_path_test.ps1 -Iface "Ethernet" 8.8.8.8
    .\mtu_path_test.ps1 -NoSave -Step 250 8.8.8.8
"@ | Write-Host
}

if ($ShowHelp) { Show-Usage; exit 0 }
if ($Version)  { Write-Host "mtu_path_test.ps1 $Script:VersionString"; exit 0 }


# -------------------------------------------------------- color / progress ---

$useColor = (-not $NoColor.IsPresent) -and (-not [Console]::IsOutputRedirected)
$esc = [char]27

if ($useColor) {
    $C = @{
        Reset  = "$esc[0m";  Dim    = "$esc[2m";  Bold   = "$esc[1m"
        Green  = "$esc[32m"; Yellow = "$esc[33m"; Red    = "$esc[31m"
        Cyan   = "$esc[36m"; Grey   = "$esc[90m"
    }
} else {
    $C = @{ Reset=''; Dim=''; Bold=''; Green=''; Yellow=''; Red=''; Cyan=''; Grey='' }
}

# Live progress goes to stderr; auto-suppressed when stderr is redirected.
$stderrIsTty = -not [Console]::IsErrorRedirected

function Write-ProbeProgress {
    param([string]$Prefix, [string]$Msg)
    if ($stderrIsTty) {
        [Console]::Error.Write("`r$Prefix probing $Msg$esc[K")
    }
}
function Clear-ProbeProgress {
    if ($stderrIsTty) { [Console]::Error.Write("`r$esc[K") }
}


# ------------------------------------------------------------------ helpers ---

# Per-target log file capture: when set, every Write-Out call appends an
# ANSI-stripped copy of the line to this path.
$Script:CurrentLogFile = $null

function Remove-AnsiSequence {
    param([string]$Text)
    return ($Text -replace ("$esc" + '\[[0-9;]*[A-Za-z]'), '')
}

# Single sink for all user-visible output. Mirrors stdout to the per-target
# log file (ANSI stripped) when one is open.
function Write-Out {
    param([string]$Text = '')
    Write-Host $Text
    if ($Script:CurrentLogFile) {
        Add-Content -Path $Script:CurrentLogFile -Value (Remove-AnsiSequence $Text)
    }
}

function ConvertTo-SafeFilename {
    param([string]$Name)
    return ($Name -replace '[^A-Za-z0-9._-]', '_')
}

function Get-SweepSizes {
    param(
        [int]$Start, [int]$End, [int]$Step,
        [int]$FineStep, [int]$FinePivot
    )
    $list = New-Object System.Collections.Generic.List[int]
    $s = $Start
    if ($s -lt $FinePivot -and $s -le $End) {
        while ($s -le $FinePivot -and $s -le $End) {
            [void]$list.Add($s); $s += $FineStep
        }
        $s = $FinePivot + $Step
    }
    while ($s -le $End) { [void]$list.Add($s); $s += $Step }
    if ($list.Count -gt 0) {
        $last = $list[$list.Count - 1]
        if ($last -ne $End -and $End -gt $last) { [void]$list.Add($End) }
    }
    return ,$list.ToArray()
}

function New-MtuBar {
    param([int]$Value, [int]$Lo, [int]$Hi, [int]$Width = $Script:BarWidth)
    if ($Value -le 0 -or $Hi -le $Lo) { return ('░' * $Width) }
    $pct = ($Value - $Lo) / ($Hi - $Lo)
    if ($pct -lt 0) { $pct = 0 }
    if ($pct -gt 1) { $pct = 1 }
    $fill = [int][math]::Round($pct * $Width)
    if ($fill -gt $Width) { $fill = $Width }
    if ($fill -lt 0) { $fill = 0 }
    return ('█' * $fill) + ('░' * ($Width - $fill))
}


# ------------------------------------------------- iface → source-IP lookup ---

function Resolve-IfaceAddress {
    param([string]$Iface)
    if ([string]::IsNullOrEmpty($Iface)) { return '' }
    if ($Iface -match '^\d+\.\d+\.\d+\.\d+$') { return $Iface }
    try {
        $ip = Get-NetIPAddress -InterfaceAlias $Iface -AddressFamily IPv4 `
                -ErrorAction Stop |
              Where-Object { $_.PrefixOrigin -ne 'WellKnown' } |
              Select-Object -First 1 -ExpandProperty IPAddress
        if ($ip) { return $ip }
    } catch {
        Write-Warning "Could not resolve interface '$Iface' to a source IPv4 address: $_"
    }
    return ''
}


# ----------------------------------------------------- required-tool check ---

function Test-RequiredTool {
    param(
        [string]$Name,
        [string]$WingetId = '',
        [string]$Note = ''
    )
    if (Get-Command $Name -ErrorAction SilentlyContinue) { return }

    $msg = "$($C.Red)Error:$($C.Reset) required tool ``$Name`` was not found on PATH."
    [Console]::Error.WriteLine($msg)
    [Console]::Error.WriteLine('')

    [Console]::Error.WriteLine('On Windows, ping.exe and tracert.exe ship with the OS. If a tool')
    [Console]::Error.WriteLine('is missing it usually means PATH was edited or the file is corrupt.')
    [Console]::Error.WriteLine('Try the following to verify and recover:')
    [Console]::Error.WriteLine('')
    [Console]::Error.WriteLine("  Get-Command $Name")
    [Console]::Error.WriteLine("  Get-Item 'C:\Windows\System32\$Name'")
    [Console]::Error.WriteLine('')
    [Console]::Error.WriteLine('  # Repair Windows component store if the binary is missing:')
    [Console]::Error.WriteLine('  sfc /scannow')
    [Console]::Error.WriteLine('  DISM /Online /Cleanup-Image /RestoreHealth')
    if ($Note) { [Console]::Error.WriteLine(""); [Console]::Error.WriteLine("  $Note") }
    exit 2
}

Test-RequiredTool 'ping.exe'
Test-RequiredTool 'tracert.exe'


# ------------------------------------------------------------ tracert run ---

function Invoke-Tracert {
    param([string]$Target, [int]$MaxHops, [string]$SrcAddr)
    $trArgs = @('-d', '-h', $MaxHops, '-w', 2000)
    if ($SrcAddr) { $trArgs += @('-S', $SrcAddr) }
    $trArgs += $Target

    Write-Out "$($C.Cyan)Running:$($C.Reset) tracert $($trArgs -join ' ')"
    $raw = & tracert.exe @trArgs 2>&1

    $hops = New-Object System.Collections.Generic.List[object]
    foreach ($line in $raw) {
        $text = "$line"
        if ($text -match '^\s*(\d+)\s+(.+)$') {
            $num = [int]$matches[1]
            $rest = $matches[2]
            if ($rest -match 'Request timed out') {
                [void]$hops.Add([pscustomobject]@{
                    Number = $num; Ip = '*'; Hostname = ''; Unreachable = $true
                    MaxNoFrag = 0; FragAt = 0; FragRouter = ''; FragRouterMtu = 0
                    MaxWithFrag = 0; FirstRealFail = 0
                    DfBaselineFailed = $false; NoDfBaselineFailed = $false; Note = ''
                })
                continue
            }
            $ip = $null; $hostName = ''
            # Last whitespace-separated token is the IP (we used -d so no PTR).
            $tokens = $rest.Trim() -split '\s+'
            for ($i = $tokens.Count - 1; $i -ge 0; $i--) {
                if ($tokens[$i] -match '^(\d+\.\d+\.\d+\.\d+)$') { $ip = $matches[1]; break }
            }
            if ($ip) {
                [void]$hops.Add([pscustomobject]@{
                    Number = $num; Ip = $ip; Hostname = $hostName; Unreachable = $false
                    MaxNoFrag = 0; FragAt = 0; FragRouter = ''; FragRouterMtu = 0
                    MaxWithFrag = 0; FirstRealFail = 0
                    DfBaselineFailed = $false; NoDfBaselineFailed = $false; Note = ''
                })
            }
        }
    }
    return ,$hops.ToArray()
}


# -------------------------------------------------------------- ping probe ---

# Newer Windows ping: "Reply from 10.0.0.5: Packet needs to be fragmented but DF set."
# Older Windows ping: "Packet needs to be fragmented but DF set." (no source IP).
$Script:FragRe = [regex]'(?:Reply from\s+(?<ip>\d+\.\d+\.\d+\.\d+):\s*)?Packet needs to be fragmented but DF set\.?(?:\s*\(MTU\s*=?\s*(?<mtu>\d+)\))?'
$Script:OkRe   = [regex]'Reply from\s+\S+:\s*bytes=\d+'

function Invoke-PingProbe {
    param(
        [string]$Ip,
        [int]   $TotalSize,
        [int]   $TimeoutMs,
        [bool]  $Df,
        [string]$SrcAddr = ''
    )
    $payload = $TotalSize - $Script:IcmpOverhead
    if ($payload -lt 0) {
        return @{ Ok = $false; FragRouter = ''; FragMtu = 0; Error = 'size below ICMP overhead' }
    }
    $pingArgs = @('-n', '1', '-w', $TimeoutMs, '-l', $payload)
    if ($Df) { $pingArgs = @('-f') + $pingArgs }
    if ($SrcAddr) { $pingArgs += @('-S', $SrcAddr) }
    $pingArgs += $Ip

    $raw = & ping.exe @pingArgs 2>&1
    $out = ($raw -join "`n")

    if ($Script:OkRe.IsMatch($out))   {
        return @{ Ok = $true; FragRouter = ''; FragMtu = 0; Error = '' }
    }
    $fm = $Script:FragRe.Match($out)
    if ($fm.Success) {
        $r = $fm.Groups['ip'].Value
        $m = 0
        if ($fm.Groups['mtu'].Success) { $m = [int]$fm.Groups['mtu'].Value }
        return @{ Ok = $false; FragRouter = $r; FragMtu = $m; Error = 'frag-needed' }
    }
    if ($out -match 'transmit failed' -or $out -match 'General failure') {
        return @{ Ok = $false; FragRouter = ''; FragMtu = 0; Error = 'local-mtu-or-error' }
    }
    if ($out -match 'Request timed out|host unreachable|could not find host') {
        return @{ Ok = $false; FragRouter = ''; FragMtu = 0; Error = 'no reply' }
    }
    return @{ Ok = $false; FragRouter = ''; FragMtu = 0; Error = 'no reply' }
}

function Invoke-WithRetry {
    param(
        [string]$Ip, [int]$Size, [int]$TimeoutMs, [bool]$Df,
        [int]$Retries, [string]$SrcAddr
    )
    $last = $null
    for ($i = 0; $i -le $Retries; $i++) {
        $last = Invoke-PingProbe -Ip $Ip -TotalSize $Size -TimeoutMs $TimeoutMs `
                                 -Df $Df -SrcAddr $SrcAddr
        if ($last.Ok -or $last.FragRouter) { return $last }
    }
    return $last
}


# --------------------------------------------------------------- per hop ----

function Invoke-DualProbe {
    param(
        [string]$Ip, [int]$Start, [int]$End, [int]$Step,
        [int]$TimeoutMs, [int]$Retries,
        [int]$FineStep, [int]$FinePivot,
        [string]$Prefix, [string]$SrcAddr
    )
    $sizes = Get-SweepSizes -Start $Start -End $End -Step $Step `
                            -FineStep $FineStep -FinePivot $FinePivot
    if ($sizes.Count -eq 0) { $sizes = ,$Start }

    $r = @{
        MaxNoFrag=0; FragAt=0; FragRouter=''; FragRouterMtu=0
        MaxWithFrag=0; FirstRealFail=0
        DfBaselineFailed=$false; NoDfBaselineFailed=$false; Note=''
    }
    $first = $true
    $total = $sizes.Count
    $idx = 0

    foreach ($size in $sizes) {
        $idx++
        if ($Prefix) { Write-ProbeProgress $Prefix "[$idx/$total] size=$size  DF…" }
        $df = Invoke-WithRetry -Ip $Ip -Size $size -TimeoutMs $TimeoutMs -Df $true `
                               -Retries $Retries -SrcAddr $SrcAddr
        $dfShort = if ($df.Ok) { 'OK' } else { 'FAIL' }
        if ($Prefix) { Write-ProbeProgress $Prefix "[$idx/$total] size=$size  DF=$dfShort  non-DF…" }
        $nodf = Invoke-WithRetry -Ip $Ip -Size $size -TimeoutMs $TimeoutMs -Df $false `
                                 -Retries $Retries -SrcAddr $SrcAddr
        $nodfShort = if ($nodf.Ok) { 'OK' } else { 'FAIL' }
        if ($Prefix) { Write-ProbeProgress $Prefix "[$idx/$total] size=$size  DF=$dfShort  non-DF=$nodfShort" }

        if ($df.Ok) {
            $r.MaxNoFrag = $size
        } elseif ($r.FragAt -eq 0) {
            $r.FragAt = $size
            if ($df.FragRouter) {
                $r.FragRouter = $df.FragRouter
                $r.FragRouterMtu = $df.FragMtu
            }
        }
        if ($nodf.Ok) { $r.MaxWithFrag = $size }

        if ($first) {
            $r.DfBaselineFailed = -not $df.Ok
            $r.NoDfBaselineFailed = -not $nodf.Ok
            $first = $false
        }

        if ((-not $df.Ok) -and (-not $nodf.Ok)) {
            $r.FirstRealFail = $size
            $r.Note = if ($nodf.Error) { $nodf.Error } else { $df.Error }
            break
        }
    }
    if ($Prefix) { Clear-ProbeProgress }
    return $r
}


# ------------------------------------------------------------- rendering ----

function Format-Render {
    param([string]$Target, [object[]]$Hops, [int]$Start, [int]$End)
    $sep = '═' * 78
    Write-Out ''
    Write-Out $sep
    Write-Out "  $($C.Bold)MTU Path Test$($C.Reset)  →  target: $($C.Cyan)$Target$($C.Reset)"
    Write-Out "  Tested range: $Start → $End bytes  (dual probe: DF-set + DF-clear per size; fine step under $FinePivot, coarse above)"
    Write-Out $sep

    for ($i = 0; $i -lt $Hops.Count; $i++) {
        $h = $Hops[$i]
        $isLast = $i -eq ($Hops.Count - 1)
        $glyph = if ($isLast) { '◆' } else { '●' }

        if ($h.Unreachable) {
            $n2 = '{0,2}' -f $h.Number
            Write-Out ("  [{0}] {1}{2}  *  no response{3}" -f $n2, $C.Grey, $glyph, $C.Reset)
        } else {
            $n2 = '{0,2}' -f $h.Number
            $label = $h.Ip
            Write-Out ("  [{0}] {1}{2}{3}  {4}" -f $n2, $C.Bold, $glyph, $C.Reset, $label)

            if ($h.DfBaselineFailed -and $h.NoDfBaselineFailed) {
                $b0 = New-MtuBar 0 $Start $End
                Write-Out "        $($C.Red)│ no-frag : $b0  FAIL at baseline $Start$($C.Reset)"
                Write-Out "        $($C.Red)│ w/ frag : $b0  FAIL at baseline $Start$($C.Reset)"
                if ($h.Note) {
                    Write-Out "        $($C.Dim)│ note    : $($h.Note)$($C.Reset)"
                }
            } else {
                $nfBar = New-MtuBar $h.MaxNoFrag $Start $End
                $wfBar = New-MtuBar $h.MaxWithFrag $Start $End
                $nfColor = if ($h.MaxNoFrag -ge $End) { $C.Green } elseif ($h.MaxNoFrag) { $C.Yellow } else { $C.Red }
                $wfColor = if ($h.MaxWithFrag -ge $End) { $C.Green } elseif ($h.MaxWithFrag) { $C.Yellow } else { $C.Red }
                $nfLabel = if ($h.MaxNoFrag) { "max=$($h.MaxNoFrag)" } else { "none up to $Start" }
                $wfLabel = if ($h.MaxWithFrag) { "max=$($h.MaxWithFrag)" } else { "none up to $Start" }
                Write-Out "        $nfColor│ no-frag : $nfBar  $nfLabel$($C.Reset)"
                Write-Out "        $wfColor│ w/ frag : $wfBar  $wfLabel$($C.Reset)"

                if ($h.FragAt -gt 0) {
                    if ($h.FragRouter) {
                        $mtu = if ($h.FragRouterMtu -gt 0) { " (link MTU $($h.FragRouterMtu))" } else { '' }
                        Write-Out "        $($C.Yellow)│ frag pt : $($h.FragAt) → via $($h.FragRouter)$mtu$($C.Reset)"
                    } else {
                        Write-Out "        $($C.Yellow)│ frag pt : $($h.FragAt) (router silent — Windows ping did not name it)$($C.Reset)"
                    }
                } else {
                    Write-Out "        $($C.Green)│ frag pt : none in tested range$($C.Reset)"
                }
                if ($h.FirstRealFail -gt 0) {
                    Write-Out "        $($C.Red)│ hard fail at $($h.FirstRealFail) (both DF and DF-clear)  $($h.Note)$($C.Reset)"
                }
            }
        }
        if (-not $isLast) { Write-Out "        $($C.Dim)▼$($C.Reset)" }
    }
    Write-Out $sep

    # Per-target summary
    $tested = $Hops | Where-Object { -not $_.Unreachable -and ($_.MaxNoFrag -or $_.FragAt -or $_.MaxWithFrag) }
    if ($tested) {
        $nfVals = $tested | Where-Object { $_.MaxNoFrag } | ForEach-Object { $_.MaxNoFrag }
        $wfVals = $tested | Where-Object { $_.MaxWithFrag } | ForEach-Object { $_.MaxWithFrag }
        $pnf = if ($nfVals) { ($nfVals | Measure-Object -Minimum).Minimum } else { 0 }
        $pwf = if ($wfVals) { ($wfVals | Measure-Object -Minimum).Minimum } else { 0 }
        $first = $tested | Where-Object { $_.FragAt -gt 0 } | Select-Object -First 1
        Write-Out "  $($C.Bold)No-frag Path MTU:$($C.Reset)    $pnf bytes"
        Write-Out "  $($C.Bold)Frag-OK Path MTU:$($C.Reset)    $pwf bytes"
        if ($first) {
            $who = if ($first.FragRouter) {
                if ($first.FragRouterMtu) {
                    "$($first.FragRouter) (link MTU $($first.FragRouterMtu))"
                } else { $first.FragRouter }
            } else { 'router silent' }
            Write-Out "  $($C.Bold)First fragmentation:$($C.Reset) hop $($first.Number) ($($first.Ip)) starts fragmenting at $($first.FragAt) — $who"
        } else {
            Write-Out "  $($C.Green)No fragmentation observed within the tested range.$($C.Reset)"
        }
    }
    Write-Out $sep
    Write-Out ''
}

function Format-MultiSummary {
    param([array]$Results)
    if ($Results.Count -le 1) { return }
    $sep = '═' * 86
    Write-Out $sep
    Write-Out "  $($C.Bold)Multi-Target Summary$($C.Reset)"
    Write-Out $sep
    Write-Out ('  {0,-28} {1,9} {2,9}  {3}' -f 'Target', 'No-frag', 'W/frag', 'Fragmentation point')
    Write-Out ('  {0,-28} {1,9} {2,9}  {3}' -f ('-' * 28), ('-' * 9), ('-' * 9), ('-' * 36))
    foreach ($r in $Results) {
        $hops = $r.Hops
        $tested = $hops | Where-Object { -not $_.Unreachable -and ($_.MaxNoFrag -or $_.FragAt -or $_.MaxWithFrag) }
        if (-not $tested) {
            Write-Out ('  {0,-28} {1,9} {2,9}  {3}no data{4}' -f $r.Target, '—', '—', $C.Grey, $C.Reset)
            continue
        }
        $nfVals = $tested | Where-Object { $_.MaxNoFrag } | ForEach-Object { $_.MaxNoFrag }
        $wfVals = $tested | Where-Object { $_.MaxWithFrag } | ForEach-Object { $_.MaxWithFrag }
        $pnf = if ($nfVals) { ($nfVals | Measure-Object -Minimum).Minimum } else { 0 }
        $pwf = if ($wfVals) { ($wfVals | Measure-Object -Minimum).Minimum } else { 0 }
        $first = $tested | Where-Object { $_.FragAt -gt 0 } | Select-Object -First 1
        if ($first) {
            $who = if ($first.FragRouter) { "$($first.FragRouter) MTU $($first.FragRouterMtu)" } else { 'silent' }
            $note = "hop $($first.Number) @ $($first.FragAt) ($who)"
            $color = $C.Yellow
        } else {
            $note = 'no frag in range'; $color = $C.Green
        }
        Write-Out ('  {0,-28} {1,9} {2,9}  {3}{4}{5}' -f $r.Target, $pnf, $pwf, $color, $note, $C.Reset)
    }
    Write-Out $sep
    Write-Out ''
}


# ------------------------------------------------------ load targets file ---

function Read-TargetsFile {
    param([string]$Path)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($raw in (Get-Content -Path $Path)) {
        $line = $raw
        $hash = $line.IndexOf('#')
        if ($hash -ge 0) { $line = $line.Substring(0, $hash) }
        $line = $line.Trim()
        if (-not $line) { continue }
        $first = ($line -split '\s+')[0]
        if ($first) { [void]$out.Add($first) }
    }
    return ,($out | Select-Object -Unique)
}


# ------------------------------------------------------- run-one-target ----

function Invoke-OneTarget {
    param([string]$Target, [string]$SrcAddr)

    $bar1 = '━' * 72
    Write-Out ''
    Write-Out "$($C.Bold)$bar1$($C.Reset)"
    Write-Out "$($C.Bold)Target:$($C.Reset) $($C.Cyan)$Target$($C.Reset)"
    Write-Out "$($C.Bold)$bar1$($C.Reset)"

    $hops = Invoke-Tracert -Target $Target -MaxHops $MaxHops -SrcAddr $SrcAddr
    if (-not $hops -or $hops.Count -eq 0) {
        Write-Out "$($C.Red)No hops discovered for $Target$($C.Reset)"
        return ,@()
    }

    Write-Out "Discovered $($hops.Count) hop(s). Probing MTU per hop ($Start→$End, fine_step=$FineStep up to $FinePivot, then step=$Step)..."
    Write-Out ''

    foreach ($h in $hops) {
        $prefix = ('  [{0,2}] {1,-39}' -f $h.Number, $h.Ip)
        if ($h.Unreachable) {
            Write-Out "$prefix $($C.Grey)skip (no response)$($C.Reset)"
            continue
        }
        $r = Invoke-DualProbe -Ip $h.Ip -Start $Start -End $End -Step $Step `
                              -TimeoutMs $TimeoutMs -Retries $Retries `
                              -FineStep $FineStep -FinePivot $FinePivot `
                              -Prefix $prefix -SrcAddr $SrcAddr
        $h.MaxNoFrag         = $r.MaxNoFrag
        $h.FragAt            = $r.FragAt
        $h.FragRouter        = $r.FragRouter
        $h.FragRouterMtu     = $r.FragRouterMtu
        $h.MaxWithFrag       = $r.MaxWithFrag
        $h.FirstRealFail     = $r.FirstRealFail
        $h.DfBaselineFailed  = $r.DfBaselineFailed
        $h.NoDfBaselineFailed= $r.NoDfBaselineFailed
        $h.Note              = $r.Note

        $nf = if ($h.MaxNoFrag) { $h.MaxNoFrag } else { '—' }
        $wf = if ($h.MaxWithFrag) { $h.MaxWithFrag } else { '—' }

        if ($h.DfBaselineFailed -and $h.NoDfBaselineFailed) {
            Write-Out "$prefix $($C.Red)both probes fail at baseline ($($h.Note))$($C.Reset)"
        } elseif ($h.FragAt -gt 0 -and $h.FragRouter) {
            $mtuPart = if ($h.FragRouterMtu) { " (MTU $($h.FragRouterMtu))" } else { '' }
            Write-Out "$prefix $($C.Yellow)no-frag=$nf, frag@$($h.FragAt) via $($h.FragRouter)$mtuPart, w/frag=$wf$($C.Reset)"
        } elseif ($h.FragAt -gt 0) {
            Write-Out "$prefix $($C.Yellow)no-frag=$nf, frag@$($h.FragAt) (silent), w/frag=$wf$($C.Reset)"
        } else {
            Write-Out "$prefix $($C.Green)no-frag=$nf, w/frag=$wf ✓ (no frag in range)$($C.Reset)"
        }
    }

    Format-Render -Target $Target -Hops $hops -Start $Start -End $End
    return ,$hops
}


# ----------------------------------------------------------------- main ----

# Sweep validation
if ($Start -lt 64 -or $End -gt 65500 -or $Start -ge $End -or $Step -lt 1 -or $FineStep -lt 1) {
    Write-Error 'Invalid -Start / -End / -Step / -FineStep combination'
    exit 2
}

# Resolve --iface to a source IPv4 address (Windows ping has -S for source).
$srcAddr = ''
if ($Iface) {
    $srcAddr = Resolve-IfaceAddress -Iface $Iface
    if (-not $srcAddr) {
        Write-Error "Could not resolve -Iface '$Iface' to an IPv4 address."
        exit 2
    }
    Write-Host "$($C.Dim)Iface '$Iface' → source $srcAddr$($C.Reset)"
}

# Load --file targets
$allTargets = New-Object System.Collections.Generic.List[string]
foreach ($t in $Targets) { [void]$allTargets.Add($t) }
if ($File) {
    if (-not (Test-Path -LiteralPath $File)) {
        Write-Error "Cannot read -File '$File'"; exit 2
    }
    foreach ($t in (Read-TargetsFile -Path $File)) { [void]$allTargets.Add($t) }
}
$dedup = $allTargets | Select-Object -Unique
if (-not $dedup -or $dedup.Count -eq 0) {
    Write-Host 'No targets given. Pass one or more positional targets, or -File.'
    Show-Usage
    exit 2
}

# Output directory
if (-not $NoSave.IsPresent) {
    if (-not (Test-Path -LiteralPath $OutDir)) {
        try { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
        catch {
            Write-Warning "Could not create -OutDir '$OutDir' ($_); disabling save."
            $NoSave = [switch]::Present
        }
    }
}

$runTs = Get-Date -Format 'yyyyMMdd_HHmmss'
$savedFiles = New-Object System.Collections.Generic.List[string]
$results = New-Object System.Collections.Generic.List[object]

foreach ($t in $dedup) {
    if (-not $NoSave.IsPresent) {
        $safe = ConvertTo-SafeFilename -Name $t
        $ext = $OutExt.TrimStart('.')
        $logPath = Join-Path -Path $OutDir -ChildPath "${safe}_${runTs}.${ext}"
        Set-Content -Path $logPath -Value '' -Encoding UTF8
        $Script:CurrentLogFile = $logPath
        Write-Host "$($C.Dim)↳ saving to:$($C.Reset) $logPath"
    } else {
        $Script:CurrentLogFile = $null
    }

    try {
        $hops = Invoke-OneTarget -Target $t -SrcAddr $srcAddr
        [void]$results.Add([pscustomobject]@{ Target = $t; Hops = $hops })
    } finally {
        if ($Script:CurrentLogFile) {
            [void]$savedFiles.Add($Script:CurrentLogFile)
            $Script:CurrentLogFile = $null
        }
    }
}

Format-MultiSummary -Results $results.ToArray()

if ($savedFiles.Count -gt 0) {
    Write-Host "$($C.Bold)Saved logs:$($C.Reset)"
    foreach ($f in $savedFiles) { Write-Host "  $f" }
    Write-Host ''
}

exit 0
