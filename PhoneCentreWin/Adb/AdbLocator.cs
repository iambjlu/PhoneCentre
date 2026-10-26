using System.Diagnostics;
using System.IO.Compression;
using PhoneCentre.Settings;
using PhoneCentre.Support;

namespace PhoneCentre.Adb;

/// <summary>尋找 adb.exe；找不到時可協助從 Google 官方下載 platform-tools</summary>
public static class AdbLocator
{
    private const string PlatformToolsUrl = "https://dl.google.com/android/repository/platform-tools-latest-windows.zip";
    private static readonly Dictionary<string, bool> RunnableCache = new();
    private static readonly object CacheLock = new();

    public static string ManagedAdb => Path.Combine(Assets.SupportDir, "platform-tools", "adb.exe");

    /// <summary>依序：自訂路徑 → PhoneCentre 下載的 → ANDROID_HOME → Android SDK → PATH</summary>
    public static string? Find()
    {
        var candidates = new List<string>();
        if (!string.IsNullOrEmpty(AppSettings.CustomAdbPath)) candidates.Add(AppSettings.CustomAdbPath);
        candidates.Add(ManagedAdb);
        foreach (var env in new[] { "ANDROID_HOME", "ANDROID_SDK_ROOT" })
            if (Environment.GetEnvironmentVariable(env) is { Length: > 0 } home)
                candidates.Add(Path.Combine(home, "platform-tools", "adb.exe"));
        candidates.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Android", "Sdk", "platform-tools", "adb.exe"));
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
            candidates.Add(Path.Combine(dir.Trim('"'), "adb.exe"));

        return candidates.FirstOrDefault(c => File.Exists(c) && IsRunnable(c));
    }

    /// <summary>這個 adb 能不能在這台電腦上執行（例如架構不符、檔案損毀就跳過，改用下載的新版）</summary>
    private static bool IsRunnable(string path)
    {
        lock (CacheLock) { if (RunnableCache.TryGetValue(path, out var c)) return c; }
        bool ok = false;
        try
        {
            var psi = new ProcessStartInfo(path, "version")
            {
                RedirectStandardOutput = true, RedirectStandardError = true,
                UseShellExecute = false, CreateNoWindow = true,
            };
            using var p = Process.Start(psi)!;
            if (p.WaitForExit(4000)) ok = p.ExitCode == 0; else { try { p.Kill(true); } catch { } }
        }
        catch { ok = false; }
        lock (CacheLock) RunnableCache[path] = ok;
        return ok;
    }

    /// <summary>下載並解壓 platform-tools，回傳 adb 路徑</summary>
    public static async Task<string> InstallAsync(Action<string> progress)
    {
        progress("正在從 Google 下載 Android SDK Platform-Tools…");
        using var http = new HttpClient();
        var tmp = Path.Combine(Path.GetTempPath(), $"platform-tools-{Guid.NewGuid():N}.zip");
        try
        {
            using (var resp = await http.GetAsync(PlatformToolsUrl, HttpCompletionOption.ResponseHeadersRead))
            {
                resp.EnsureSuccessStatusCode();
                await using var dst = File.Create(tmp);
                await resp.Content.CopyToAsync(dst);
            }
            progress("正在解壓縮…");
            var dest = Assets.SupportDir;
            var tools = Path.Combine(dest, "platform-tools");
            if (Directory.Exists(tools)) Directory.Delete(tools, true);
            ZipFile.ExtractToDirectory(tmp, dest);
            if (!File.Exists(ManagedAdb)) throw new IOException("解壓縮失敗：找不到 adb.exe");
            lock (CacheLock) RunnableCache.Remove(ManagedAdb);
            progress("安裝完成");
            return ManagedAdb;
        }
        finally { try { File.Delete(tmp); } catch { } }
    }
}
