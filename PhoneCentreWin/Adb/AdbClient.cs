using System.Text;
using PhoneCentre.Support;

namespace PhoneCentre.Adb;

/// <summary>adb 操作：短指令走 socket（快、不用開程序），檔案傳輸與 server 管理走 adb CLI</summary>
public readonly record struct AdbClient(AdbEndpoint Endpoint, string Serial)
{
    public static string? AdbPath => AdbLocator.Find();

    // MARK: Shell

    /// <summary>在裝置上執行指令並取回輸出（exec: 服務，無 pty，二進位安全）</summary>
    public Task<byte[]> ExecAsync(string command, double timeout = 15)
    {
        var (ep, serial) = (Endpoint, Serial);
        return Task.Run(() =>
        {
            using var s = AdbSocket.Open(ep, serial, $"exec:{command}");
            s.SetTimeout(timeout);
            return s.ReadToEnd();
        });
    }

    public async Task<string> ShellAsync(string command, double timeout = 15) =>
        Encoding.UTF8.GetString(await ExecAsync(command, timeout));

    public async Task<string> GetPropAsync(string key)
    {
        try { return (await ShellAsync($"getprop {key}")).Trim(); } catch { return ""; }
    }

    // MARK: CLI

    private IEnumerable<string> BaseArgs()
    {
        if (Endpoint != AdbEndpoint.Local) { yield return "-H"; yield return Endpoint.Host; yield return "-P"; yield return Endpoint.Port.ToString(); }
        yield return "-s"; yield return Serial;
    }

    public async Task<ShellResult> CliAsync(IEnumerable<string> args, double? timeout = null)
    {
        var adb = AdbPath ?? throw new AdbException("找不到 adb");
        return await Shell.RunAsync(adb, BaseArgs().Concat(args), timeout);
    }

    public async Task PushAsync(string localPath, string remote)
    {
        var r = await CliAsync(["push", localPath, remote]);
        if (r.Status != 0) throw new AdbException(r.Stderr.Length == 0 ? r.Text : r.Stderr);
        // 讓媒體庫看到新檔案
        try { await ShellAsync($"am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d {Shell.Quote("file://" + remote)} >/dev/null 2>&1"); } catch { }
    }

    public async Task PullAsync(string remote, string localPath)
    {
        var r = await CliAsync(["pull", "-a", remote, localPath]);
        if (r.Status != 0) throw new AdbException(r.Stderr.Length == 0 ? r.Text : r.Stderr);
    }

    public async Task InstallAsync(string apkPath)
    {
        var r = await CliAsync(["install", "-r", "-d", apkPath]);
        if (r.Status != 0 || r.Text.Contains("Failure"))
            throw new AdbException((r.Text + r.Stderr).Trim());
    }

    // MARK: Server 層級

    public static async Task<ShellResult> ServerCliAsync(AdbEndpoint endpoint, IEnumerable<string> args, double timeout = 15)
    {
        var adb = AdbPath ?? throw new AdbException("找不到 adb");
        var a = new List<string>();
        if (endpoint != AdbEndpoint.Local) a.AddRange(["-H", endpoint.Host, "-P", endpoint.Port.ToString()]);
        a.AddRange(args);
        return await Shell.RunAsync(adb, a, timeout);
    }

    public static async Task StartServerAsync()
    {
        try { await ServerCliAsync(AdbEndpoint.Local, ["start-server"], 15); } catch { }
    }

    /// <summary>adb connect；回傳 adb 的訊息</summary>
    public static async Task<(bool Ok, string Message)> ConnectAsync(string address, AdbEndpoint? endpoint = null)
    {
        var ep = endpoint ?? AdbEndpoint.Local;
        string msg;
        try { msg = await Task.Run(() => AdbSocket.HostQuery(ep, $"host:connect:{address}")); }
        catch (Exception e) { return (false, e.Message); }
        return (msg.Contains("connected to") && !msg.Contains("failed") && !msg.Contains("unable"), msg);
    }

    public static async Task DisconnectAsync(string address, AdbEndpoint? endpoint = null)
    {
        var ep = endpoint ?? AdbEndpoint.Local;
        try { await Task.Run(() => AdbSocket.HostQuery(ep, $"host:disconnect:{address}")); } catch { }
    }

    public static async Task<(bool Ok, string Message)> PairAsync(string address, string code)
    {
        try
        {
            var r = await ServerCliAsync(AdbEndpoint.Local, ["pair", address, code], 30);
            var msg = (r.Text + r.Stderr).Trim();
            return (msg.Contains("Successfully paired"), msg);
        }
        catch (Exception e) { return (false, e.Message); }
    }

    /// <summary>adb mdns services → (instance, type, address)</summary>
    public static async Task<List<(string Instance, string Type, string Address)>> MdnsServicesAsync()
    {
        var result = new List<(string, string, string)>();
        try
        {
            var r = await ServerCliAsync(AdbEndpoint.Local, ["mdns", "services"], 5);
            foreach (var line in r.Text.Split('\n'))
            {
                var parts = line.Split(['\t', ' '], StringSplitOptions.RemoveEmptyEntries);
                if (parts.Length >= 3 && parts[1].StartsWith("_adb")) result.Add((parts[0], parts[1], parts[2]));
            }
        }
        catch { }
        return result;
    }
}
