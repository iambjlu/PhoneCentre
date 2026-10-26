using System.Reflection;
using System.Runtime.InteropServices;
using PhoneCentre.Support;

namespace PhoneCentre.Mirror;

/// <summary>
/// 精簡版 FFmpeg（只含 H.264 解碼器與 swscale，LGPL，見 scripts/build-ffmpeg.sh）的 P/Invoke。
/// DLL 內嵌在 exe（依平台 x64／ARM64），第一次使用時解到 %LOCALAPPDATA%\PhoneCentre\assets 再載入。
/// 只用函式，不用 AutoGen：AVFrame／AVPacket 只讀取開頭那段（公開 ABI，跨版本不變）的欄位。
/// </summary>
internal static unsafe class FFmpegNative
{
    private const string AvCodec = "avcodec", AvUtil = "avutil", SwScale = "swscale";
    private static readonly object Gate = new();
    private static bool _ready;

    public static void EnsureLoaded()
    {
        lock (Gate)
        {
            if (_ready) return;
            var libs = new Dictionary<string, IntPtr>();
            // 依相依順序載入：avutil → swscale／avcodec
            foreach (var prefix in new[] { "avutil-", "swscale-", "avcodec-" })
            {
                var res = Assembly.GetExecutingAssembly().GetManifestResourceNames()
                    .FirstOrDefault(n => n.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) && n.EndsWith(".dll", StringComparison.OrdinalIgnoreCase))
                    ?? throw new DllNotFoundException($"App 內缺少 FFmpeg 的 {prefix}*.dll");
                var (path, _) = Assets.Extract(res);
                libs[prefix.TrimEnd('-')] = NativeLibrary.Load(path);
            }
            NativeLibrary.SetDllImportResolver(typeof(FFmpegNative).Assembly, (name, _, _) =>
                libs.TryGetValue(name, out var h) ? h : IntPtr.Zero);
            _ready = true;
        }
    }

    public const int AV_CODEC_ID_H264 = 27;
    public const int AV_PIX_FMT_YUV420P = 0, AV_PIX_FMT_BGRA = 28;
    public const int SWS_BILINEAR = 2;
    public const int AVERROR_EAGAIN = -11;     // -EAGAIN（mingw 的 errno）

    // AVFrame 開頭：data[8]@0、linesize[8]@64、extended_data@96、width@104、height@108、nb_samples@112、format@116
    public static byte** FrameData(IntPtr f) => (byte**)f;
    public static int* FrameLinesize(IntPtr f) => (int*)((byte*)f + 64);
    public static int FrameWidth(IntPtr f) => *(int*)((byte*)f + 104);
    public static int FrameHeight(IntPtr f) => *(int*)((byte*)f + 108);
    public static int FrameFormat(IntPtr f) => *(int*)((byte*)f + 116);
    // AVPacket 開頭：buf@0、pts@8、dts@16、data@24、size@32
    public static byte* PacketData(IntPtr p) => *(byte**)((byte*)p + 24);

    [DllImport(AvCodec)] public static extern IntPtr avcodec_find_decoder(int id);
    [DllImport(AvCodec)] public static extern IntPtr avcodec_alloc_context3(IntPtr codec);
    [DllImport(AvCodec)] public static extern int avcodec_open2(IntPtr ctx, IntPtr codec, IntPtr options);
    [DllImport(AvCodec)] public static extern void avcodec_free_context(ref IntPtr ctx);
    [DllImport(AvCodec)] public static extern IntPtr av_packet_alloc();
    [DllImport(AvCodec)] public static extern void av_packet_free(ref IntPtr pkt);
    [DllImport(AvCodec)] public static extern int av_new_packet(IntPtr pkt, int size);
    [DllImport(AvCodec)] public static extern void av_packet_unref(IntPtr pkt);
    [DllImport(AvCodec)] public static extern int avcodec_send_packet(IntPtr ctx, IntPtr pkt);
    [DllImport(AvCodec)] public static extern int avcodec_receive_frame(IntPtr ctx, IntPtr frame);

    [DllImport(AvUtil)] public static extern IntPtr av_frame_alloc();
    [DllImport(AvUtil)] public static extern void av_frame_free(ref IntPtr frame);
    [DllImport(AvUtil)] public static extern int av_opt_set(IntPtr obj, [MarshalAs(UnmanagedType.LPStr)] string name, [MarshalAs(UnmanagedType.LPStr)] string val, int flags);
    [DllImport(AvUtil)] public static extern int av_opt_set_int(IntPtr obj, [MarshalAs(UnmanagedType.LPStr)] string name, long val, int flags);
    [DllImport(AvUtil)] public static extern int av_strerror(int err, byte* buf, nuint size);

    [DllImport(SwScale)] public static extern IntPtr sws_getCachedContext(IntPtr ctx, int srcW, int srcH, int srcFmt,
        int dstW, int dstH, int dstFmt, int flags, IntPtr srcFilter, IntPtr dstFilter, IntPtr param);
    [DllImport(SwScale)] public static extern int sws_scale(IntPtr ctx, byte** srcSlice, int* srcStride, int srcSliceY, int srcSliceH,
        byte** dst, int* dstStride);
    [DllImport(SwScale)] public static extern void sws_freeContext(IntPtr ctx);

    public static string Error(int err)
    {
        byte* buf = stackalloc byte[256];
        av_strerror(err, buf, 256);
        return $"{Marshal.PtrToStringAnsi((IntPtr)buf)} ({err})";
    }
}
