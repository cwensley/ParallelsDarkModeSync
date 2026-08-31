// DarkModeSyncLauncher.exe -- windowless host for DarkModeSyncAgent.ps1.
//
// Compiled inside the guest at install time (see Install-GuestAgent.ps1) and used as
// the scheduled task's action instead of powershell.exe.
//
// Why this exists: powershell.exe is a console application, so Task Scheduler
// allocates a console for it. On Windows 11 that console is handed off to Windows
// Terminal, which ignores -WindowStyle Hidden -- leaving a blank terminal window that
// stops the sync when it is closed. Starting PowerShell from a GUI-subsystem process
// with CreateNoWindow means no console is ever allocated, so there is no window and
// nothing to close.
//
// It also supervises the agent: if PowerShell exits for any reason the agent is
// restarted (with backoff if it is dying immediately), and the agent is assigned to a
// job object so it cannot outlive the launcher when the task is stopped.
//
// Kept to C# 5 -- it is built by the .NET Framework compiler that ships with Windows.

using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

internal static class Launcher
{
    // Per-session, so one launcher per signed-in user.
    private const string MutexName = @"Local\DarkModeSyncLauncher";

    private const int MaxLogBytes = 64 * 1024;

    private static string _logFile;
    private static readonly object _logLock = new object();

    private static int Main(string[] args)
    {
        if (args.Length < 1)
        {
            return 2; // usage: DarkModeSyncLauncher.exe <agent.ps1> [agent args...]
        }

        string agentPath = args[0];
        string installDir = Path.GetDirectoryName(Path.GetFullPath(agentPath));
        _logFile = Path.Combine(installDir, "launcher.log");

        bool isFirst;
        using (new Mutex(true, MutexName, out isFirst))
        {
            if (!isFirst)
            {
                Log("another launcher is already running in this session; exiting");
                return 0;
            }

            return Supervise(agentPath, args, installDir);
        }
    }

    private static int Supervise(string agentPath, string[] args, string workingDir)
    {
        string powershell = Path.Combine(
            Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
        string arguments = BuildArguments(agentPath, args);

        Log("launcher starting: " + arguments);

        using (JobHandle job = new JobHandle())
        {
            double backoffSeconds = 5;

            while (true)
            {
                DateTime started = DateTime.UtcNow;
                int exitCode;

                try
                {
                    exitCode = RunOnce(powershell, arguments, workingDir, job);
                }
                catch (Exception ex)
                {
                    Log("could not start the agent: " + ex.Message);
                    exitCode = -1;
                }

                double ranSeconds = (DateTime.UtcNow - started).TotalSeconds;
                Log(string.Format(
                    "agent exited with {0} after {1:0}s; restarting in {2:0}s",
                    exitCode, ranSeconds, backoffSeconds));

                Thread.Sleep(TimeSpan.FromSeconds(backoffSeconds));

                // Back off only while it keeps dying straight away.
                backoffSeconds = ranSeconds < 30 ? Math.Min(backoffSeconds * 2, 300) : 5;
            }
        }
    }

    private static int RunOnce(string exe, string arguments, string workingDir, JobHandle job)
    {
        ProcessStartInfo psi = new ProcessStartInfo(exe, arguments)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
            WorkingDirectory = workingDir,
        };

        using (Process p = Process.Start(psi))
        {
            // Ties the agent's lifetime to ours: if the task is stopped and we are
            // terminated, closing the job handle kills the agent too.
            job.Assign(p);
            p.WaitForExit();
            return p.ExitCode;
        }
    }

    private static string BuildArguments(string agentPath, string[] args)
    {
        StringBuilder sb = new StringBuilder();
        sb.Append("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ");
        sb.Append(Quote(agentPath));

        for (int i = 1; i < args.Length; i++)
        {
            sb.Append(' ');
            sb.Append(Quote(args[i]));
        }

        return sb.ToString();
    }

    private static string Quote(string value)
    {
        if (value.Length > 0 && value.IndexOfAny(new[] { ' ', '\t', '"' }) < 0)
        {
            return value;
        }
        return '"' + value.Replace("\"", "\\\"") + '"';
    }

    private static void Log(string message)
    {
        string line = DateTime.Now.ToString("yyyy-MM-ddTHH:mm:ss") + " " + message;
        try
        {
            lock (_logLock)
            {
                FileInfo info = new FileInfo(_logFile);
                if (info.Exists && info.Length > MaxLogBytes)
                {
                    File.Delete(_logFile);
                }
                File.AppendAllText(_logFile, line + Environment.NewLine, Encoding.UTF8);
            }
        }
        catch
        {
            // Logging must never take the launcher down.
        }
    }

    // --- job object -------------------------------------------------------------

    private sealed class JobHandle : IDisposable
    {
        private IntPtr _handle;

        public JobHandle()
        {
            _handle = CreateJobObject(IntPtr.Zero, null);
            if (_handle == IntPtr.Zero)
            {
                return; // supervision still works; we just lose kill-on-close
            }

            JOBOBJECT_EXTENDED_LIMIT_INFORMATION info =
                new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;

            int size = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(info, buffer, false);
                SetInformationJobObject(
                    _handle, JobObjectExtendedLimitInformation, buffer, (uint)size);
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        public void Assign(Process p)
        {
            if (_handle != IntPtr.Zero)
            {
                AssignProcessToJobObject(_handle, p.Handle);
            }
        }

        public void Dispose()
        {
            if (_handle != IntPtr.Zero)
            {
                CloseHandle(_handle);
                _handle = IntPtr.Zero;
            }
        }
    }

    private const int JobObjectExtendedLimitInformation = 9;
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr securityAttributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(
        IntPtr job, int infoClass, IntPtr info, uint infoLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);
}
