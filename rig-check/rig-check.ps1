#requires -Version 5.1
<#
.SYNOPSIS
Read-only checker for the Helios Neo 16S and Odyssey G93SD profiles.

.DESCRIPTION
status reads machine.yaml, profiles.yaml, the Windows display mode, and the
NVIDIA driver. selftest checks the files and the report logic. Neither
command writes a file or changes Windows, the driver, or a game.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'selftest')]
    [string]$Command = 'status'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:RigExitCode = 0

$script:RigDisplaySource = @'
using System;
using System.Runtime.InteropServices;

namespace RigCheck {
    public static class DisplayNative {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct DISPLAY_DEVICE {
            public int cb;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
            public string DeviceName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
            public string DeviceString;
            public int StateFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
            public string DeviceID;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
            public string DeviceKey;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct DEVMODE {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
            public string dmDeviceName;
            public short dmSpecVersion;
            public short dmDriverVersion;
            public short dmSize;
            public short dmDriverExtra;
            public int dmFields;
            public int dmPositionX;
            public int dmPositionY;
            public int dmDisplayOrientation;
            public int dmDisplayFixedOutput;
            public short dmColor;
            public short dmDuplex;
            public short dmYResolution;
            public short dmTTOption;
            public short dmCollate;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
            public string dmFormName;
            public short dmLogPixels;
            public int dmBitsPerPel;
            public int dmPelsWidth;
            public int dmPelsHeight;
            public int dmDisplayFlags;
            public int dmDisplayFrequency;
            public int dmICMMethod;
            public int dmICMIntent;
            public int dmMediaType;
            public int dmDitherType;
            public int dmReserved1;
            public int dmReserved2;
            public int dmPanningWidth;
            public int dmPanningHeight;
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool EnumDisplaySettings(string lpszDeviceName, int iModeNum, ref DEVMODE lpDevMode);
    }
}
'@

function ConvertTo-RigArray($Value) {
    $list = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Value) { return ,$list }
    if ($Value -is [string]) {
        $list.Add($Value)
        return ,$list
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($item in $Value) { $list.Add($item) }
        return ,$list
    }
    $list.Add($Value)
    return ,$list
}

function Remove-RigComment([string]$Line) {
    $inQuote = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($c -eq '"') { $inQuote = -not $inQuote; continue }
        if (-not $inQuote -and $c -eq '#') { return $Line.Substring(0, $i) }
    }
    return $Line
}

function ConvertFrom-RigScalar([string]$Value) {
    $v = $Value.Trim()
    if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) {
        return $v.Substring(1, $v.Length - 2).Replace('\"', '"')
    }
    if ($v -eq 'true') { return $true }
    if ($v -eq 'false') { return $false }
    if ($v -eq 'null' -or $v -eq '~') { return $null }
    return $v
}

function Test-RigKeyValue([string]$Text) {
    return $Text -match '^[A-Za-z_][A-Za-z0-9_]*\s*:'
}

function Get-RigLines([string]$Text) {
    $clean = [string]$Text
    if ($clean.Length -gt 0 -and [int][char]$clean[0] -eq 0xFEFF) {
        $clean = $clean.Substring(1)
    }
    $clean = $clean.Replace("`r", '')
    $rows = New-Object System.Collections.Generic.List[object]
    $number = 0
    foreach ($raw in $clean.Split([char]10)) {
        $number++
        if ($raw -match "`t") { throw "Line ${number}: tabs are not allowed" }
        $stripped = Remove-RigComment $raw
        if ($stripped.Trim() -eq '') { continue }
        $indent = 0
        while ($indent -lt $stripped.Length -and $stripped[$indent] -eq ' ') { $indent++ }
        $rows.Add(@{
            Line   = $number
            Indent = $indent
            Text   = $stripped.Trim()
        })
    }
    return ,$rows
}

function ConvertFrom-RigYaml([string]$Text) {
    $lines = ConvertTo-RigArray (Get-RigLines $Text)
    $root = @{}
    $stack = New-Object System.Collections.Generic.List[object]
    $stack.Add(@{ Indent = -1; Kind = 'map'; Node = $root })

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        while ($stack.Count -gt 1 -and $stack[$stack.Count - 1].Indent -ge $line.Indent) {
            $stack.RemoveAt($stack.Count - 1)
        }
        $top = $stack[$stack.Count - 1]

        if ($line.Text.StartsWith('- ')) {
            if ($top.Kind -ne 'list') { throw "Line $($line.Line): list item is not under a list" }
            $rest = $line.Text.Substring(2).Trim()
            if (Test-RigKeyValue $rest) {
                $map = @{}
                [void]$top.Node.Add($map)
                $colon = $rest.IndexOf(':')
                $key = $rest.Substring(0, $colon).Trim()
                $val = $rest.Substring($colon + 1).Trim()
                if ($map.ContainsKey($key)) { throw "Line $($line.Line): duplicate key '$key'" }
                if ($val -eq '') { $map[$key] = $null } else { $map[$key] = ConvertFrom-RigScalar $val }
                $stack.Add(@{ Indent = $line.Indent; Kind = 'map'; Node = $map })
            }
            else {
                [void]$top.Node.Add((ConvertFrom-RigScalar $rest))
            }
            continue
        }

        $colon = $line.Text.IndexOf(':')
        if ($colon -lt 1) { throw "Line $($line.Line): expected key: value" }
        $key = $line.Text.Substring(0, $colon).Trim()
        $val = $line.Text.Substring($colon + 1).Trim()
        if ($top.Kind -ne 'map') { throw "Line $($line.Line): key '$key' is not under a map" }
        if ($top.Node.ContainsKey($key)) { throw "Line $($line.Line): duplicate key '$key'" }

        if ($val -ne '') {
            $top.Node[$key] = ConvertFrom-RigScalar $val
            continue
        }

        $next = $null
        if (($i + 1) -lt $lines.Count) { $next = $lines[$i + 1] }
        if ($null -ne $next -and $next.Indent -gt $line.Indent -and $next.Text.StartsWith('- ')) {
            $list = New-Object System.Collections.Generic.List[object]
            $top.Node[$key] = $list
            $stack.Add(@{ Indent = $line.Indent; Kind = 'list'; Node = $list })
        }
        elseif ($null -ne $next -and $next.Indent -gt $line.Indent) {
            $map = @{}
            $top.Node[$key] = $map
            $stack.Add(@{ Indent = $line.Indent; Kind = 'map'; Node = $map })
        }
        else {
            $top.Node[$key] = $null
        }
    }
    return $root
}

function Get-RigChild($Node, [string]$Key) {
    if ($null -eq $Node -or -not ($Node -is [System.Collections.IDictionary])) { return $null }
    if (-not $Node.ContainsKey($Key)) { return $null }
    return $Node[$Key]
}

function Get-RigPath($Node, [string[]]$Keys) {
    $current = $Node
    foreach ($key in $Keys) {
        $current = Get-RigChild $current $key
        if ($null -eq $current) { return $null }
    }
    return $current
}

function Test-RigNameMatch($Name, $Tokens) {
    if ([string]::IsNullOrWhiteSpace([string]$Name)) { return $false }
    $lower = ([string]$Name).ToLowerInvariant()
    foreach ($token in (ConvertTo-RigArray $Tokens)) {
        $needle = ([string]$token).ToLowerInvariant()
        if ($needle -ne '' -and $lower.Contains($needle)) { return $true }
    }
    return $false
}

function Get-RigRoleHint($Machine, $Monitor) {
    $tokens = Get-RigPath $Machine @('display', 'match_names')
    if (Test-RigNameMatch $Monitor.Name $tokens) { return 'external' }
    if ([string]$Monitor.Connection -eq 'Internal') { return 'internal' }
    $mode = '{0}x{1}' -f $Monitor.Width, $Monitor.Height
    $internalRes = [string](Get-RigPath $Machine @('laptop', 'internal_panel', 'resolution'))
    if ($mode -eq $internalRes) { return 'internal' }
    return 'external'
}

function Get-RigConfigPath($Config, [string]$DocumentsRoot) {
    if ($null -eq $Config) { return $null }
    if ($Config['verified'] -ne $true) { return $null }
    if ([string]$Config['purpose'] -ne 'presence') { return $null }
    if ([string]$Config['root'] -ne 'documents') { return $null }
    $full = $DocumentsRoot
    foreach ($part in ([string]$Config['path'] -split '/')) {
        if ($part -ne '') { $full = [System.IO.Path]::Combine($full, $part) }
    }
    return $full
}

function Get-RigValidationErrors($Machine, $Profiles) {
    $errors = New-Object System.Collections.Generic.List[string]
    if ([string](Get-RigChild $Machine 'schema') -ne '1') { $errors.Add('machine.yaml schema must be 1') }
    if ([string](Get-RigChild $Profiles 'schema') -ne '1') { $errors.Add('profiles.yaml schema must be 1') }

    $expected = [string](Get-RigPath $Machine @('driver', 'expected'))
    if ($expected -ne '616.92') { $errors.Add('driver.expected must stay 616.92') }
    $capToken = [string](Get-RigPath $Machine @('display', 'fps_cap'))
    if ($capToken -ne 'match_display_hz') { $errors.Add('display.fps_cap must stay match_display_hz') }
    if ([string](Get-RigPath $Machine @('display', 'preferred_resolution')) -ne '5120x1440') {
        $errors.Add('display.preferred_resolution must stay 5120x1440')
    }
    if ([string](Get-RigPath $Machine @('display', 'connection')) -ne 'HDMI') {
        $errors.Add('display.connection must stay HDMI')
    }
    if ([string](Get-RigPath $Machine @('laptop', 'internal_panel', 'resolution')) -ne '2560x1600') {
        $errors.Add('internal panel resolution must stay 2560x1600')
    }

    $never = (ConvertTo-RigArray (Get-RigChild $Machine 'never_touch'))
    foreach ($word in @('BIOS', 'undervolt', 'PredatorSense', 'fan curves')) {
        $found = $false
        foreach ($item in $never) {
            if ([string]$item -eq $word) { $found = $true }
        }
        if (-not $found) { $errors.Add("never_touch is missing $word") }
    }

    $games = (ConvertTo-RigArray (Get-RigChild $Profiles 'games'))
    $expectedIds = @('iracing', 'acc', 'ace', 'fh6', 'bf6')
    if ($games.Count -ne $expectedIds.Count) { $errors.Add('profiles.yaml must list five games') }
    for ($i = 0; $i -lt $games.Count -and $i -lt $expectedIds.Count; $i++) {
        if ([string]$games[$i]['id'] -ne $expectedIds[$i]) {
            $errors.Add("game $($i + 1) must be $($expectedIds[$i])")
        }
    }

    $settings = New-Object System.Collections.Generic.List[object]
    foreach ($item in (ConvertTo-RigArray (Get-RigChild $Profiles 'shared'))) { $settings.Add($item) }
    foreach ($game in $games) {
        foreach ($item in (ConvertTo-RigArray (Get-RigChild $game 'settings'))) { $settings.Add($item) }
        $cfg = Get-RigChild $game 'config'
        if ($null -ne $cfg) {
            if ($cfg['verified'] -ne $true -or [string]$cfg['purpose'] -ne 'presence') {
                $errors.Add("$([string]$game['id']) config must be a verified presence check")
            }
        }
    }
    foreach ($item in $settings) {
        $apply = [string](Get-RigChild $item 'apply')
        if ($apply -ne 'manual') { $errors.Add("$([string]$item['id']) must stay manual in phase 1") }
        if ([string](Get-RigChild $item 'value') -eq '240') { $errors.Add("$([string]$item['id']) hardcodes 240") }
    }
    return ,$errors
}

function Get-RigDriverState($Machine, $Observation) {
    $expected = [string](Get-RigPath $Machine @('driver', 'expected'))
    $source = [string]$Observation.DriverSource
    $version = [string]$Observation.DriverVersion
    if ($source -eq 'unavailable' -or [string]::IsNullOrWhiteSpace($version)) { return 'UNAVAILABLE' }
    if ($version -eq $expected) { return 'OK' }
    if ($source -eq 'windows') { return 'UNCOMPARED' }
    return 'DIFFERENT'
}

function Get-RigGpuState($Machine, $Observation) {
    $name = [string]$Observation.GpuName
    if ([string]::IsNullOrWhiteSpace($name)) { return 'SKIPPED' }
    if ($name.ToLowerInvariant().Contains('5070')) { return 'OK' }
    return 'DIFFERENT'
}

function New-RigAnalysis($Machine, $Observation) {
    $classified = New-Object System.Collections.Generic.List[object]
    foreach ($mon in (ConvertTo-RigArray $Observation.Monitors)) {
        $copy = @{
            Name       = [string]$mon.Name
            Width      = [int]$mon.Width
            Height     = [int]$mon.Height
            Hertz      = [int]$mon.Hertz
            Connection = [string]$mon.Connection
            Primary    = $false
            Selected   = $false
        }
        if ($mon.ContainsKey('Primary') -and $mon.Primary) { $copy.Primary = $true }
        if ([string]::IsNullOrWhiteSpace($copy.Connection)) { $copy.Connection = 'Unknown' }
        $copy.RoleHint = Get-RigRoleHint $Machine $copy
        $classified.Add($copy)
    }

    $tokens = Get-RigPath $Machine @('display', 'match_names')
    $preferred = [string](Get-RigPath $Machine @('display', 'preferred_resolution'))
    $externals = @($classified | Where-Object { $_.RoleHint -eq 'external' })
    $target = $null
    foreach ($mon in $externals) {
        if (Test-RigNameMatch $mon.Name $tokens) { $target = $mon; break }
    }
    if ($null -eq $target) {
        foreach ($mon in $externals) {
            if (('{0}x{1}' -f $mon.Width, $mon.Height) -eq $preferred) { $target = $mon; break }
        }
    }
    if ($null -eq $target -and $externals.Count -eq 1) { $target = $externals[0] }
    if ($null -ne $target) { $target.Selected = $true }

    $resolutionState = 'MISSING'
    $modeText = 'unavailable'
    if ($null -ne $target) {
        $modeText = '{0}x{1}' -f $target.Width, $target.Height
        if ($modeText -eq $preferred) { $resolutionState = 'OK' } else { $resolutionState = 'DIFFERENT' }
    }

    $refreshState = 'MISSING'
    $capHz = $null
    if ($null -ne $target -and $resolutionState -eq 'OK' -and $target.Hertz -ge 1) {
        $refreshState = 'OK'
        $capHz = [int]$target.Hertz
    }
    elseif ($null -ne $target -and $target.Hertz -ge 1) {
        $refreshState = 'OK'
    }
    elseif ($null -ne $target) {
        $refreshState = 'DIFFERENT'
    }

    $wantedConnection = [string](Get-RigPath $Machine @('display', 'connection'))
    $connectionState = 'SKIPPED'
    if ($null -ne $target) {
        if ([string]::IsNullOrWhiteSpace([string]$target.Connection) -or $target.Connection -eq 'Unknown') {
            $connectionState = 'UNCOMPARED'
        }
        elseif ($target.Connection.ToUpperInvariant() -eq $wantedConnection.ToUpperInvariant()) {
            $connectionState = 'OK'
        }
        else {
            $connectionState = 'DIFFERENT'
        }
    }

    $driverState = Get-RigDriverState $Machine $Observation
    $gpuState = Get-RigGpuState $Machine $Observation
    $exitCode = 0
    if ($driverState -ne 'OK') { $exitCode = 2 }
    if ($resolutionState -ne 'OK') { $exitCode = 2 }
    if ($resolutionState -eq 'OK' -and $refreshState -ne 'OK') { $exitCode = 2 }
    if ($connectionState -eq 'DIFFERENT') { $exitCode = 2 }
    if ($gpuState -eq 'DIFFERENT') { $exitCode = 2 }

    return @{
        Monitors         = $classified
        Target           = $target
        ResolutionState  = $resolutionState
        ModeText         = $modeText
        RefreshState     = $refreshState
        ConnectionState  = $connectionState
        DriverState      = $driverState
        GpuState         = $gpuState
        CapHz            = $capHz
        ExitCode         = $exitCode
    }
}

function Add-RigNote($Lines, [string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    $Lines.Add('    ' + $Text)
}

function Add-RigRow($Lines, [string]$Label, [string]$Value, [string]$Tag, [string]$State) {
    $line = '  {0,-36} {1}' -f $Label, $Value
    if (-not [string]::IsNullOrWhiteSpace($Tag)) { $line += '  [{0}]' -f $Tag }
    if (-not [string]::IsNullOrWhiteSpace($State)) { $line += '  {0}' -f $State }
    $Lines.Add($line)
}

function Get-RigCapNote($Machine, $Analysis) {
    $maxHz = [int](Get-RigPath $Machine @('display', 'panel_max_hz'))
    $preferred = [string](Get-RigPath $Machine @('display', 'preferred_resolution'))
    if ($null -ne $Analysis.CapHz) {
        $hz = [int]$Analysis.CapHz
        if ($hz -lt $maxHz) {
            return "The G93SD can run at $maxHz Hz. Windows is reporting $hz Hz, so the number to type is $hz."
        }
        return "Windows is reporting $hz Hz, so the number to type is $hz."
    }
    if ($Analysis.ResolutionState -eq 'DIFFERENT' -and $null -ne $Analysis.Target) {
        $seen = '{0}x{1} @ {2} Hz' -f $Analysis.Target.Width, $Analysis.Target.Height, $Analysis.Target.Hertz
        return "Set Windows to $preferred, then run status again. The current mode is $seen. Windows display mode stays as it is."
    }
    return 'The Odyssey was not found, so no FPS cap is suggested.'
}

function New-RigReport($Machine, $Profiles, $Observation) {
    $analysis = New-RigAnalysis $Machine $Observation
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('rig-check status')
    $lines.Add('Read-only. This run changes nothing.')
    $lines.Add('')

    $product = [string](Get-RigPath $Machine @('laptop', 'product'))
    $sku = [string](Get-RigPath $Machine @('laptop', 'sku'))
    Add-RigRow $lines 'Laptop' "$product ($sku)" '' ''
    Add-RigRow $lines 'Expected GPU' ([string](Get-RigPath $Machine @('laptop', 'gpu'))) '' ''
    $lines.Add('')
    $lines.Add('Displays')
    if ($analysis.Monitors.Count -eq 0) {
        $lines.Add('  none reported')
    }
    foreach ($mon in $analysis.Monitors) {
        $role = 'other'
        if ($mon.Selected) { $role = 'target' }
        elseif ($mon.RoleHint -eq 'internal') { $role = 'internal' }
        if ($mon.Hertz -ge 1) { $hzText = "$($mon.Hertz) Hz" } else { $hzText = 'unknown Hz' }
        $primary = ''
        if ($mon.Primary) { $primary = ' primary' }
        $lines.Add(('  {0,-10} {1}x{2} @ {3}  {4}{5}  {6}' -f $role, $mon.Width, $mon.Height, $hzText, $mon.Connection, $primary, $mon.Name))
    }
    $lines.Add('')

    $driverValue = [string]$Observation.DriverVersion
    if ([string]::IsNullOrWhiteSpace($driverValue)) { $driverValue = 'unavailable' }
    Add-RigRow $lines 'NVIDIA driver' $driverValue 'check' $analysis.DriverState
    $expectedDriver = [string](Get-RigPath $Machine @('driver', 'expected'))
    if ($analysis.DriverState -eq 'OK') {
        Add-RigNote $lines ("Read from {0}." -f $Observation.DriverSource)
    }
    elseif ($analysis.DriverState -eq 'UNCOMPARED') {
        Add-RigNote $lines "Expected $expectedDriver. Windows reported a raw driver version and nvidia-smi was not used, so this was not compared. Driver install and rollback stay manual."
    }
    else {
        Add-RigNote $lines "Expected $expectedDriver. Driver install and rollback stay manual."
    }

    $gpuName = [string]$Observation.GpuName
    if ([string]::IsNullOrWhiteSpace($gpuName)) { $gpuName = 'unavailable' }
    Add-RigRow $lines 'Detected GPU' $gpuName '' ''
    if ($analysis.GpuState -eq 'DIFFERENT') {
        Add-RigNote $lines ("Detected GPU name does not mention 5070. Expected {0}." -f (Get-RigPath $Machine @('laptop', 'gpu')))
    }

    $resolutionValue = $analysis.ModeText
    Add-RigRow $lines 'Resolution' $resolutionValue 'check' $analysis.ResolutionState
    if ($analysis.ResolutionState -eq 'DIFFERENT') {
        Add-RigNote $lines ("Preferred resolution is {0}. Windows display mode stays as it is." -f (Get-RigPath $Machine @('display', 'preferred_resolution')))
    }
    elseif ($analysis.ResolutionState -eq 'MISSING') {
        Add-RigNote $lines 'The Odyssey was not found. Windows display mode stays as it is.'
    }

    $refreshValue = 'unavailable'
    if ($null -ne $analysis.Target -and $analysis.Target.Hertz -ge 1) { $refreshValue = "$($analysis.Target.Hertz) Hz" }
    $refreshLabelState = $analysis.RefreshState
    if ($refreshLabelState -eq 'MISSING') { $refreshLabelState = 'DIFFERENT' }
    Add-RigRow $lines 'Refresh' $refreshValue 'check' $refreshLabelState

    $connectionValue = 'unavailable'
    if ($null -ne $analysis.Target) { $connectionValue = [string]$analysis.Target.Connection }
    $connectionLabel = $analysis.ConnectionState
    if ($connectionLabel -eq 'SKIPPED') { $connectionLabel = 'DIFFERENT' }
    Add-RigRow $lines 'Connection' $connectionValue 'check' $connectionLabel
    if ($analysis.ConnectionState -eq 'DIFFERENT') {
        Add-RigNote $lines 'Preferred connection is HDMI. The cable and port stay as they are.'
    }
    elseif ($analysis.ConnectionState -eq 'UNCOMPARED') {
        Add-RigNote $lines 'Preferred connection is HDMI. The link type was not identified.'
    }

    Add-RigRow $lines 'G-SYNC' ([string](Get-RigChild $Machine 'gsync')) 'manual' ''
    Add-RigNote $lines 'Confirm this in NVIDIA Control Panel. The driver profile database is not read.'
    Add-RigRow $lines 'HDR' ([string](Get-RigChild $Machine 'hdr')) 'manual' ''
    Add-RigNote $lines 'HDR stays as it is.'
    $lines.Add('')

    $capText = 'unavailable'
    if ($null -ne $analysis.CapHz) { $capText = [string]$analysis.CapHz }
    $capNote = Get-RigCapNote $Machine $analysis

    $lines.Add('Shared settings')
    foreach ($setting in (ConvertTo-RigArray (Get-RigChild $Profiles 'shared'))) {
        $value = [string]$setting['value']
        if ($setting['id'] -eq 'fps_cap') { $value = $capText }
        Add-RigRow $lines ([string]$setting['label']) $value ([string]$setting['apply']) ''
        if ($setting['id'] -eq 'fps_cap') {
            Add-RigNote $lines $capNote
        }
        else {
            Add-RigNote $lines ([string](Get-RigChild $setting 'note'))
        }
    }
    $lines.Add('')

    foreach ($game in (ConvertTo-RigArray (Get-RigChild $Profiles 'games'))) {
        $lines.Add([string]$game['name'])
        Add-RigRow $lines 'FPS cap' $capText 'manual' ''
        foreach ($setting in (ConvertTo-RigArray (Get-RigChild $game 'settings'))) {
            Add-RigRow $lines ([string]$setting['label']) ([string]$setting['value']) ([string]$setting['apply']) ''
            Add-RigNote $lines ([string](Get-RigChild $setting 'note'))
        }
        $cfg = Get-RigChild $game 'config'
        if ($null -ne $cfg) {
            $state = $null
            if ($null -ne $Observation.Config -and $Observation.Config.ContainsKey([string]$game['id'])) {
                $state = $Observation.Config[[string]$game['id']]
            }
            if ($null -eq $state) {
                Add-RigRow $lines 'Config folder' 'not checked' 'manual' ''
            }
            elseif ($state.Exists) {
                Add-RigRow $lines 'Config folder' 'present' 'manual' ''
                Add-RigNote $lines ([string]$state.Path)
            }
            else {
                Add-RigRow $lines 'Config folder' 'not found' 'manual' ''
                Add-RigNote $lines ([string]$state.Path)
            }
            Add-RigNote $lines 'Presence only. File contents are not read.'
        }
        else {
            Add-RigRow $lines 'Config files' 'Not read. Set these in the game.' 'manual' ''
        }
        $lines.Add('')
    }

    $lines.Add('NVIDIA Control Panel, set by hand')
    foreach ($item in (ConvertTo-RigArray (Get-RigChild $Machine 'nvidia_checklist'))) {
        Add-RigRow $lines ([string]$item['label']) ([string]$item['value']) 'manual' ''
    }
    $lines.Add('')
    $lines.Add('Left alone')
    foreach ($item in (ConvertTo-RigArray (Get-RigChild $Machine 'never_touch'))) {
        $lines.Add('  ' + [string]$item)
    }
    $lines.Add('')
    $lines.Add('PredatorSense')
    Add-RigNote $lines ([string](Get-RigChild $Machine 'predator_sense'))
    $lines.Add('')
    $lines.Add('No files were written.')

    return @{
        Report   = ($lines -join [Environment]::NewLine)
        ExitCode = [int]$analysis.ExitCode
    }
}

function Initialize-RigDisplayNative {
    foreach ($asm in [AppDomain]::CurrentDomain.GetAssemblies()) {
        if ($asm.GetType('RigCheck.DisplayNative', $false)) { return }
    }
    Add-Type -TypeDefinition $script:RigDisplaySource -Language CSharp -ErrorAction Stop
}

function ConvertTo-RigConnection($Code) {
    if ($null -eq $Code -or [string]$Code -eq '') { return 'Unknown' }
    $n = 0L
    try { $n = [int64]$Code } catch { return 'Unknown' }
    if ($n -eq 0) { return 'VGA' }
    if ($n -eq 4) { return 'DVI' }
    if ($n -eq 5) { return 'HDMI' }
    if ($n -eq 6 -or $n -eq 11) { return 'Internal' }
    if ($n -eq 10) { return 'DisplayPort' }
    if ($n -eq 2147483648 -or $n -eq -2147483648) { return 'Internal' }
    return 'Unknown'
}

function ConvertFrom-RigUInt16String($Values) {
    if ($null -eq $Values) { return '' }
    if ($Values -is [string]) { return $Values.Trim() }
    $chars = New-Object System.Collections.Generic.List[char]
    foreach ($n in (ConvertTo-RigArray $Values)) {
        if ([int]$n -eq 0) { break }
        $chars.Add([char]([int]$n))
    }
    return (-join $chars).Trim()
}

function Get-RigHardwareToken([string]$Id) {
    if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
    $match = [regex]::Match($Id, '(?i)(?:MONITOR|DISPLAY)\\([A-Z0-9]+)')
    if ($match.Success) { return $match.Groups[1].Value.ToUpperInvariant() }
    return $null
}

function Get-RigWmiMonitors {
    $byToken = @{}
    try {
        $ids = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop)
        $conns = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams -ErrorAction Stop)
    }
    catch {
        return $byToken
    }
    $connByInstance = @{}
    foreach ($conn in $conns) {
        $connByInstance[[string]$conn.InstanceName] = $conn
    }
    foreach ($id in $ids) {
        $token = Get-RigHardwareToken ([string]$id.InstanceName)
        if ($null -eq $token) { continue }
        $friendly = ConvertFrom-RigUInt16String $id.UserFriendlyName
        $connection = 'Unknown'
        if ($connByInstance.ContainsKey([string]$id.InstanceName)) {
            $connection = ConvertTo-RigConnection $connByInstance[[string]$id.InstanceName].VideoOutputTechnology
        }
        $byToken[$token] = @{ Name = $friendly; Connection = $connection }
    }
    return $byToken
}

function Get-RigGdiMonitors {
    Initialize-RigDisplayNative
    $wmi = Get-RigWmiMonitors
    $list = New-Object System.Collections.Generic.List[object]
    $deviceSize = [Runtime.InteropServices.Marshal]::SizeOf([type]'RigCheck.DisplayNative+DISPLAY_DEVICE')
    $modeSize = [Runtime.InteropServices.Marshal]::SizeOf([type]'RigCheck.DisplayNative+DEVMODE')

    for ($i = 0; $i -lt 16; $i++) {
        $dd = New-Object RigCheck.DisplayNative+DISPLAY_DEVICE
        $dd.cb = $deviceSize
        $ok = [RigCheck.DisplayNative]::EnumDisplayDevices([NullString]::Value, [uint32]$i, [ref]$dd, [uint32]0)
        if (-not $ok) { break }
        $attached = 1
        $mirroring = 8
        $primaryFlag = 4
        if (($dd.StateFlags -band $attached) -eq 0) { continue }
        if (($dd.StateFlags -band $mirroring) -ne 0) { continue }

        $dm = New-Object RigCheck.DisplayNative+DEVMODE
        $dm.dmSize = [int16]$modeSize
        $okMode = [RigCheck.DisplayNative]::EnumDisplaySettings([string]$dd.DeviceName, -1, [ref]$dm)
        if (-not $okMode) { continue }

        $child = New-Object RigCheck.DisplayNative+DISPLAY_DEVICE
        $child.cb = $deviceSize
        $hasChild = [RigCheck.DisplayNative]::EnumDisplayDevices([string]$dd.DeviceName, [uint32]0, [ref]$child, [uint32]0)
        $name = 'Unknown display'
        $token = $null
        if ($hasChild) {
            if (-not [string]::IsNullOrWhiteSpace([string]$child.DeviceString)) { $name = ([string]$child.DeviceString).Trim() }
            $token = Get-RigHardwareToken ([string]$child.DeviceID)
        }
        $connection = 'Unknown'
        if ($null -ne $token -and $wmi.ContainsKey($token)) {
            $info = $wmi[$token]
            if (-not [string]::IsNullOrWhiteSpace([string]$info.Name)) {
                if ($name -eq 'Unknown display' -or $name -match 'Generic|PnP') { $name = [string]$info.Name }
            }
            if ([string]$info.Connection -ne '' -and [string]$info.Connection -ne 'Unknown') {
                $connection = [string]$info.Connection
            }
        }
        $list.Add(@{
            Name       = $name
            Width      = [int]$dm.dmPelsWidth
            Height     = [int]$dm.dmPelsHeight
            Hertz      = [int]$dm.dmDisplayFrequency
            Connection = $connection
            Primary    = (($dd.StateFlags -band $primaryFlag) -ne 0)
        })
    }
    return ,$list
}

function Get-RigDriverObservation {
    $command = $null
    try { $command = Get-Command nvidia-smi -ErrorAction SilentlyContinue } catch { $command = $null }
    if ($null -ne $command) {
        try {
            $raw = & $command.Source --query-gpu=driver_version,name --format=csv,noheader
            if ($LASTEXITCODE -eq 0 -and $null -ne $raw) {
                $rows = @($raw | Where-Object { $_ -is [string] -and $_.Trim() -ne '' })
                $pick = $null
                foreach ($row in $rows) {
                    if ($row -match '5070') { $pick = $row; break }
                }
                if ($null -eq $pick -and $rows.Count -gt 0) { $pick = [string]$rows[0] }
                if (-not [string]::IsNullOrWhiteSpace([string]$pick)) {
                    $text = ([string]$pick).Trim()
                    $idx = $text.IndexOf(',')
                    if ($idx -lt 0) {
                        return @{ DriverVersion = $text.Trim('"'); DriverSource = 'nvidia-smi'; GpuName = '' }
                    }
                    return @{
                        DriverVersion = $text.Substring(0, $idx).Trim().Trim('"')
                        DriverSource  = 'nvidia-smi'
                        GpuName       = $text.Substring($idx + 1).Trim().Trim('"')
                    }
                }
            }
        }
        catch { }
    }

    try {
        $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction Stop | Where-Object { $_.Name -match 'NVIDIA' })
        if ($gpus.Count -gt 0) {
            $pick = $gpus[0]
            foreach ($gpu in $gpus) {
                if ([string]$gpu.Name -match '5070') { $pick = $gpu; break }
            }
            return @{
                DriverVersion = [string]$pick.DriverVersion
                DriverSource  = 'windows'
                GpuName       = [string]$pick.Name
            }
        }
    }
    catch { }

    return @{ DriverVersion = ''; DriverSource = 'unavailable'; GpuName = '' }
}

function Get-RigConfigObservation($Profiles) {
    $state = @{}
    $docs = [Environment]::GetFolderPath('MyDocuments')
    foreach ($game in (ConvertTo-RigArray (Get-RigChild $Profiles 'games'))) {
        $cfg = Get-RigChild $game 'config'
        $full = Get-RigConfigPath $cfg $docs
        if ($null -eq $full) { continue }
        $exists = $false
        try { $exists = Test-Path -LiteralPath $full } catch { $exists = $false }
        $state[[string]$game['id']] = @{ Path = $full; Exists = $exists }
    }
    return $state
}

function Test-RigHostWindows {
    if ($PSVersionTable.PSVersion.Major -ge 6) { return [bool]$IsWindows }
    return $env:OS -eq 'Windows_NT'
}

function Get-RigSettingsFiles {
    $root = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($root)) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
    $machinePath = Join-Path $root 'machine.yaml'
    $profilePath = Join-Path $root 'profiles.yaml'
    if (-not (Test-Path -LiteralPath $machinePath) -or -not (Test-Path -LiteralPath $profilePath)) {
        throw 'machine.yaml and profiles.yaml must sit beside rig-check.ps1.'
    }
    $machine = ConvertFrom-RigYaml (Get-Content -LiteralPath $machinePath -Raw)
    $profiles = ConvertFrom-RigYaml (Get-Content -LiteralPath $profilePath -Raw)
    return @{ Machine = $machine; Profiles = $profiles }
}

function Invoke-RigStatus {
    $docs = Get-RigSettingsFiles
    $problems = (ConvertTo-RigArray (Get-RigValidationErrors $docs.Machine $docs.Profiles))
    if ($problems.Count -gt 0) {
        Write-Output 'Settings files are invalid.'
        foreach ($problem in $problems) { Write-Output $problem }
        Write-Output 'No files were written.'
        $script:RigExitCode = 1
        return
    }
    try {
        $monitors = Get-RigGdiMonitors
    }
    catch {
        Write-Output ("Display read failed: {0}" -f $_.Exception.Message)
        Write-Output 'No files were written.'
        $script:RigExitCode = 1
        return
    }
    $driver = Get-RigDriverObservation
    $observation = @{
        DriverVersion = [string]$driver.DriverVersion
        DriverSource  = [string]$driver.DriverSource
        GpuName       = [string]$driver.GpuName
        Monitors      = $monitors
        Config        = Get-RigConfigObservation $docs.Profiles
    }
    $result = New-RigReport $docs.Machine $docs.Profiles $observation
    Write-Output $result.Report
    $script:RigExitCode = [int]$result.ExitCode
}

function Invoke-RigSelfTest {
    $failures = New-Object System.Collections.Generic.List[string]

    function Add-Failure([string]$Message) {
        $failures.Add($Message)
    }

    $docs = $null
    try { $docs = Get-RigSettingsFiles } catch { Add-Failure $_.Exception.Message }
    if ($null -eq $docs) {
        foreach ($failure in $failures) { Write-Output $failure }
        $script:RigExitCode = 1
        return
    }

    $machine = $docs.Machine
    $profiles = $docs.Profiles
    foreach ($problem in (ConvertTo-RigArray (Get-RigValidationErrors $machine $profiles))) {
        Add-Failure $problem
    }

    $games = (ConvertTo-RigArray (Get-RigChild $profiles 'games'))
    $byId = @{}
    foreach ($game in $games) { $byId[[string]$game['id']] = $game }

    $fov = $null
    foreach ($setting in (ConvertTo-RigArray (Get-RigChild $byId['iracing'] 'settings'))) {
        if ($setting['id'] -eq 'fov') { $fov = [string]$setting['value'] }
        if ($setting['id'] -eq 'rendering' -and [string]$setting['value'] -notmatch '32:9') {
            Add-Failure 'iRacing rendering should say single 32:9'
        }
        if ($setting['id'] -eq 'dlss' -and [string]$setting['value'] -notmatch 'Quality only') {
            Add-Failure 'iRacing DLSS should stay off unless the cap is missed'
        }
    }
    if ($fov -ne 'unset') { Add-Failure 'iRacing field of view must stay unset' }

    foreach ($setting in (ConvertTo-RigArray (Get-RigChild $byId['acc'] 'settings'))) {
        if ($setting['id'] -eq 'antialiasing' -and [string]$setting['value'] -ne 'Temporal') {
            Add-Failure 'ACC anti-aliasing should be Temporal'
        }
        if ($setting['id'] -eq 'dlss' -and [string]$setting['value'] -notmatch 'ghosts') {
            Add-Failure 'ACC DLSS note should mention ghosts'
        }
    }
    foreach ($setting in (ConvertTo-RigArray (Get-RigChild $byId['ace'] 'settings'))) {
        if ($setting['id'] -eq 'dlss' -and [string]$setting['value'] -ne 'Quality') { Add-Failure 'ACE DLSS should be Quality' }
        if ($setting['id'] -eq 'dlss_files' -and [string]$setting['value'] -notmatch 'Leave the game files alone') {
            Add-Failure 'ACE must leave DLSS files alone'
        }
    }
    if ($null -ne (Get-RigChild $byId['ace'] 'config')) { Add-Failure 'ACE has no confirmed config path' }
    if ($null -ne (Get-RigChild $byId['fh6'] 'config')) { Add-Failure 'Forza has no confirmed config path' }
    if ($null -ne (Get-RigChild $byId['bf6'] 'config')) { Add-Failure 'Battlefield has no confirmed config path' }
    foreach ($setting in (ConvertTo-RigArray (Get-RigChild $byId['fh6'] 'settings'))) {
        if ($setting['id'] -eq 'ray_tracing' -and [string]$setting['value'] -notmatch '^Off') {
            Add-Failure 'Forza ray tracing should start off'
        }
    }
    foreach ($setting in (ConvertTo-RigArray (Get-RigChild $byId['bf6'] 'settings'))) {
        if ($setting['id'] -eq 'reflex' -and [string]$setting['value'] -ne 'On') { Add-Failure 'Battlefield Reflex should be On' }
        if ($setting['id'] -eq 'future_frame' -and [string]$setting['value'] -ne 'Off') { Add-Failure 'Battlefield future frame rendering should be Off' }
    }

    $joined = Get-RigConfigPath $byId['acc']['config'] 'C:\Docs'
    if ($joined -notmatch 'Assetto Corsa Competizione' -or $joined -notmatch 'Config') {
        Add-Failure "ACC path join failed: $joined"
    }
    if ($null -ne (Get-RigConfigPath @{ verified = $false; purpose = 'presence'; root = 'documents'; path = 'iRacing' } 'C:\Docs')) {
        Add-Failure 'unverified config paths must not be checked'
    }

    try {
        ConvertFrom-RigYaml "schema: 1`n`tlaptop: x" | Out-Null
        Add-Failure 'tab yaml should throw'
    }
    catch {
        if ($_.Exception.Message -notmatch 'tab') { Add-Failure $_.Exception.Message }
    }
    try {
        ConvertFrom-RigYaml "schema: 1`nschema: 2" | Out-Null
        Add-Failure 'duplicate key should throw'
    }
    catch {
        if ($_.Exception.Message -notmatch 'duplicate') { Add-Failure $_.Exception.Message }
    }

    $sample = ConvertFrom-RigYaml @"
schema: 1
display:
  match_names:
    - G93SD
games:
  - id: iracing
    name: iRacing
    settings:
      - id: fov
        value: unset
        apply: manual
"@
    $sampleGames = (ConvertTo-RigArray (Get-RigChild $sample 'games'))
    if ($sampleGames.Count -ne 1 -or [string]$sampleGames[0]['id'] -ne 'iracing') {
        Add-Failure 'sample yaml did not parse one game'
    }

    $config = @{
        iracing = @{ Path = 'C:\Users\John\Documents\iRacing'; Exists = $true }
        acc     = @{ Path = 'C:\Users\John\Documents\Assetto Corsa Competizione\Config'; Exists = $false }
    }
    function New-Fixture($Driver, $Source, $Gpu, $Monitors) {
        return @{
            DriverVersion = $Driver
            DriverSource  = $Source
            GpuName       = $Gpu
            Monitors      = $Monitors
            Config        = $config
        }
    }

    $laptop = @{ Name = 'Laptop panel'; Width = 2560; Height = 1600; Hertz = 240; Connection = 'Internal'; Primary = $true }
    $odyssey = @{ Name = 'SAMSUNG Odyssey G93SD'; Width = 5120; Height = 1440; Hertz = 120; Connection = 'HDMI'; Primary = $false }
    $good = New-RigReport $machine $profiles (New-Fixture '616.92' 'nvidia-smi' 'NVIDIA GeForce RTX 5070 Ti Laptop GPU' @($laptop, $odyssey))
    $goodReport = [string]$good.Report
    if ($good.ExitCode -ne 0) { Add-Failure "good fixture exit $($good.ExitCode)"; Add-Failure $goodReport }
    $capHits = [regex]::Matches($goodReport, 'FPS cap\s+120')
    if ($capHits.Count -ne 6) { Add-Failure "expected 6 FPS cap rows at 120, got $($capHits.Count)"; Add-Failure $goodReport }
    foreach ($needle in @(
            'No files were written.',
            'Borderless',
            'The G93SD can run at 240 Hz. Windows is reporting 120 Hz',
            'present',
            'not found',
            'Leave the game files alone',
            'unset',
            'PredatorSense'
        )) {
        if (-not $goodReport.Contains($needle)) { Add-Failure "good report missing: $needle" }
    }
    if ($goodReport.Contains('DIFFERENT')) { Add-Failure 'good report should not contain DIFFERENT' }
    if ($goodReport.Contains('match_display_hz')) { Add-Failure 'good report leaked the cap token' }
    if ($goodReport -match 'FPS cap\s+240') { Add-Failure 'good report used 240 as the cap' }

    $badDriver = New-RigReport $machine $profiles (New-Fixture '572.16' 'nvidia-smi' 'NVIDIA GeForce RTX 5070 Ti Laptop GPU' @($laptop, $odyssey))
    if ($badDriver.ExitCode -ne 2) { Add-Failure 'driver mismatch should exit 2' }
    if ([string]$badDriver.Report -notmatch 'DIFFERENT' -or [string]$badDriver.Report -notmatch 'Driver install and rollback stay manual') {
        Add-Failure 'driver mismatch report is incomplete'
    }
    if ([regex]::Matches([string]$badDriver.Report, 'FPS cap\s+120').Count -ne 6) {
        Add-Failure 'driver mismatch should still show cap 120'
    }

    $rawDriver = New-RigReport $machine $profiles (New-Fixture '32.0.15.7692' 'windows' 'NVIDIA GeForce RTX 5070 Ti Laptop GPU' @($laptop, $odyssey))
    if ($rawDriver.ExitCode -ne 2 -or [string]$rawDriver.Report -notmatch 'UNCOMPARED') {
        Add-Failure 'raw Windows driver version should be UNCOMPARED'
    }

    $laptopOnly = New-RigReport $machine $profiles (New-Fixture '616.92' 'nvidia-smi' 'NVIDIA GeForce RTX 5070 Ti Laptop GPU' @($laptop))
    if ($laptopOnly.ExitCode -ne 2) { Add-Failure 'laptop-only should exit 2' }
    $laptopReport = [string]$laptopOnly.Report
    if ($laptopReport -notmatch 'The Odyssey was not found') { Add-Failure 'laptop-only should say the Odyssey was not found' }
    if ($laptopReport -match 'FPS cap\s+240' -or $laptopReport -match 'FPS cap\s+120') {
        Add-Failure 'laptop-only must not suggest the internal refresh'
    }
    if ($laptopReport -notmatch '2560x1600') { Add-Failure 'laptop-only should list the internal panel' }

    $wrongMode = @{ Name = 'Generic PnP Monitor'; Width = 3840; Height = 1080; Hertz = 60; Connection = 'HDMI'; Primary = $false }
    $wrong = New-RigReport $machine $profiles (New-Fixture '616.92' 'nvidia-smi' 'NVIDIA GeForce RTX 5070 Ti Laptop GPU' @($laptop, $wrongMode))
    if ($wrong.ExitCode -ne 2) { Add-Failure 'wrong resolution should exit 2' }
    if ([string]$wrong.Report -notmatch 'Preferred resolution is 5120x1440' -or [string]$wrong.Report -match 'FPS cap\s+60') {
        Add-Failure 'wrong resolution must not publish that refresh as the cap'
    }

    $genericGood = @{ Name = 'Generic PnP Monitor'; Width = 5120; Height = 1440; Hertz = 240; Connection = 'HDMI'; Primary = $false }
    $generic = New-RigReport $machine $profiles (New-Fixture '616.92' 'nvidia-smi' 'NVIDIA GeForce RTX 5070 Ti Laptop GPU' @($laptop, $genericGood))
    if ($generic.ExitCode -ne 0) { Add-Failure "generic 5120x1440 should exit 0, got $($generic.ExitCode)" }
    if ([regex]::Matches([string]$generic.Report, 'FPS cap\s+240').Count -ne 6) {
        Add-Failure 'generic 5120x1440 at 240 should cap at 240'
    }

    $namedWrong = @{ Name = 'SAMSUNG Odyssey G93SD'; Width = 2560; Height = 1080; Hertz = 120; Connection = 'HDMI'; Primary = $false }
    $otherWide = @{ Name = 'Generic PnP Monitor'; Width = 5120; Height = 1440; Hertz = 120; Connection = 'HDMI'; Primary = $false }
    $nameWins = New-RigReport $machine $profiles (New-Fixture '616.92' 'nvidia-smi' 'NVIDIA GeForce RTX 5070 Ti Laptop GPU' @($laptop, $otherWide, $namedWrong))
    if ($nameWins.ExitCode -ne 2 -or [string]$nameWins.Report -notmatch 'target\s+2560x1080') {
        Add-Failure 'Odyssey name should win over another 5120x1440 display'
    }

    $twoExternals = @(
        $laptop,
        @{ Name = 'Generic PnP Monitor'; Width = 1920; Height = 1080; Hertz = 60; Connection = 'HDMI'; Primary = $false },
        @{ Name = 'Generic PnP Monitor'; Width = 2560; Height = 1440; Hertz = 144; Connection = 'HDMI'; Primary = $false }
    )
    $ambiguous = New-RigReport $machine $profiles (New-Fixture '616.92' 'nvidia-smi' 'NVIDIA GeForce RTX 5070 Ti Laptop GPU' $twoExternals)
    if ($ambiguous.ExitCode -ne 2 -or [string]$ambiguous.Report -notmatch 'The Odyssey was not found') {
        Add-Failure 'two unmatched externals should stay unresolved'
    }

    $displayPort = @{ Name = 'SAMSUNG Odyssey G93SD'; Width = 5120; Height = 1440; Hertz = 120; Connection = 'DisplayPort'; Primary = $false }
    $port = New-RigReport $machine $profiles (New-Fixture '616.92' 'nvidia-smi' 'NVIDIA GeForce RTX 5070 Ti Laptop GPU' @($laptop, $displayPort))
    if ($port.ExitCode -ne 2 -or [string]$port.Report -notmatch 'Preferred connection is HDMI') {
        Add-Failure 'DisplayPort should be reported and left alone'
    }

    $wrongGpu = New-RigReport $machine $profiles (New-Fixture '616.92' 'nvidia-smi' 'NVIDIA GeForce RTX 4060 Laptop GPU' @($laptop, $odyssey))
    if ($wrongGpu.ExitCode -ne 2 -or [string]$wrongGpu.Report -notmatch 'does not mention 5070') {
        Add-Failure 'a non-5070 GPU name should fail the check'
    }

    $scriptPath = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($scriptPath)) { $scriptPath = $MyInvocation.MyCommand.Path }
    $source = Get-Content -LiteralPath $scriptPath -Raw
    $needles = @(
        ('Set-' + 'Content'),
        ('Add-' + 'Content'),
        ('Out-' + 'File'),
        ('New-' + 'Item'),
        ('Remove-' + 'Item'),
        ('Clear-' + 'Content'),
        ('Set-' + 'ItemProperty'),
        ('Copy-' + 'Item'),
        ('Move-' + 'Item'),
        ('Rename-' + 'Item'),
        ('Invoke-' + 'WebRequest'),
        ('Invoke-' + 'RestMethod'),
        ('Start-' + 'Process'),
        ('ChangeDisplay' + 'Settings'),
        ('SetDisplay' + 'Config'),
        ('Stream' + 'Writer'),
        ('File]::' + 'Write')
    )
    foreach ($needle in $needles) {
        if ($source.Contains($needle)) { Add-Failure "write API present: $needle" }
    }

    try {
        Initialize-RigDisplayNative
        $devSize = [Runtime.InteropServices.Marshal]::SizeOf([type]'RigCheck.DisplayNative+DEVMODE')
        $dispSize = [Runtime.InteropServices.Marshal]::SizeOf([type]'RigCheck.DisplayNative+DISPLAY_DEVICE')
        if ($devSize -ne 220) { Add-Failure "DEVMODE size $devSize, expected 220" }
        if ($dispSize -ne 840) { Add-Failure "DISPLAY_DEVICE size $dispSize, expected 840" }
    }
    catch {
        Add-Failure ("display helper compile failed: {0}" -f $_.Exception.Message)
    }

    if ([string](ConvertTo-RigConnection 5) -ne 'HDMI') { Add-Failure 'HDMI code 5 was not mapped' }
    if ([string](ConvertTo-RigConnection 2147483648) -ne 'Internal') { Add-Failure 'internal output code was not mapped' }
    if ((Get-RigHardwareToken 'MONITOR\SAM7305\{guid}\0001') -ne 'SAM7305') { Add-Failure 'monitor hardware token parse failed' }

    if ($failures.Count -gt 0) {
        foreach ($failure in $failures) { Write-Output $failure }
        $script:RigExitCode = 1
        return
    }
    Write-Output 'selftest ok'
    $script:RigExitCode = 0
}

if ($Command -eq 'selftest') {
    Invoke-RigSelfTest
    exit $script:RigExitCode
}

if (-not (Test-RigHostWindows)) {
    Write-Output 'status reads the Windows display mode and the NVIDIA driver. Run it on the laptop. selftest can run on this machine.'
    exit 1
}

Invoke-RigStatus
exit $script:RigExitCode
