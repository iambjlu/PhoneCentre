using System.Diagnostics;
using System.Text;

namespace PhoneCentre.Support;

public sealed record ShellResult(int Status, byte[] Stdout, string Stderr)
{
    public string Text => Encoding.UTF8.GetString(Stdout);
}

/// <summary>非同步執行外部程式（邊跑邊讀 stdout/stderr，避免 pipe 塞滿）</summary>
public static class Shell
{
    public static async Task<ShellResult> RunAsync(string exe, IEnumerable<string> args, double? timeout = null)
    {
        var psi = new ProcessStartInfo(exe)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);

        using var p = Process.Start(psi) ?? throw new InvalidOperationException($"無法啟動 {exe}");
        p.StandardInput.Close();
        using var cts = new CancellationTokenSource();
        if (timeout is double t) cts.CancelAfter(TimeSpan.FromSeconds(t));
        using var reg = cts.Token.Register(() => { try { p.Kill(true); } catch { } });

        var outTask = ReadAllAsync(p.StandardOutput.BaseStream);
        var errTask = ReadAllAsync(p.StandardError.BaseStream);
        await p.WaitForExitAsync();
        var stdout = await outTask;
        var stderr = Encoding.UTF8.GetString(await errTask);
        return new ShellResult(p.ExitCode, stdout, stderr);
    }

    private static async Task<byte[]> ReadAllAsync(Stream s)
    {
        using var ms = new MemoryStream();
        await s.CopyToAsync(ms);
        return ms.ToArray();
    }

    /// <summary>單引號跳脫，給 adb shell 使用</summary>
    public static string Quote(string s) => "'" + s.Replace("'", "'\\''") + "'";
}
