<#
.SYNOPSIS
    Mirrors the macOS host's light/dark appearance into this Windows guest.

.DESCRIPTION
    Reads a one-line state file published by the host watcher ("dark" or "light")
    over the Parallels shared folder and applies it to the current user's
    personalization settings, then broadcasts WM_SETTINGCHANGE so running apps,
    Explorer, the taskbar and Start pick the change up without a sign-out.

    The sync is one-way: the Mac is authoritative. If the theme is changed inside
    Windows it is snapped back on the next poll. Set -NoEnforce to allow the guest
    to hold a manual override until the host next changes.

    Must run in the interactive user's session -- it writes to HKCU.
#>

[CmdletBinding()]
param(
    # Host state file, as seen from inside the guest.
    [string] $StatePath = '\\Mac\Home\.darkmode-sync\state',

    # How often to re-read the host state, in seconds.
    [double] $PollSeconds = 1.5,

    # Apply once and exit, instead of watching.
    [switch] $Once,

    # Don't correct theme changes made inside Windows.
    [switch] $NoEnforce,

    # Write log lines to stdout as well as the log file.
    [switch] $LogToConsole
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$PersonalizeKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$AppDir  = Join-Path $env:LOCALAPPDATA 'DarkModeSync'
$LogFile = Join-Path $AppDir 'agent.log'
$MaxLogBytes = 256KB

if (-not (Test-Path -LiteralPath $AppDir)) {
    New-Item -Path $AppDir -ItemType Directory -Force | Out-Null
}

function Write-Log {
    param([string] $Message)

    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'), $Message
    try {
        if ((Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -gt $MaxLogBytes) {
            # Keep the tail so the log stays useful but bounded.
            $keep = Get-Content -LiteralPath $LogFile -Tail 200
            Set-Content -LiteralPath $LogFile -Value $keep -Encoding UTF8
        }
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    } catch {
        # Logging must never take the agent down.
    }
    if ($LogToConsole) { Write-Output $line }
}

Add-Type -Namespace DarkModeSync -Name Native -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@

function Send-SettingChange {
    $HWND_BROADCAST   = [IntPtr] 0xFFFF
    $WM_SETTINGCHANGE = 0x001A
    $SMTO_ABORTIFHUNG = 0x0002

    foreach ($section in 'ImmersiveColorSet', 'WindowsThemeElement') {
        $result = [UIntPtr]::Zero
        [void] [DarkModeSync.Native]::SendMessageTimeout(
            $HWND_BROADCAST, $WM_SETTINGCHANGE, [UIntPtr]::Zero,
            $section, $SMTO_ABORTIFHUNG, 1000, [ref] $result)
    }
}

function Get-HostMode {
    <# Returns 'dark', 'light', or $null when the host state can't be read. #>
    try {
        $raw = Get-Content -LiteralPath $StatePath -TotalCount 1 -ErrorAction Stop
    } catch {
        return $null
    }
    if ($null -eq $raw) { return $null }

    switch ($raw.Trim().ToLowerInvariant()) {
        'dark'  { return 'dark' }
        'light' { return 'light' }
        default { return $null }
    }
}

function Get-GuestMode {
    <# Returns 'dark', 'light', or 'mixed' if the two values disagree. #>
    try {
        $key = Get-ItemProperty -LiteralPath $PersonalizeKey -ErrorAction Stop
    } catch {
        return $null
    }

    # Windows defaults to light when the values are absent.
    $apps   = if ($key.PSObject.Properties['AppsUseLightTheme'])   { [int] $key.AppsUseLightTheme }   else { 1 }
    $system = if ($key.PSObject.Properties['SystemUsesLightTheme']) { [int] $key.SystemUsesLightTheme } else { 1 }

    if ($apps -ne $system) { return 'mixed' }
    return $(if ($apps -eq 0) { 'dark' } else { 'light' })
}

function Set-GuestMode {
    param([ValidateSet('dark', 'light')] [string] $Mode)

    # 0 = dark, 1 = light.
    $value = if ($Mode -eq 'dark') { 0 } else { 1 }

    if (-not (Test-Path -LiteralPath $PersonalizeKey)) {
        New-Item -Path $PersonalizeKey -Force | Out-Null
    }
    New-ItemProperty -LiteralPath $PersonalizeKey -Name 'AppsUseLightTheme' `
        -Value $value -PropertyType DWord -Force | Out-Null
    New-ItemProperty -LiteralPath $PersonalizeKey -Name 'SystemUsesLightTheme' `
        -Value $value -PropertyType DWord -Force | Out-Null

    Send-SettingChange
}

# --- main -------------------------------------------------------------------

Write-Log "agent starting (state: $StatePath, poll: ${PollSeconds}s, enforce: $(-not $NoEnforce))"

$lastHostMode = $null
$warnedUnreadable = $false

while ($true) {
    $hostMode = Get-HostMode

    if ($null -eq $hostMode) {
        if (-not $warnedUnreadable) {
            Write-Log "cannot read host state at $StatePath -- retrying"
            $warnedUnreadable = $true
        }
    } else {
        if ($warnedUnreadable) {
            Write-Log 'host state readable again'
            $warnedUnreadable = $false
        }

        $hostChanged = ($hostMode -ne $lastHostMode)
        $guestMode = Get-GuestMode
        $drifted = ($guestMode -ne $hostMode)

        # Apply when the host changed, or when Windows has drifted and we enforce.
        if ($hostChanged -or ($drifted -and -not $NoEnforce)) {
            if ($drifted) {
                $reason = if ($hostChanged) { 'host changed' } else { 'guest drifted' }
                Set-GuestMode -Mode $hostMode
                Write-Log "applied $hostMode ($reason; guest was $guestMode)"
            } elseif ($hostChanged) {
                Write-Log "host is $hostMode; guest already matches"
            }
            $lastHostMode = $hostMode
        }
    }

    if ($Once) { break }
    Start-Sleep -Seconds $PollSeconds
}
