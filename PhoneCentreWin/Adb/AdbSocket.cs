using System.Net;
using System.Net.Sockets;
using System.Text;

namespace PhoneCentre.Adb;

/// <summary>adb server 的位置。本機為 127.0.0.1:5037；遠端 PhoneCentre 透過加密通道映射到本機的另一個 port。</summary>
public readonly record struct AdbEndpoint(string Host = "127.0.0.1", int Port = 5037, Guid? RemoteId = null)
{
    // 不能用 new()：record struct 的 new() 會得到全零的 default，不套用主建構函式的預設值
    public static AdbEndpoint Local { get; } = new("127.0.0.1", 5037, null);
    public bool IsLocal => RemoteId is null;
}

public sealed class AdbException : Exception
{
    public AdbException(string message) : base(message) { }
    public static AdbException ConnectFailed(string s) => new($"無法連線到 adb server：{s}");
    public static AdbException Protocol(string s) => new($"adb 協定錯誤：{s}");
    public static AdbException Closed() => new("連線已關閉");
}

/// <summary>直接走 adb server 協定的 socket（阻塞式，請在背景執行緒使用）</summary>
public sealed class AdbSocket : IDisposable
{
    private Socket? _socket;
    private readonly object _lock = new();

    public AdbSocket(AdbEndpoint endpoint, double timeout = 5)
    {
        IPAddress[] addrs;
        if (IPAddress.TryParse(endpoint.Host, out var literal)) addrs = [literal];
        else
        {
            try { addrs = Dns.GetHostAddresses(endpoint.Host); }
            catch (Exception e) { throw AdbException.ConnectFailed($"無法解析 {endpoint.Host}（{e.Message}）"); }
        }

        string last = "socket()";
        foreach (var addr in addrs)
        {
            var s = new Socket(addr.AddressFamily, SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
            try
            {
                var connect = s.ConnectAsync(new IPEndPoint(addr, endpoint.Port));
                if (!connect.Wait(timeout > 0 ? TimeSpan.FromSeconds(timeout) : Timeout.InfiniteTimeSpan))
                    throw new TimeoutException("連線逾時");
                _socket = s;
                SetTimeout(timeout);
                return;
            }
            catch (Exception e)
            {
                last = (e is AggregateException ae ? ae.GetBaseException() : e).Message;
                s.Dispose();
            }
        }
        throw AdbException.ConnectFailed(last);
    }

    /// <summary>timeout 為 0 代表不限制</summary>
    public void SetTimeout(double seconds)
    {
        if (_socket is null) return;
        int ms = (int)(seconds * 1000);
        _socket.ReceiveTimeout = ms;
        _socket.SendTimeout = ms;
    }

    public void Close()
    {
        lock (_lock)
        {
            if (_socket is null) return;
            try { _socket.Shutdown(SocketShutdown.Both); } catch { }
            _socket.Dispose();
            _socket = null;
        }
    }

    public void Dispose() => Close();

    // MARK: 讀寫

    public void Write(ReadOnlySpan<byte> data)
    {
        var s = _socket ?? throw AdbException.Closed();
        try
        {
            while (!data.IsEmpty)
            {
                int n = s.Send(data);
                if (n <= 0) throw AdbException.Closed();
                data = data[n..];
            }
        }
        catch (Exception e) when (e is SocketException or ObjectDisposedException) { throw AdbException.Closed(); }
    }

    public byte[] ReadExact(int count)
    {
        var s = _socket ?? throw AdbException.Closed();
        var buf = new byte[count];
        int off = 0;
        try
        {
            while (off < count)
            {
                int n = s.Receive(buf, off, count - off, SocketFlags.None);
                if (n <= 0) throw AdbException.Closed();
                off += n;
            }
        }
        catch (Exception e) when (e is SocketException or ObjectDisposedException) { throw AdbException.Closed(); }
        return buf;
    }

    public byte[] ReadSome(int max = 65_536)
    {
        var s = _socket ?? throw AdbException.Closed();
        var buf = new byte[max];
        try
        {
            int n = s.Receive(buf);
            if (n <= 0) throw AdbException.Closed();
            return n == max ? buf : buf[..n];
        }
        catch (Exception e) when (e is SocketException or ObjectDisposedException) { throw AdbException.Closed(); }
    }

    public byte[] ReadToEnd()
    {
        using var all = new MemoryStream();
        try { while (true) all.Write(ReadSome()); }
        catch (AdbException) { }
        return all.ToArray();
    }

    // MARK: adb server 協定

    public void SendRequest(string request)
    {
        var payload = Encoding.UTF8.GetBytes(request);
        var msg = new byte[4 + payload.Length];
        Encoding.ASCII.GetBytes(payload.Length.ToString("x4")).CopyTo(msg, 0);
        payload.CopyTo(msg, 4);
        Write(msg);
        var status = Encoding.UTF8.GetString(ReadExact(4));
        if (status == "OKAY") return;
        if (status == "FAIL") throw new AdbException(ReadLengthPrefixedString());
        throw AdbException.Protocol($"未預期的回應 {status}");
    }

    public string ReadLengthPrefixedString()
    {
        var hex = Encoding.UTF8.GetString(ReadExact(4));
        if (!int.TryParse(hex, System.Globalization.NumberStyles.HexNumber, null, out int len))
            throw AdbException.Protocol($"長度 {hex}");
        return Encoding.UTF8.GetString(ReadExact(len));
    }

    // MARK: 便利方法

    /// <summary>host: 開頭的查詢，例如 host:devices-l、host:version</summary>
    public static string HostQuery(AdbEndpoint endpoint, string request)
    {
        using var s = new AdbSocket(endpoint, 3);
        s.SendRequest(request);
        return s.ReadLengthPrefixedString();
    }

    /// <summary>開啟到裝置上某個服務的串流，例如 localabstract:scrcpy_xxx、shell:xxx</summary>
    public static AdbSocket Open(AdbEndpoint endpoint, string serial, string service, double timeout = 5)
    {
        var s = new AdbSocket(endpoint, timeout);
        try
        {
            s.SendRequest($"host:transport:{serial}");
            s.SendRequest(service);
        }
        catch { s.Close(); throw; }
        s.SetTimeout(0);
        return s;
    }
}
