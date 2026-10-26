using System.Reflection;

namespace PhoneCentre.Support;

/// <summary>內嵌在 exe 的資源（scrcpy-server、手機端輔助程式）。adb push 需要實體檔案，所以解到本機資料夾。</summary>
public static class Assets
{
    public static string SupportDir
    {
        get
        {
            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PhoneCentre");
            Directory.CreateDirectory(dir);
            return dir;
        }
    }

    /// <summary>把內嵌資源解到 SupportDir\assets（大小相同就沿用），回傳實體路徑與大小</summary>
    public static (string Path, long Size) Extract(string resourceName)
    {
        var asm = Assembly.GetExecutingAssembly();
        using var src = asm.GetManifestResourceStream(resourceName)
            ?? throw new FileNotFoundException($"App 內缺少 {resourceName}");
        var dir = Path.Combine(SupportDir, "assets");
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, resourceName);
        long size = src.Length;
        if (!File.Exists(path) || new FileInfo(path).Length != size)
        {
            using var dst = File.Create(path);
            src.CopyTo(dst);
        }
        return (path, size);
    }
}
