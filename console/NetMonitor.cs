// Per-process network accounting for the multilink console, from the
// Microsoft-Windows-Kernel-Network ETW provider (what Resource Monitor uses).
// Compiled by Add-Type under Windows PowerShell 5.1: keep it C# 5.
using System;
using System.Collections.Generic;
using System.Net;
using System.Runtime.InteropServices;
using System.Threading;

namespace Multilink
{
    public sealed class NetRow
    {
        public int Pid;
        public string LocalIp;
        public string Proto;   // TCP, UDP or QUIC (UDP to/from port 443)
        public long Rx;
        public long Tx;
        public int Conns;      // distinct remote endpoints in the window
    }

    // Sums traffic per (process, local address, protocol). Each event carries
    // two addresses; whichever one is one of our own link addresses is the
    // local side, so the result doesn't depend on the provider's field naming.
    public sealed class NetAggregator
    {
        private sealed class Acc
        {
            public long Rx, Tx;
            public HashSet<string> Remotes = new HashSet<string>();
        }

        private readonly object gate = new object();
        private HashSet<string> locals = new HashSet<string>();
        private Dictionary<string, Acc> accs = new Dictionary<string, Acc>();
        private Dictionary<string, NetRow> keys = new Dictionary<string, NetRow>();

        public void SetLocalAddresses(string[] ips)
        {
            HashSet<string> set = new HashSet<string>();
            foreach (string ip in ips) { IPAddress a; if (IPAddress.TryParse(ip, out a)) set.Add(a.ToString()); }
            lock (gate) { locals = set; }
        }

        public void Add(int pid, bool send, int size, string addrA, int portA, string addrB, int portB, bool udp)
        {
            string local, remote; int remotePort;
            lock (gate)
            {
                if (locals.Contains(addrA)) { local = addrA; remote = addrB; remotePort = portB; }
                else if (locals.Contains(addrB)) { local = addrB; remote = addrA; remotePort = portA; }
                else return;
                string proto = udp ? (remotePort == 443 ? "QUIC" : "UDP") : "TCP";
                string key = pid + "|" + local + "|" + proto;
                Acc acc;
                if (!accs.TryGetValue(key, out acc))
                {
                    acc = new Acc();
                    accs[key] = acc;
                    NetRow row = new NetRow();
                    row.Pid = pid; row.LocalIp = local; row.Proto = proto;
                    keys[key] = row;
                }
                if (send) acc.Tx += size; else acc.Rx += size;
                acc.Remotes.Add(remote + ":" + remotePort);
            }
        }

        public NetRow[] Drain()
        {
            lock (gate)
            {
                List<NetRow> rows = new List<NetRow>();
                foreach (KeyValuePair<string, Acc> kv in accs)
                {
                    NetRow r = keys[kv.Key];
                    r.Rx = kv.Value.Rx; r.Tx = kv.Value.Tx; r.Conns = kv.Value.Remotes.Count;
                    rows.Add(r);
                }
                accs = new Dictionary<string, Acc>();
                keys = new Dictionary<string, NetRow>();
                return rows.ToArray();
            }
        }
    }

    // Real-time ETW session on Microsoft-Windows-Kernel-Network. Needs admin.
    public sealed class NetMonitor : IDisposable
    {
        public const string SessionName = "MultilinkNetMon";
        private static Guid Provider = new Guid("7DD42A49-5329-4832-8DFD-43D979153A88");
        private const ulong KeywordIPv4 = 0x10, KeywordIPv6 = 0x20;

        public readonly NetAggregator Aggregator = new NetAggregator();
        private ulong session, trace;
        private Thread worker;
        private EventRecordCallback callback;   // kept alive while ProcessTrace runs

        // --- native ---------------------------------------------------------------
        [StructLayout(LayoutKind.Sequential)]
        private struct WnodeHeader
        {
            public uint BufferSize, ProviderId;
            public ulong HistoricalContext;
            public long TimeStamp;
            public Guid Guid;
            public uint ClientContext, Flags;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct TraceProperties
        {
            public WnodeHeader Wnode;
            public uint BufferSize, MinimumBuffers, MaximumBuffers, MaximumFileSize, LogFileMode, FlushTimer, EnableFlags;
            public int AgeLimit;
            public uint NumberOfBuffers, FreeBuffers, EventsLost, BuffersWritten, LogBuffersLost, RealTimeBuffersLost;
            public IntPtr LoggerThreadId;
            public uint LogFileNameOffset, LoggerNameOffset;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct EventTraceHeader
        {
            public ushort Size, FieldTypeFlags;
            public uint Version, ThreadId, ProcessId;
            public long TimeStamp;
            public Guid Guid;
            public uint KernelTime, UserTime;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct EventTrace
        {
            public EventTraceHeader Header;
            public uint InstanceId, ParentInstanceId;
            public Guid ParentGuid;
            public IntPtr MofData;
            public uint MofLength, ClientContext;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SystemTime { public ushort Year, Month, DayOfWeek, Day, Hour, Minute, Second, Milliseconds; }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct TimeZoneInformation
        {
            public int Bias;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string StandardName;
            public SystemTime StandardDate;
            public int StandardBias;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DaylightName;
            public SystemTime DaylightDate;
            public int DaylightBias;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct TraceLogfileHeader
        {
            public uint BufferSize, Version, ProviderVersion, NumberOfProcessors;
            public long EndTime;
            public uint TimerResolution, MaximumFileSize, LogFileMode, BuffersWritten;
            public Guid LogInstanceGuid;
            public IntPtr LoggerName, LogFileName;
            public TimeZoneInformation TimeZone;
            public long BootTime, PerfFreq, StartTime;
            public uint ReservedFlags, BuffersLost;
        }

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate void EventRecordCallback(IntPtr eventRecord);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct EventTraceLogfile
        {
            [MarshalAs(UnmanagedType.LPWStr)] public string LogFileName;
            [MarshalAs(UnmanagedType.LPWStr)] public string LoggerName;
            public long CurrentTime;
            public uint BuffersRead, ProcessTraceMode;
            public EventTrace CurrentEvent;
            public TraceLogfileHeader LogfileHeader;
            public IntPtr BufferCallback;
            public uint BufferSize, Filled, EventsLost;
            public EventRecordCallback EventRecordCallback;
            public uint IsKernelTrace;
            public IntPtr Context;
        }

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
        private static extern uint StartTrace(out ulong handle, string name, IntPtr properties);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
        private static extern uint ControlTrace(ulong handle, string name, IntPtr properties, uint controlCode);
        [DllImport("advapi32.dll")]
        private static extern uint EnableTraceEx2(ulong handle, ref Guid provider, uint controlCode, byte level,
                                                  ulong matchAny, ulong matchAll, uint timeout, IntPtr parameters);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
        private static extern ulong OpenTrace(ref EventTraceLogfile logfile);
        [DllImport("advapi32.dll")]
        private static extern uint ProcessTrace(ulong[] handles, uint count, IntPtr start, IntPtr end);
        [DllImport("advapi32.dll")]
        private static extern uint CloseTrace(ulong handle);

        private const uint WnodeFlagTracedGuid = 0x00020000;
        private const uint RealTimeMode = 0x00000100;
        private const uint ControlStop = 1;
        private const uint EnableProvider = 1;
        private const uint ErrorAlreadyExists = 183;
        private const uint ModeRealTime = 0x00000100, ModeEventRecord = 0x10000000;
        private const int NameBytes = 1024;

        private static IntPtr NewProperties()
        {
            int size = Marshal.SizeOf(typeof(TraceProperties)) + NameBytes * 2;
            IntPtr buf = Marshal.AllocHGlobal(size);
            for (int i = 0; i < size; i++) Marshal.WriteByte(buf, i, 0);
            TraceProperties p = new TraceProperties();
            p.Wnode.BufferSize = (uint)size;
            p.Wnode.Flags = WnodeFlagTracedGuid;
            p.Wnode.ClientContext = 1;   // QPC timestamps
            p.LogFileMode = RealTimeMode;
            p.FlushTimer = 1;
            p.LoggerNameOffset = (uint)Marshal.SizeOf(typeof(TraceProperties));
            p.LogFileNameOffset = p.LoggerNameOffset + NameBytes;
            Marshal.StructureToPtr(p, buf, false);
            return buf;
        }

        // Sessions are kernel objects and survive a crashed console.
        public static void StopStale()
        {
            IntPtr props = NewProperties();
            try { ControlTrace(0, SessionName, props, ControlStop); }
            finally { Marshal.FreeHGlobal(props); }
        }

        public void Start()
        {
            IntPtr props = NewProperties();
            try
            {
                uint rc = StartTrace(out session, SessionName, props);
                if (rc == ErrorAlreadyExists)
                {
                    StopStale();
                    Marshal.FreeHGlobal(props);
                    props = NewProperties();
                    rc = StartTrace(out session, SessionName, props);
                }
                if (rc != 0) throw new InvalidOperationException("StartTrace failed with error " + rc);
            }
            finally { Marshal.FreeHGlobal(props); }

            uint en = EnableTraceEx2(session, ref Provider, EnableProvider, 5, KeywordIPv4 | KeywordIPv6, 0, 0, IntPtr.Zero);
            if (en != 0) { StopStale(); throw new InvalidOperationException("EnableTraceEx2 failed with error " + en); }

            callback = new EventRecordCallback(OnEvent);
            EventTraceLogfile log = new EventTraceLogfile();
            log.LoggerName = SessionName;
            log.ProcessTraceMode = ModeRealTime | ModeEventRecord;
            log.EventRecordCallback = callback;
            trace = OpenTrace(ref log);
            if (trace == ulong.MaxValue || trace == 0xFFFFFFFF) { StopStale(); throw new InvalidOperationException("OpenTrace failed"); }

            ulong[] handles = new ulong[] { trace };
            worker = new Thread(delegate () { ProcessTrace(handles, 1, IntPtr.Zero, IntPtr.Zero); });
            worker.IsBackground = true;
            worker.Start();
        }

        // EVENT_RECORD: EventDescriptor.Id at 40, UserDataLength at 86,
        // UserData pointer after ExtendedData (88 + pointer size).
        private void OnEvent(IntPtr rec)
        {
            try
            {
                int id = Marshal.ReadInt16(rec, 40) & 0xFFFF;
                bool v4, udp, send;
                switch (id)
                {
                    case 10: v4 = true; udp = false; send = true; break;
                    case 11: v4 = true; udp = false; send = false; break;
                    case 26: v4 = false; udp = false; send = true; break;
                    case 27: v4 = false; udp = false; send = false; break;
                    case 42: v4 = true; udp = true; send = true; break;
                    case 43: v4 = true; udp = true; send = false; break;
                    case 58: v4 = false; udp = true; send = true; break;
                    case 59: v4 = false; udp = true; send = false; break;
                    default: return;
                }
                int len = Marshal.ReadInt16(rec, 86) & 0xFFFF;
                IntPtr data = Marshal.ReadIntPtr(rec, 88 + IntPtr.Size);
                int addrLen = v4 ? 4 : 16;
                if (data == IntPtr.Zero || len < 8 + addrLen * 2 + 4) return;
                // Payload: PID u32, size u32, daddr, saddr, dport u16, sport u16 (ports big-endian).
                int pid = Marshal.ReadInt32(data, 0);
                int size = Marshal.ReadInt32(data, 4);
                byte[] a = new byte[addrLen], b = new byte[addrLen];
                Marshal.Copy(IntPtr.Add(data, 8), a, 0, addrLen);
                Marshal.Copy(IntPtr.Add(data, 8 + addrLen), b, 0, addrLen);
                int off = 8 + addrLen * 2;
                int portA = (Marshal.ReadByte(data, off) << 8) | Marshal.ReadByte(data, off + 1);
                int portB = (Marshal.ReadByte(data, off + 2) << 8) | Marshal.ReadByte(data, off + 3);
                Aggregator.Add(pid, send, size, new IPAddress(a).ToString(), portA, new IPAddress(b).ToString(), portB, udp);
            }
            catch { }   // never throw into ETW's thread
        }

        public void Dispose()
        {
            StopStale();
            if (trace != 0) { CloseTrace(trace); trace = 0; }
        }
    }
}
