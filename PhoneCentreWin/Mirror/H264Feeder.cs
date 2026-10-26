using System.Collections.Concurrent;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Media.Core;
using Windows.Media.MediaProperties;

namespace PhoneCentre.Mirror;

/// <summary>
/// 把 scrcpy 的 H.264 Annex B 封包餵給系統的 <see cref="MediaStreamSource"/>（由 Windows 的 H.264 解碼器，通常是硬體解碼）。
/// 建立與 <see cref="Source"/> 的使用都在 UI 執行緒；<see cref="Config"/>／<see cref="Frame"/> 可從任何執行緒呼叫。
/// </summary>
public sealed class H264Feeder
{
    public MediaStreamSource Source { get; }

    private readonly ConcurrentQueue<MediaStreamSample> _queue = new();
    private readonly object _gate = new();
    private MediaStreamSourceSampleRequest? _pending;
    private MediaStreamSourceSampleRequestedEventArgs? _pendingArgs;
    private MediaStreamSourceSampleRequestDeferral? _deferral;
    private byte[] _config = [];
    private long _firstPts = -1;
    private bool _gotKey;
    private const int MaxQueued = 4;   // 超過就丟舊的，維持低延遲

    public H264Feeder(int width, int height)
    {
        var props = VideoEncodingProperties.CreateH264();
        props.Width = (uint)width;
        props.Height = (uint)height;
        Source = new MediaStreamSource(new VideoStreamDescriptor(props))
        {
            BufferTime = TimeSpan.Zero,
            CanSeek = false,
        };
        Source.SampleRequested += OnSampleRequested;
    }

    public void Config(byte[] packet) => _config = packet;

    public void Frame(byte[] packet, ulong ptsMicros, bool key)
    {
        if (!_gotKey && !key) return;           // 必須從關鍵幀開始
        _gotKey = true;
        if (_firstPts < 0) _firstPts = (long)ptsMicros;

        byte[] data = packet;
        if (key && _config.Length > 0)          // 關鍵幀前面補 SPS/PPS，解碼器才能獨立解碼
        {
            data = new byte[_config.Length + packet.Length];
            _config.CopyTo(data, 0);
            packet.CopyTo(data, _config.Length);
        }
        var sample = MediaStreamSample.CreateFromBuffer(data.AsBuffer(), TimeSpan.FromTicks(((long)ptsMicros - _firstPts) * 10));

        lock (_gate)
        {
            if (_deferral is not null)
            {
                _pending!.Sample = sample;
                var d = _deferral;
                _deferral = null; _pending = null; _pendingArgs = null;
                d.Complete();
                return;
            }
            _queue.Enqueue(sample);
            while (_queue.Count > MaxQueued) _queue.TryDequeue(out _);
        }
    }

    private void OnSampleRequested(MediaStreamSource sender, MediaStreamSourceSampleRequestedEventArgs args)
    {
        lock (_gate)
        {
            if (_queue.TryDequeue(out var sample)) { args.Request.Sample = sample; return; }
            _pending = args.Request;
            _pendingArgs = args;
            _deferral = args.Request.GetDeferral();
        }
    }
}
