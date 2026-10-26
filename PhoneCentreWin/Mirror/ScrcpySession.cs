using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Text;
using PhoneCentre.Adb;
using PhoneCentre.Support;

namespace PhoneCentre.Mirror;

/// <summary>
/// 一個 scrcpy-server 連線：推送 server、建立 video / audio / control 三條 socket，把影像與音訊封包交給解碼端並轉送控制事件。
/// 解碼與播放不在這裡：<see cref="VideoConfig"/>／<see cref="VideoFrame"/>／<see cref="AudioPacket"/> 在背景執行緒呼叫，
/// 其餘事件會回到建立此物件的同步內容（UI 執行緒）。
/// </summary>
public sealed class ScrcpySession
{
    public const string ServerVersion = "3.3.4";
    public const string ServerRemotePath = "/data/local/tmp/phonecentre-scrcpy-server.jar";

    public enum StateKind { Idle, Starting, Running, Failed, Stopped }
    public readonly record struct SessionState(StateKind Kind, string? Message = null);

    public Device Device { get; }
    public MirrorConfig Config { get; }
    public string DeviceName { get; private set; } = "";
    public (int Width, int Height) FrameSize { get; private set; }
    public SessionState State { get; private set; } = new(StateKind.Idle);

    // 事件（State／FrameSize／DeviceClipboard 在 UI 執行緒；Video／Audio 在背景執行緒）
    public event Action<SessionState>? StateChanged;
    public event Action<int, int>? FrameSizeChanged;
    public event Action<string>? DeviceClipboard;
    /// <summary>SPS/PPS 等 config 封包（Annex B）</summary>
    public event Action<byte[]>? VideoConfig;
    /// <summary>一個影像封包（Annex B）、pts（微秒）、是否為關鍵幀</summary>
    public event Action<byte[], ulong, bool>? VideoFrame;
    /// <summary>raw PCM（48 kHz 雙聲道 s16le）</summary>
    public event Action<byte[]>? AudioPacket;

    private readonly SynchronizationContext? _ui = SynchronizationContext.Current;
    private AdbSocket? _shell, _video, _audio, _control;
    private readonly BlockingCollection<byte[]> _controlQueue = [];
    private volatile bool _stopped;
    private ulong _clipboardSeq = 1;
    private readonly StringBuilder _serverLog = new();

    public ScrcpySession(Device device, MirrorConfig config)
    {
        Device = device;
        Config = config;
    }

    private void Post(Action a)
    {
        if (_ui is null) a(); else _ui.Post(_ => a(), null);
    }

    private void SetState(SessionState s)
    {
        State = s;
        Post(() => StateChanged?.Invoke(s));
    }

    private string ServerLog() { lock (_serverLog) return _serverLog.ToString(); }

    // MARK: 啟動

    public void Start()
    {
        SetState(new(StateKind.Starting));
        new Thread(() =>
        {
            try { Run(); }
            catch (Exception e)
            {
                if (_stopped) return;
                var extra = string.Join("\n", ServerLog().Split('\n')
                    .Where(l => l.Contains("ERROR") || l.Contains("Exception")).Take(3));
                SetState(new(StateKind.Failed, e.Message + (extra.Length == 0 ? "" : "\n" + extra)));
            }
        }) { IsBackground = true, Name = "scrcpy-session" }.Start();
    }

    private void Run()
    {
        PushServerIfNeeded();

        var scid = Random.Shared.Next(1, 0x7fff_ffff).ToString("x8");
        var prefix = $"app_process / com.genymobile.scrcpy.Server {ServerVersion} scid={scid} tunnel_forward=true";
        var cmd = $"CLASSPATH={ServerRemotePath} " + LimitLength(prefix, ServerArgs());

        // 用 shell:（有 pty）啟動；在部分三星 Android 12 上用 exec: 會讓 server 原生崩潰。
        // 關閉這條連線時 server 會收到 SIGHUP 一起結束。
        var shell = AdbSocket.Open(Device.Endpoint, Device.Serial, "shell:" + cmd);
        _shell = shell;
        new Thread(() =>
        {
            try
            {
                while (true)
                {
                    var s = Encoding.UTF8.GetString(shell.ReadSome());
                    lock (_serverLog) _serverLog.Append(s);
                    System.Diagnostics.Debug.Write("[scrcpy-server] " + s);
                }
            }
            catch (AdbException) { }
        }) { IsBackground = true }.Start();

        // 依序連線 video → audio → control，第一條 socket 會先收到 1 byte dummy
        var socketName = $"localabstract:scrcpy_{scid}";
        AdbSocket? video = null;
        for (int i = 0; i < 100; i++)
        {
            if (_stopped) throw AdbException.Closed();
            try
            {
                var s = AdbSocket.Open(Device.Endpoint, Device.Serial, socketName, 2);
                s.SetTimeout(2);
                try { s.ReadExact(1); video = s; break; }
                catch { s.Close(); }
            }
            catch (AdbException) { }
            Thread.Sleep(100);
        }
        if (video is null)
        {
            var log = ServerLog();
            throw new AdbException("無法連線到 scrcpy-server\n" + (log.Length > 400 ? log[^400..] : log));
        }
        video.SetTimeout(0);
        _video = video;
        if (Config.Audio) _audio = AdbSocket.Open(Device.Endpoint, Device.Serial, socketName);
        var control = AdbSocket.Open(Device.Endpoint, Device.Serial, socketName);
        _control = control;

        // 裝置名稱（64 bytes）
        var nameData = video.ReadExact(64);
        DeviceName = Encoding.UTF8.GetString(nameData.TakeWhile(b => b != 0).ToArray());

        // 影像 codec meta：codec id、寬、高
        var meta = video.ReadExact(12);
        uint codec = BinaryPrimitives.ReadUInt32BigEndian(meta);
        if (codec == 0 || codec == 1) throw new AdbException("裝置無法擷取畫面");
        int w = (int)BinaryPrimitives.ReadUInt32BigEndian(meta.AsSpan(4));
        int h = (int)BinaryPrimitives.ReadUInt32BigEndian(meta.AsSpan(8));
        FrameSize = (w, h);
        Post(() => FrameSizeChanged?.Invoke(w, h));

        SetState(new(StateKind.Running));
        StartControlWriter(control);
        StartControlReader(control);
        if (_audio is { } a) StartAudio(a);

        if (Config.ScreenOff) Send(ControlMessage.SetDisplayPower(false));
        if (Config.StartApp is { } app) Send(ControlMessage.StartApp(app));

        // 影像封包迴圈
        while (!_stopped)
        {
            var header = video.ReadExact(12);
            ulong ptsFlags = BinaryPrimitives.ReadUInt64BigEndian(header);
            int size = (int)BinaryPrimitives.ReadUInt32BigEndian(header.AsSpan(8));
            var packet = video.ReadExact(size);
            if ((ptsFlags & (1UL << 63)) != 0) VideoConfig?.Invoke(packet);
            else VideoFrame?.Invoke(packet, ptsFlags & 0x3fff_ffff_ffff_ffffUL, (ptsFlags & (1UL << 62)) != 0);
        }
    }

    /// <summary>只送跟 scrcpy-server 預設值不同的參數，依重要性排序（越後面越先被捨棄）</summary>
    private List<string> ServerArgs()
    {
        var v = Config.Video;
        var args = new List<string>();
        if (Config.NewDisplay is { } nd)
        {
            args.Add($"new_display={nd}");
            if (!Config.SystemDecorations) args.Add("vd_system_decorations=false");
        }
        if (Config.Audio)
        {
            args.Add("audio_codec=raw");
            if (!Config.MuteDevice && Device.Info is { Sdk: >= 33 })
            {
                // Android 13+：擷取播放音訊，同時讓手機繼續發聲（預設 output 會讓手機靜音）
                args.Add("audio_source=playback");
                args.Add("audio_dup=true");
            }
        }
        else args.Add("audio=false");
        if (v.MaxSize > 0) args.Add($"max_size={v.MaxSize}");
        int bitRate = (int)(v.BitRateMbps * 1_000_000);
        if (bitRate != 8_000_000) args.Add($"video_bit_rate={bitRate}");
        if (v.MaxFps > 0) args.Add($"max_fps={v.MaxFps}");
        if (!Config.ClipboardSync) args.Add("clipboard_autosync=false");
        if (Config.NewDisplay is not null) args.Add("vd_destroy_content=false");
        return args;
    }

    /// <summary>
    /// 三星部分機型（例如 S10 / Android 12）的 libstagefright 在設定編碼器時會把程序 cmdline
    /// 讀進固定大小的緩衝區，app_process 的參數超過約 257 字元就會 stack corruption 崩潰，
    /// 所以把總長度壓在 240 以內，超過就從最後面開始捨棄參數。
    /// </summary>
    public static string LimitLength(string prefix, List<string> args, int max = 240)
    {
        args = [.. args];
        string line = string.Join(" ", args.Prepend(prefix));
        while (Encoding.UTF8.GetByteCount(line) > max && args.Count > 0)
        {
            args.RemoveAt(args.Count - 1);
            line = string.Join(" ", args.Prepend(prefix));
        }
        return line;
    }

    private void PushServerIfNeeded()
    {
        var (local, localSize) = Assets.Extract("scrcpy-server");
        string remote;
        using (var s = AdbSocket.Open(Device.Endpoint, Device.Serial, $"exec:stat -c %s {ServerRemotePath} 2>/dev/null"))
            remote = Encoding.UTF8.GetString(s.ReadToEnd()).Trim();
        long remoteSize = long.TryParse(remote, out var n) ? n : -2;
        if (remoteSize == localSize) return;
        Device.Client.PushAsync(local, ServerRemotePath).GetAwaiter().GetResult();
    }

    // MARK: 控制

    public void Send(byte[] message)
    {
        if (!_controlQueue.IsAddingCompleted) try { _controlQueue.Add(message); } catch (InvalidOperationException) { }
    }

    /// <summary>Mac → 手機剪貼簿；paste = true 時同時貼上</summary>
    public void SetClipboard(string text, bool paste) =>
        Send(ControlMessage.SetClipboard(++_clipboardSeq, paste, text));

    private void StartControlWriter(AdbSocket s) => new Thread(() =>
    {
        try { foreach (var msg in _controlQueue.GetConsumingEnumerable()) s.Write(msg); }
        catch (Exception) { }
    }) { IsBackground = true, Name = "scrcpy-control-writer" }.Start();

    private void StartControlReader(AdbSocket s) => new Thread(() =>
    {
        try
        {
            while (true)
            {
                byte type = s.ReadExact(1)[0];
                switch (type)
                {
                    case 0:   // 剪貼簿
                        int len = (int)BinaryPrimitives.ReadUInt32BigEndian(s.ReadExact(4));
                        var text = Encoding.UTF8.GetString(s.ReadExact(len));
                        Post(() => DeviceClipboard?.Invoke(text));
                        break;
                    case 1:   // ack clipboard
                        s.ReadExact(8);
                        break;
                    case 2:   // uhid output
                        var hd = s.ReadExact(4);
                        s.ReadExact((hd[2] << 8) | hd[3]);
                        break;
                    default:
                        return;
                }
            }
        }
        catch (Exception) { }
    }) { IsBackground = true, Name = "scrcpy-control-reader" }.Start();

    // MARK: 音訊

    private void StartAudio(AdbSocket s) => new Thread(() =>
    {
        try
        {
            uint codec = BinaryPrimitives.ReadUInt32BigEndian(s.ReadExact(4));
            if (codec == 0 || codec == 1) { System.Diagnostics.Debug.WriteLine("[PhoneCentre] 裝置不支援音訊轉送"); return; }
            while (true)
            {
                var header = s.ReadExact(12);
                int size = (int)BinaryPrimitives.ReadUInt32BigEndian(header.AsSpan(8));
                var packet = s.ReadExact(size);
                if ((BinaryPrimitives.ReadUInt64BigEndian(header) & (1UL << 63)) != 0) continue;
                AudioPacket?.Invoke(packet);
            }
        }
        catch (Exception) { }
    }) { IsBackground = true, Name = "scrcpy-audio" }.Start();

    // MARK: 停止

    public void Stop()
    {
        _stopped = true;
        if (Config.ScreenOff) Send(ControlMessage.SetDisplayPower(true));
        _controlQueue.CompleteAdding();
        // 讓控制執行緒把「恢復螢幕」送完再關 socket
        Task.Run(async () =>
        {
            await Task.Delay(Config.ScreenOff ? 150 : 0);
            _video?.Close(); _audio?.Close(); _control?.Close(); _shell?.Close();
        });
        SetState(new(StateKind.Stopped));
    }
}
