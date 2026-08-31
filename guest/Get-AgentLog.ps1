<#
.SYNOPSIS
    Prints the tail of the dark-mode sync agent log for the interactive user.

.DESCRIPTION
    Pushed from the Mac via 'prlctl exec', which runs as SYSTEM -- so $env:LOCALAPPDATA
    would point at SYSTEM's profile rather than the signed-in user's. This resolves the
    console user's profile directory explicitly.
#>

[CmdletBinding()]
param(
    [int] $Tail = 40
)

$ErrorActionPreference = 'Stop'

$me = [System.Security.Principal.WindowsIdentity]::GetCurrent()

if ($me.IsSystem) {
    $consoleUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
    if (-not $consoleUser) {
        Write-Output 'No interactive user is signed in, so there is no agent log to read.'
        return
    }
    $sid = (New-Object System.Security.Principal.NTAccount($consoleUser)).Translate(
        [System.Security.Principal.SecurityIdentifier]).Value
} else {
    $sid = $me.User.Value
}

$profileKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
$profileDir = (Get-ItemProperty -LiteralPath $profileKey -Name ProfileImagePath).ProfileImagePath
$appDir      = Join-Path $profileDir 'AppData\Local\DarkModeSync'
$logFile     = Join-Path $appDir 'agent.log'
$launcherLog = Join-Path $appDir 'launcher.log'

if (-not (Test-Path -LiteralPath $logFile)) {
    Write-Output "No agent log at $logFile -- the agent may not have run yet."
} else {
    Get-Content -LiteralPath $logFile -Tail $Tail
}

# The launcher only writes when it starts or has to restart the agent, so this is
# usually a couple of lines -- but it is where a crash-looping agent shows up.
if (Test-Path -LiteralPath $launcherLog) {
    Write-Output ''
    Write-Output '-- launcher --'
    Get-Content -LiteralPath $launcherLog -Tail 10
}
