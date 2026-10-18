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
}
