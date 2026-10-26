namespace PhoneCentre.Adb;

/// <summary>adb 回報的一台裝置</summary>
public sealed class Device
{
    public string Serial { get; set; } = "";
    public string State { get; set; } = "";
    public string Model { get; set; } = "";
    public string Product { get; set; } = "";
    public string TransportId { get; set; } = "";
    public AdbEndpoint Endpoint { get; set; } = AdbEndpoint.Local;
    public DeviceInfo? Info { get; set; }

    /// <summary>本機：serial；遠端：&lt;remoteID&gt;|serial</summary>
    public string Id => MakeId(Serial, Endpoint);

    public static string MakeId(string serial, AdbEndpoint endpoint) =>
        endpoint.RemoteId is Guid g ? $"{g}|{serial}" : serial;

    public bool IsOnline => State == "device";
    public bool IsWireless => Serial.Contains(':') || Serial.Contains("._adb-tls-connect");
    public bool IsRemote => !Endpoint.IsLocal;
    public AdbClient Client => new(Endpoint, Serial);

    public string DisplayName
    {
        get
        {
            if (!string.IsNullOrEmpty(Info?.DeviceName)) return Info!.DeviceName;
            if (Model.Length > 0) return Model.Replace('_', ' ');
            return Serial;
        }
    }

    /// <summary>廠牌與型號（側邊欄第二行）</summary>
    public string ModelLine =>
        !string.IsNullOrEmpty(Info?.Manufacturer) ? Info!.Manufacturer.ToUpperInvariant() + " " + Info.Model : Model.Replace('_', ' ');

    public string Subtitle
    {
        get
        {
            var parts = new List<string>();
            if (!string.IsNullOrEmpty(Info?.Manufacturer)) parts.Add(ModelLine);
            else if (Model.Length > 0) parts.Add(Model);
            if (Info is not null) parts.Add($"Android {Info.AndroidVersion}");
            return string.Join(" · ", parts);
        }
    }

    public string StateDescription => State switch
    {
        "device" => "已連線",
        "offline" => "離線",
        "unauthorized" => "未授權（請在手機上允許 USB 偵錯）",
        "authorizing" => "授權中",
        _ => State,
    };

    /// <summary>解析 host:devices-l</summary>
    public static List<Device> Parse(string text, AdbEndpoint endpoint)
    {
        var list = new List<Device>();
        foreach (var line in text.Split('\n'))
        {
            var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 2) continue;
            var d = new Device { Serial = parts[0], State = parts[1], Endpoint = endpoint };
            foreach (var p in parts.Skip(2))
            {
                int i = p.IndexOf(':');
                if (i < 0) continue;
                var (k, v) = (p[..i], p[(i + 1)..]);
                switch (k)
                {
                    case "model": d.Model = v; break;
                    case "product": d.Product = v; break;
                    case "transport_id": d.TransportId = v; break;
                }
            }
            list.Add(d);
        }
        return list;
    }
}

/// <summary>連線後一次性抓取的裝置資訊</summary>
public sealed record DeviceInfo(string DeviceName, string Manufacturer, string Model, string AndroidVersion,
    int Sdk, string SerialNo, string ScreenSize, int Density)
{
    /// <summary>
    /// 每個欄位都加上名稱再解析，並丟掉錯誤訊息（例如手機剛開機、settings 服務還沒起來時會印
    /// 「cmd: Can't find service: settings」），關鍵欄位不合理就回傳 null，讓呼叫端稍後重試，不要把壞資料存起來
    /// </summary>
    public static async Task<DeviceInfo?> FetchAsync(AdbClient c)
    {
        const string script =
            "echo \"name=$(settings get global device_name 2>/dev/null)\"; echo \"mfr=$(getprop ro.product.manufacturer)\"; " +
            "echo \"model=$(getprop ro.product.model)\"; echo \"ver=$(getprop ro.build.version.release)\"; " +
            "echo \"sdk=$(getprop ro.build.version.sdk)\"; echo \"sn=$(getprop ro.serialno)\"; " +
            "echo \"size=$(wm size 2>/dev/null | tail -1)\"; echo \"dpi=$(wm density 2>/dev/null | tail -1)\"";
        string output;
        try { output = await c.ShellAsync(script); } catch { return null; }

        var kv = new Dictionary<string, string>();
        foreach (var line in output.Split('\n'))
        {
            int eq = line.IndexOf('=');
            if (eq < 0) continue;
            kv[line[..eq].Trim()] = line[(eq + 1)..].Trim();
        }
        if (!int.TryParse(kv.GetValueOrDefault("sdk"), out int sdk) || sdk <= 0) return null;
        var model = kv.GetValueOrDefault("model");
        var ver = kv.GetValueOrDefault("ver");
        if (string.IsNullOrEmpty(model) || string.IsNullOrEmpty(ver)) return null;

        var name = kv.GetValueOrDefault("name") ?? "";
        if (name == "null" || name.Contains("Can't find service") || name.StartsWith("cmd:")) name = "";
        var size = AfterColon(kv.GetValueOrDefault("size") ?? "");
        int density = int.TryParse(AfterColon(kv.GetValueOrDefault("dpi") ?? ""), out int dpi) ? dpi : 420;
        return new DeviceInfo(name, kv.GetValueOrDefault("mfr") ?? "", model, ver, sdk,
            kv.GetValueOrDefault("sn") ?? "", size.Contains('x') ? size : "", density);
    }

    /// <summary>「Physical size: 1080x2280」→「1080x2280」</summary>
    private static string AfterColon(string s) => (s.Split(':').LastOrDefault() ?? s).Trim();
}
