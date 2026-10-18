// Native helpers for the multilink console. Compiled at runtime by Add-Type
// under Windows PowerShell 5.1, so this must stay C# 5.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

namespace Multilink
{
    // Per-interface byte counters straight from iphlpapi. Get-NetAdapterStatistics
    // takes seconds per call on some machines, far too slow for a 1 s sampler.
    public static class IfStats
    {
        // MIB_IF_ROW2 (x64 and x86 share this layout): 1352 bytes,
        // InterfaceIndex at 8, InOctets at 1208, OutOctets at 1280.
        private const int RowSize = 1352;
        private const int IndexOffset = 8;
        private const int InOctetsOffset = 1208;
        private const int OutOctetsOffset = 1280;

        [DllImport("iphlpapi.dll")]
        private static extern int GetIfEntry2(IntPtr row);

        // Returns { received, sent } bytes, or null if the interface is gone.
        public static long[] Get(uint interfaceIndex)
        {
            IntPtr row = Marshal.AllocHGlobal(RowSize);
            try
            {
                for (int i = 0; i < RowSize; i++) Marshal.WriteByte(row, i, 0);
                Marshal.WriteInt32(row, IndexOffset, (int)interfaceIndex);
                if (GetIfEntry2(row) != 0) return null;
                return new long[] { Marshal.ReadInt64(row, InOctetsOffset), Marshal.ReadInt64(row, OutOctetsOffset) };
            }
            finally { Marshal.FreeHGlobal(row); }
        }
    }

    // Polls each tracked interface on its own thread. A USB-tethered phone's
    // RNDIS driver can take ~2 s to answer a stats query; on its own thread it
    // only slows its own readings, not every link's.
    public sealed class IfPoller : IDisposable
    {
        private sealed class Slot
        {
            public long Rx, Tx;
            public double At = -1;
            public volatile bool Stop;
        }

        private readonly Dictionary<uint, Slot> slots = new Dictionary<uint, Slot>();

        // Same clock as the readings' timestamps.
        public static double Now() { return (double)Stopwatch.GetTimestamp() / Stopwatch.Frequency; }

        public void Track(uint index)
        {
            Slot slot;
            lock (slots)
            {
                if (slots.ContainsKey(index)) return;
                slot = new Slot();
                slots[index] = slot;
            }
            Thread t = new Thread(delegate ()
            {
                while (!slot.Stop)
                {
                    long[] v = IfStats.Get(index);
                    if (v != null)
                    {
                        double now = (double)Stopwatch.GetTimestamp() / Stopwatch.Frequency;
                        lock (slot) { slot.Rx = v[0]; slot.Tx = v[1]; slot.At = now; }
                    }
                    Thread.Sleep(250);
                }
            });
            t.IsBackground = true;
            t.Start();
        }

        public void Untrack(uint index)
        {
            lock (slots)
            {
                Slot slot;
                if (slots.TryGetValue(index, out slot)) { slot.Stop = true; slots.Remove(index); }
            }
        }

        public uint[] Tracked()
        {
            lock (slots) { return new List<uint>(slots.Keys).ToArray(); }
        }

        // { rxBytes, txBytes, atSeconds } of the latest reading, or null.
        public double[] Read(uint index)
        {
            Slot slot;
            lock (slots) { if (!slots.TryGetValue(index, out slot)) return null; }
            lock (slot)
            {
                if (slot.At < 0) return null;
                return new double[] { slot.Rx, slot.Tx, slot.At };
            }
        }

        public void Dispose()
        {
            lock (slots)
            {
                foreach (Slot s in slots.Values) s.Stop = true;
                slots.Clear();
            }
        }
    }

    // A Job Object that kills every assigned process when its last handle
    // closes - including when the console is killed with the window's X.
    public static class JobObject
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct BasicLimit
        {
            public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass, SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IoCounters
        {
            public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ExtendedLimit
        {
            public BasicLimit Basic;
            public IoCounters Io;
            public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }

        private const int ExtendedLimitInformation = 9;
        private const uint KillOnJobClose = 0x2000;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll")]
        private static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimit info, int length);
        [DllImport("kernel32.dll")]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        public static IntPtr CreateKillOnClose()
        {
            IntPtr job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) return IntPtr.Zero;
            ExtendedLimit info = new ExtendedLimit();
            info.Basic.LimitFlags = KillOnJobClose;
            SetInformationJobObject(job, ExtendedLimitInformation, ref info, Marshal.SizeOf(typeof(ExtendedLimit)));
            return job;
        }

        public static bool Assign(IntPtr job, IntPtr process)
        {
            return AssignProcessToJobObject(job, process);
        }

        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);

        // Closing the last handle kills every process still in the job.
        public static bool Close(IntPtr job)
        {
            return CloseHandle(job);
        }
    }

    // Console close (X button, logoff, shutdown) arrives on a thread with no
    // PowerShell runspace, so the handler only raises a flag. The console's
    // request loop sees it within 250 ms, cleans up, and calls Done(); the
    // handler waits for that (Windows allows ~5 s) before letting the process die.
    public static class ConsoleClose
    {
        private delegate bool HandlerRoutine(int ctrlType);
        [DllImport("kernel32.dll")]
        private static extern bool SetConsoleCtrlHandler(HandlerRoutine handler, bool add);

        private static HandlerRoutine handler;   // kept alive so the GC can't collect it
        private static readonly ManualResetEvent done = new ManualResetEvent(false);
        private static volatile bool requested;

        public static bool Requested { get { return requested; } }

        public static void Register()
        {
            if (handler != null) return;
            handler = delegate (int ctrlType)
            {
                requested = true;
                done.WaitOne(4500);
                return false;
            };
            SetConsoleCtrlHandler(handler, true);
        }

        public static void Done() { done.Set(); }
    }

    public static class CommandLine
    {
        [DllImport("shell32.dll", SetLastError = true)]
        private static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string cmdLine, out int argc);
        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr mem);

        public static string[] Split(string cmdLine)
        {
            int argc;
            IntPtr argv = CommandLineToArgvW(cmdLine, out argc);
            try
            {
                string[] result = new string[argc];
                for (int i = 0; i < argc; i++) result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size));
                return result;
            }
            finally { LocalFree(argv); }
        }
    }
}
