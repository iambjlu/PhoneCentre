namespace PhoneCentre.Support;

/// <summary>簡易記錄檔（%LOCALAPPDATA%\PhoneCentre\log.txt），除錯用</summary>
public static class Log
{
    private static readonly object Gate = new();
    private static string Path => System.IO.Path.Combine(Assets.SupportDir, "log.txt");

    public static void Write(string message)
    {
        var line = $"{DateTime.Now:HH:mm:ss.fff} {message}";
        System.Diagnostics.Debug.WriteLine(line);
        try { lock (Gate) File.AppendAllText(Path, line + Environment.NewLine); } catch { }
    }
}
