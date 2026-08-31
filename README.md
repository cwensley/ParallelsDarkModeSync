# ParallelsDarkModeSync

Switch appearance on macOS and your Parallels Windows VMs follow, within a couple of
seconds, without signing out of Windows.

The sync is **one-way by design**: the Mac is authoritative. Changing the theme inside
Windows gets snapped back on the next poll (see [Letting Windows hold an
override](#letting-windows-hold-an-override) if you'd rather it didn't).

## Install

```bash
./install.sh
```

That builds and loads the host watcher, then installs the agent into every Windows VM
that is currently **running**. Use `./install.sh --host-only` to skip the guest step.

For a VM that was off at install time, start it and run:

```bash
dmsync install-guest "Windows 11"
```

`install.sh` links `dmsync` into `/usr/local/bin` when that directory is writable.
Otherwise call it as `~/.darkmode-sync/bin/dmsync`, or link it yourself:

```bash
sudo ln -sf ~/.darkmode-sync/bin/dmsync /usr/local/bin/dmsync
```

## How it works

```
macOS appearance change
        │
        │  AppleInterfaceThemeChangedNotification
        ▼
  darkmode-watcher            (launchd agent, com.mcneel.darkmodesync)
        │
        │  writes "dark" / "light"
        ▼
  ~/.darkmode-sync/state
        │
        │  read over the Parallels shared folder as
        │  \\Mac\Home\.darkmode-sync\state
        ▼
  DarkModeSyncLauncher.exe    (scheduled task, runs at logon in your Windows session)
        │
        │  starts the agent with no console, and restarts it if it dies
        ▼
  DarkModeSyncAgent.ps1
        │
        │  sets AppsUseLightTheme + SystemUsesLightTheme, then
        │  broadcasts WM_SETTINGCHANGE / ImmersiveColorSet
        ▼
  Windows re-themes live
```

**Host.** A small Swift binary listens for `AppleInterfaceThemeChangedNotification`, so it
reacts immediately rather than polling, and costs essentially nothing while idle. It
re-checks every 10 seconds as a safety net, and writes the state file atomically via
`rename(2)` so a guest never reads a half-written file. If `swiftc` is unavailable the
installer falls back to an equivalent shell poller.

**Guest.** The agent must run **in your interactive Windows session**, because the theme
lives in `HKCU`. (`prlctl exec` runs as `NT AUTHORITY\SYSTEM`, whose `HKCU` is a different
hive entirely — pushing registry writes from the Mac would change nothing you can see. That
also rules out a Windows service, which would have the same problem.) So the installer
registers a scheduled task with a logon trigger and an interactive-token principal, and
starts it immediately. It polls the state file every 1.5 s and only touches the registry
when something actually differs.

The task runs `DarkModeSyncLauncher.exe` rather than `powershell.exe` directly, and that
matters: a task whose action is a console program gets a console allocated for it, and on
Windows 11 that console is handed off to Windows Terminal — which ignores
`-WindowStyle Hidden`. You end up with a blank terminal window that kills the sync when you
close it. The launcher is a GUI-subsystem program, so it starts PowerShell with
`CreateNoWindow` and no console is ever created. It also restarts the agent if it exits,
and holds it in a job object so the agent cannot outlive the task.

The launcher is a few dozen lines of C# ([`guest/DarkModeSyncLauncher.cs`](guest/DarkModeSyncLauncher.cs)),
compiled inside the guest at install time by the .NET Framework compiler that ships with
Windows — so there is no prebuilt binary to trust and nothing extra to install. If that
compile fails for any reason, the installer falls back to an equivalent `wscript.exe` shim,
which is also windowless.

Because the guest agent converges on the host state whenever it reads it, a VM that was
suspended or powered off while you toggled catches up on its own once it is running again.

## Commands

```bash
dmsync status                    # host appearance, watcher health, per-VM agent state
dmsync vms                       # list Windows VMs
dmsync install-guest [vm...]     # install the agent (default: all running Windows VMs)
dmsync uninstall-guest [vm...]   # remove the agent
dmsync resync [vm...]            # restart the guest agent so it re-applies now
dmsync logs [host|vm...]         # host watcher log, or a guest agent log
```

VMs may be named or given by UUID.

```
$ dmsync status
Host (macOS)
  appearance now : dark
  published state: dark  (/Users/curtis/.darkmode-sync/state)
  watcher        : running

Windows VMs
  Windows 11 Fresh         stopped    agent unknown (VM not running)
  Windows 11 2026          running    agent running
  Windows 11               suspended  agent unknown (VM not running)
```

## What gets installed

| Where | Path |
| --- | --- |
| macOS | `~/.darkmode-sync/` — watcher binary, `dmsync`, guest scripts, `state`, `watcher.log` |
| macOS | `~/Library/LaunchAgents/com.mcneel.darkmodesync.plist` |
| Windows | `%LOCALAPPDATA%\DarkModeSync\` — agent script, launcher, `agent.log`, `launcher.log` |
| Windows | Scheduled task `DarkModeSync` |

Nothing needs administrator rights inside Windows; the task runs at your own privilege
level.

## Tuning

### Letting Windows hold an override

By default the agent corrects any theme change made inside Windows. To let a manual change
stick until the Mac next toggles, reinstall the guest agent with `-NoEnforce`:

```bash
prlctl exec "Windows 11 2026" powershell.exe -NoProfile -ExecutionPolicy Bypass \
  -File '\\Mac\Home\.darkmode-sync\guest\Install-GuestAgent.ps1' -NoEnforce
```

### Poll interval

Same idea, with `-PollSeconds 3`. The host side stays event-driven either way; this only
controls how quickly the guest notices.

## Troubleshooting

**Windows isn't following.** Run `dmsync status`, then `dmsync logs <vm>`.

**`cannot read host state ... retrying` in the guest log.** The guest can't see
`\\Mac\Home`. In Parallels: *Configure → Options → Sharing → Share Mac* with "Share folders
with Windows" set to at least your home folder. Confirm from inside Windows with
`dir \\Mac\Home`.

**`agent NOT installed`.** The VM wasn't running when you installed. Start it and run
`dmsync install-guest "<vm>"`.

**A blank terminal window is open in Windows.** That is a pre-launcher agent. Re-run
`dmsync install-guest "<vm>"` (or `./install.sh`); it closes the old window and replaces it
with the windowless launcher.

**Agent stopped after a Windows update or reboot.** The logon trigger should restart it.
`dmsync resync "<vm>"` restarts it immediately. There is no window to close, so the only
ways to stop it are the scheduled task and `dmsync uninstall-guest`.

**Some apps didn't re-theme.** Explorer, the taskbar, Start, Settings and most modern apps
honour the `WM_SETTINGCHANGE` broadcast. A few — notably older Win32 apps and some Office
versions — only read the theme at startup and need a restart. This is a Windows
limitation, not something the agent can work around.

## Uninstall

```bash
./uninstall.sh
```

Removes the guest agent from running VMs and everything on the host. Appearance settings on
both sides are left exactly as they are. `./uninstall.sh --host-only` skips the guest step.

For a VM that was off at uninstall time, start it and run
`dmsync uninstall-guest "<vm>"` before removing the host side.
