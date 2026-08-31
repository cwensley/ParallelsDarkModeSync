<#
.SYNOPSIS
    Removes the dark-mode sync agent from this Windows guest.

.DESCRIPTION
    Stops and unregisters the scheduled task, stops the launcher and agent, and
    deletes the installed files. The current Windows theme is left exactly as it is.
#>

[CmdletBinding()]
param(
    [string] $TaskName = 'DarkModeSync'
)

$ErrorActionPreference = 'Stop'

$me = [System.Security.Principal.WindowsIdentity]::GetCurrent()

if ($me.IsSystem) {
    $consoleUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
    if ($consoleUser) {
        $targetSid = (New-Object System.Security.Principal.NTAccount($consoleUser)).Translate(
            [System.Security.Principal.SecurityIdentifier]).Value
    }
} else {
    $targetSid = $me.User.Value
}

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Output "Removed scheduled task '$TaskName'."
} else {
    Write-Output "Scheduled task '$TaskName' was not registered."
}

# Kill the launcher and any agent process still running from a previous start.
Get-Process -Name 'DarkModeSyncLauncher' -ErrorAction SilentlyContinue | ForEach-Object {
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    Write-Output "Stopped launcher process $($_.Id)."
}

Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        ($_.Name -in 'powershell.exe', 'wscript.exe') -and $_.CommandLine -and
        ($_.CommandLine -like '*DarkModeSyncAgent.ps1*' -or $_.CommandLine -like '*DarkModeSyncLauncher.vbs*')
    } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Output "Stopped agent process $($_.ProcessId)."
    }

if ($targetSid) {
    $profileKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$targetSid"
    try {
        $profileDir = (Get-ItemProperty -LiteralPath $profileKey -Name ProfileImagePath).ProfileImagePath
        $installDir = Join-Path $profileDir 'AppData\Local\DarkModeSync'
        if (Test-Path -LiteralPath $installDir) {
            Remove-Item -LiteralPath $installDir -Recurse -Force
            Write-Output "Deleted $installDir."
        }
    } catch {
        Write-Warning "Could not remove the install directory: $($_.Exception.Message)"
    }
}

Write-Output 'Guest agent uninstalled. The current Windows theme was left unchanged.'
