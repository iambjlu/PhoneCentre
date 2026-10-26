using PhoneCentre.Support;

namespace PhoneCentre.Adb;

/// <summary>在手機端執行 phonecentre-helper.jar（App 清單、圖示、相片縮圖）</summary>
public sealed class HelperTool
{
    public static HelperTool Shared { get; } = new();
    public const string RemotePath = "/data/local/tmp/phonecentre-helper.jar";
    private readonly HashSet<string> _pushed = [];
    private readonly SemaphoreSlim _gate = new(1, 1);

    private async Task EnsureAsync(Device device)
    {
        if (_pushed.Contains(device.Id)) return;
        var (path, localSize) = Assets.Extract("phonecentre-helper.jar");
        var remote = (await device.Client.ShellAsync($"stat -c %s {RemotePath} 2>/dev/null")).Trim();
        long remoteSize = long.TryParse(remote, out var n) ? n : -2;
        if (localSize != remoteSize) await device.Client.PushAsync(path, RemotePath);
        _pushed.Add(device.Id);
    }

    public async Task<string> RunAsync(Device device, IEnumerable<string> args, double timeout = 60)
    {
        await _gate.WaitAsync();
        try { await EnsureAsync(device); }
        finally { _gate.Release(); }
        var argStr = string.Join(" ", args.Select(Shell.Quote));
        return await device.Client.ShellAsync(
            $"CLASSPATH={RemotePath} app_process / com.phonecentre.helper.Main {argStr} 2>/dev/null", timeout);
    }
}
