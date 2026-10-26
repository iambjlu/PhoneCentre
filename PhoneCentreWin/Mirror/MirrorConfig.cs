namespace PhoneCentre.Mirror;

/// <summary>畫質選項。MaxSize／MaxFps 為 0 代表不限制</summary>
public sealed class VideoOptions
{
    public int MaxFps { get; set; } = 60;
    public double BitRateMbps { get; set; } = 8;
    public int MaxSize { get; set; } = 1920;
}

/// <summary>鏡像工作階段的參數</summary>
public sealed class MirrorConfig
{
    public VideoOptions Video { get; set; } = new();
    public bool Audio { get; set; } = true;
    public bool MuteDevice { get; set; } = true;
    public bool ClipboardSync { get; set; } = true;
    public bool ScreenOff { get; set; }
    /// <summary>非 null 時在新的虛擬顯示器上執行，格式 "WxH/dpi"</summary>
    public string? NewDisplay { get; set; }
    public bool SystemDecorations { get; set; }
    /// <summary>連線後要啟動的 App（套件名稱）</summary>
    public string? StartApp { get; set; }
}
