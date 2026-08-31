<#
.SYNOPSIS
    Installs the dark-mode sync agent into this Windows guest.

.DESCRIPTION
    Copies DarkModeSyncAgent.ps1 into the target user's LOCALAPPDATA, builds a small
    windowless launcher next to it, and registers a scheduled task that starts the
    launcher at logon and keeps it running.

    The launcher matters: a task whose action is powershell.exe gets a console
    allocated for it, and on Windows 11 that console is handed off to Windows
    Terminal, which ignores -WindowStyle Hidden. The result is a blank terminal
    window that stops the sync when it is closed. The launcher is a GUI-subsystem
    process, so it starts PowerShell with no console at all.

    Works in two contexts:
      * Pushed from the Mac via 'prlctl exec' (running as SYSTEM). The interactive
        console user is detected automatically and the agent is installed for them.
      * Run by hand inside Windows. Installs for the user running it.

.PARAMETER SourceDir
    Directory holding DarkModeSyncAgent.ps1. Defaults to this script's own folder.
#>

[CmdletBinding()]
param(
    [string] $SourceDir,
    [string] $StatePath = '\\Mac\Home\.darkmode-sync\state',
    [double] $PollSeconds = 1.5,
    [string] $TaskName = 'DarkModeSync',
    [switch] $NoEnforce
)

$ErrorActionPreference = 'Stop'

if (-not $SourceDir) { $SourceDir = Split-Path -Parent $PSCommandPath }
$sourceAgent = Join-Path $SourceDir 'DarkModeSyncAgent.ps1'
if (-not (Test-Path -LiteralPath $sourceAgent)) {
    throw "Could not find DarkModeSyncAgent.ps1 in '$SourceDir'."
}
$sourceLauncher = Join-Path $SourceDir 'DarkModeSyncLauncher.cs'

# --- work out who we are installing for -------------------------------------

$me = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$runningAsSystem = $me.IsSystem

if ($runningAsSystem) {
    $consoleUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
    if (-not $consoleUser) {
        throw 'No interactive user is signed in to Windows. Sign in first, then re-run the install.'
    }
    $targetSid = (New-Object System.Security.Principal.NTAccount($consoleUser)).Translate(
        [System.Security.Principal.SecurityIdentifier]).Value
    $targetName = $consoleUser
} else {
    $targetSid = $me.User.Value
    $targetName = $me.Name
}

$profileKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$targetSid"
$profileDir = (Get-ItemProperty -LiteralPath $profileKey -Name ProfileImagePath).ProfileImagePath
$installDir   = Join-Path $profileDir 'AppData\Local\DarkModeSync'
$agentPath    = Join-Path $installDir 'DarkModeSyncAgent.ps1'
$launcherSrc  = Join-Path $installDir 'DarkModeSyncLauncher.cs'
$launcherExe  = Join-Path $installDir 'DarkModeSyncLauncher.exe'
$launcherVbs  = Join-Path $installDir 'DarkModeSyncLauncher.vbs'

Write-Output "Installing for $targetName ($targetSid)"
Write-Output "Install directory: $installDir"

if (-not (Test-Path -LiteralPath $installDir)) {
    New-Item -Path $installDir -ItemType Directory -Force | Out-Null
}
Copy-Item -LiteralPath $sourceAgent -Destination $agentPath -Force

# The agent's own arguments, passed through by whichever launcher we end up using.
$agentArgs = @('-StatePath', $StatePath, '-PollSeconds', $PollSeconds)
if ($NoEnforce) { $agentArgs += '-NoEnforce' }

# --- build the windowless launcher ------------------------------------------

function Format-Argument {
    param([string] $Value)
    if ($Value -match '[\s"]') { return '"' + ($Value -replace '"', '\"') + '"' }
    return $Value
}

$taskCommand = $null
$taskArgs    = $null

if (Test-Path -LiteralPath $sourceLauncher) {
    # A previous launcher may still be running and holding the file open.
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Get-Process -Name 'DarkModeSyncLauncher' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300

    try {
        # Compile from a local copy so the guest can rebuild without the Mac share.
        Copy-Item -LiteralPath $sourceLauncher -Destination $launcherSrc -Force
        Add-Type -Path $launcherSrc -OutputAssembly $launcherExe `
            -OutputType WindowsApplication -ErrorAction Stop
        $taskCommand = $launcherExe
        $taskArgs = (@($agentPath) + $agentArgs | ForEach-Object { Format-Argument $_ }) -join ' '
        Write-Output 'Built DarkModeSyncLauncher.exe (runs the agent with no console window).'
    } catch {
        Write-Warning "Could not build the launcher: $($_.Exception.Message)"
    }
}

if (-not $taskCommand) {
    # Fallback: a script-host shim. Also windowless, but it cannot supervise the
    # agent as thoroughly as the compiled launcher.
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
              ((@($agentPath) + $agentArgs | ForEach-Object { Format-Argument $_ }) -join ' ')
    $vbsCommand = (Format-Argument $psExe) + ' ' + $psArgs
    $vbsLiteral = '"' + ($vbsCommand -replace '"', '""') + '"'

    @"
' Windowless launcher for DarkModeSyncAgent.ps1 (fallback -- see Install-GuestAgent.ps1).
Set sh = CreateObject("WScript.Shell")
Do
    sh.Run $vbsLiteral, 0, True
    WScript.Sleep 5000
Loop
"@ | Set-Content -LiteralPath $launcherVbs -Encoding ASCII

    $taskCommand = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $taskArgs = '//B //Nologo ' + (Format-Argument $launcherVbs)
    Write-Output 'Using the wscript.exe fallback launcher.'
}

# Clear out any agent left over from an older install -- including the blank terminal
# window that a pre-launcher install leaves behind.
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        ($_.Name -in 'powershell.exe', 'wscript.exe') -and $_.CommandLine -and
        ($_.CommandLine -like '*DarkModeSyncAgent.ps1*' -or $_.CommandLine -like '*DarkModeSyncLauncher.vbs*')
    } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# --- register the logon task ------------------------------------------------

$escapedCommand = [System.Security.SecurityElement]::Escape($taskCommand)
$escapedArgs    = [System.Security.SecurityElement]::Escape($taskArgs)

$taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Mirrors the macOS host's light/dark appearance into Windows.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$targetSid</UserId>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$targetSid</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>3</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$escapedCommand</Command>
      <Arguments>$escapedArgs</Arguments>
    </Exec>
  </Actions>
</Task>
"@

Register-ScheduledTask -TaskName $TaskName -Xml $taskXml -Force | Out-Null
Write-Output "Registered scheduled task '$TaskName' (starts at logon, no window)."

# --- start it now -----------------------------------------------------------

try {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskName $TaskName
    Write-Output 'Agent started.'
} catch {
    Write-Warning "Could not start the agent now: $($_.Exception.Message)"
    Write-Warning 'It will start automatically at the next sign-in.'
}
