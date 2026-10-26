using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using PhoneCentre.Adb;
using PhoneCentre.Mirror;
using PhoneCentre.Support;
using Windows.Graphics;
using Windows.Media.Playback;

namespace PhoneCentre;

/// <summary>暫時的主視窗：啟動後連第一台在線裝置並鏡像（正式 UI 之後再做）</summary>
public sealed partial class MainWindow : Window
{
    private ScrcpySession? _session;
    private H264Feeder? _feeder;
    private (int W, int H) _frame;

    public MainWindow()
    {
        InitializeComponent();
        Title = "PhoneCentre";
        SystemBackdrop = new MicaBackdrop();
        AppWindow.Resize(new SizeInt32(520, 1000));

        Surface.PointerPressed += (s, e) => OnPointer(e, ControlMessage.MotionAction.Down);
        Surface.PointerMoved += (s, e) => { if (_pressed) OnPointer(e, ControlMessage.MotionAction.Move); };
        Surface.PointerReleased += (s, e) => OnPointer(e, ControlMessage.MotionAction.Up);
        Closed += (s, e) => _session?.Stop();

        _ = StartAsync();
    }

    private async Task StartAsync()
    {
        try
        {
            Status.Text = "正在尋找裝置…";
            var device = await FindDeviceAsync();
            if (device is null) { Status.Text = "找不到已連線的裝置"; return; }
            Log.Write($"裝置 {device.Serial} ({device.Model})");
            device.Info = await DeviceInfo.FetchAsync(device.Client);

            var config = new MirrorConfig { Audio = false };
            _session = new ScrcpySession(device, config);
            _session.StateChanged += st =>
            {
                Log.Write($"狀態 {st.Kind} {st.Message}");
                Status.Text = st.Kind == ScrcpySession.StateKind.Running ? "" : $"{st.Kind} {st.Message}";
            };
            _session.FrameSizeChanged += (w, h) =>
            {
                Log.Write($"畫面大小 {w}x{h}");
                if (_feeder is null) AttachPlayer(w, h);
                _frame = (w, h);
            };
            _session.VideoConfig += p => _feeder?.Config(p);
            _session.VideoFrame += (p, pts, key) => _feeder?.Frame(p, pts, key);
            _session.Start();
        }
        catch (Exception e)
        {
            Log.Write("錯誤 " + e);
            Status.Text = e.Message;
        }
    }

    private void AttachPlayer(int w, int h)
    {
        _feeder = new H264Feeder(w, h);
        var player = new MediaPlayer { RealTimePlayback = true, AutoPlay = true };
        player.Source = Windows.Media.Core.MediaSource.CreateFromMediaStreamSource(_feeder.Source);
        player.MediaFailed += (s, e) => Log.Write($"播放失敗 {e.Error} {e.ErrorMessage} {e.ExtendedErrorCode}");
        player.MediaOpened += (s, e) => Log.Write("播放開始");
        Player.SetMediaPlayer(player);
    }

    private static async Task<Device?> FindDeviceAsync()
    {
        for (int attempt = 0; attempt < 2; attempt++)
        {
            try
            {
                var text = await Task.Run(() => AdbSocket.HostQuery(AdbEndpoint.Local, "host:devices-l"));
                var dev = Device.Parse(text, AdbEndpoint.Local).FirstOrDefault(d => d.IsOnline);
                if (dev is not null) return dev;
                return null;
            }
            catch (AdbException) when (attempt == 0)
            {
                await AdbClient.StartServerAsync();
            }
        }
        return null;
    }

    // MARK: 輸入（滑鼠左鍵＝觸控、右鍵＝返回、中鍵＝主畫面）

    private bool _pressed;

    private void OnPointer(PointerRoutedEventArgs e, ControlMessage.MotionAction action)
    {
        if (_session is null || _frame.W == 0) return;
        var pt = e.GetCurrentPoint(Surface);
        var props = pt.Properties;

        if (action == ControlMessage.MotionAction.Down)
        {
            if (props.IsRightButtonPressed)
            {
                _session.Send(ControlMessage.BackOrScreenOn(ControlMessage.KeyAction.Down));
                _session.Send(ControlMessage.BackOrScreenOn(ControlMessage.KeyAction.Up));
                return;
            }
            if (props.IsMiddleButtonPressed)
            {
                _session.Send(ControlMessage.Keycode(ControlMessage.KeyAction.Down, 3));
                _session.Send(ControlMessage.Keycode(ControlMessage.KeyAction.Up, 3));
                return;
            }
            if (!props.IsLeftButtonPressed) return;
            _pressed = true;
            Surface.CapturePointer(e.Pointer);
        }
        else if (!_pressed) return;

        if (action == ControlMessage.MotionAction.Up) { _pressed = false; Surface.ReleasePointerCapture(e.Pointer); }

        // 視窗座標 → 手機畫面座標（Uniform 置中縮放）
        double W = Surface.ActualWidth, H = Surface.ActualHeight;
        double scale = Math.Min(W / _frame.W, H / _frame.H);
        double ox = (W - _frame.W * scale) / 2, oy = (H - _frame.H * scale) / 2;
        int x = (int)Math.Clamp((pt.Position.X - ox) / scale, 0, _frame.W - 1);
        int y = (int)Math.Clamp((pt.Position.Y - oy) / scale, 0, _frame.H - 1);

        _session.Send(ControlMessage.Touch(action, ControlMessage.PointerFinger, x, y,
            (ushort)_frame.W, (ushort)_frame.H, action == ControlMessage.MotionAction.Up ? 0f : 1f,
            0, action == ControlMessage.MotionAction.Up ? 0 : 1));
    }
}
