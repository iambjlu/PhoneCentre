using System.Buffers.Binary;
using System.Text;

namespace PhoneCentre.Mirror;

/// <summary>scrcpy 控制協定（client → device），格式依 scrcpy-server 3.3.4 的 ControlMessageReader（big-endian）</summary>
public static class ControlMessage
{
    public enum KeyAction : byte { Down = 0, Up = 1 }
    public enum MotionAction : byte { Down = 0, Up = 1, Move = 2, Cancel = 3, HoverMove = 7 }

    public const ulong PointerMouse = ulong.MaxValue;        // -1
    public const ulong PointerFinger = ulong.MaxValue - 1;   // -2

    private sealed class Writer
    {
        private readonly List<byte> _b = [];
        public void U8(byte v) => _b.Add(v);
        public void U16(ushort v) { Span<byte> s = stackalloc byte[2]; BinaryPrimitives.WriteUInt16BigEndian(s, v); _b.AddRange(s.ToArray()); }
        public void U32(uint v) { Span<byte> s = stackalloc byte[4]; BinaryPrimitives.WriteUInt32BigEndian(s, v); _b.AddRange(s.ToArray()); }
        public void I32(int v) => U32(unchecked((uint)v));
        public void U64(ulong v) { Span<byte> s = stackalloc byte[8]; BinaryPrimitives.WriteUInt64BigEndian(s, v); _b.AddRange(s.ToArray()); }
        public void Str(string str, int lenBytes = 4, int max = 300_000)
        {
            var bytes = Encoding.UTF8.GetBytes(str);
            if (bytes.Length > max) bytes = bytes[..max];
            if (lenBytes == 1) { if (bytes.Length > 255) bytes = bytes[..255]; U8((byte)bytes.Length); }
            else U32((uint)bytes.Length);
            _b.AddRange(bytes);
        }
        public byte[] ToArray() => [.. _b];
    }

    // 浮點轉定點：u16 對應 [0,1]，i16 對應 [-1,1]
    private static ushort U16Fp(float f) => f >= 1 ? (ushort)0xffff : (ushort)(Math.Max(0, f) * 65_536);
    private static ushort I16Fp(float f)
    {
        float c = Math.Clamp(f, -1, 1);
        short v = c >= 1 ? short.MaxValue : (short)(c * 32_768);
        return unchecked((ushort)v);
    }

    public static byte[] Keycode(KeyAction action, int keycode, int repeat = 0, int meta = 0)
    {
        var w = new Writer(); w.U8(0); w.U8((byte)action); w.I32(keycode); w.I32(repeat); w.I32(meta); return w.ToArray();
    }

    public static byte[] Text(string s)
    {
        var w = new Writer(); w.U8(1); w.Str(s, max: 300); return w.ToArray();
    }

    public static byte[] Touch(MotionAction action, ulong pointer, int x, int y, ushort width, ushort height,
        float pressure, int actionButton = 0, int buttons = 0)
    {
        var w = new Writer();
        w.U8(2); w.U8((byte)action); w.U64(pointer); w.I32(x); w.I32(y); w.U16(width); w.U16(height);
        w.U16(U16Fp(pressure)); w.I32(actionButton); w.I32(buttons);
        return w.ToArray();
    }

    public static byte[] Scroll(int x, int y, ushort width, ushort height, float h, float v, int buttons = 0)
    {
        // server 端會把 [-1,1] 乘回 16
        var w = new Writer();
        w.U8(3); w.I32(x); w.I32(y); w.U16(width); w.U16(height); w.U16(I16Fp(h / 16)); w.U16(I16Fp(v / 16)); w.I32(buttons);
        return w.ToArray();
    }

    public static byte[] BackOrScreenOn(KeyAction a) => [4, (byte)a];
    public static byte[] ExpandNotifications() => [5];
    public static byte[] ExpandSettings() => [6];
    public static byte[] CollapsePanels() => [7];
    /// <summary>copyKey：0 none、1 copy、2 cut</summary>
    public static byte[] GetClipboard(byte copyKey) => [8, copyKey];

    public static byte[] SetClipboard(ulong sequence, bool paste, string text)
    {
        var w = new Writer(); w.U8(9); w.U64(sequence); w.U8(paste ? (byte)1 : (byte)0); w.Str(text); return w.ToArray();
    }

    public static byte[] SetDisplayPower(bool on) => [10, on ? (byte)1 : (byte)0];
    public static byte[] RotateDevice() => [11];

    public static byte[] StartApp(string name)
    {
        var w = new Writer(); w.U8(16); w.Str(name, lenBytes: 1); return w.ToArray();
    }

    public static byte[] ResetVideo() => [17];
}
