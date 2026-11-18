using System.Drawing;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using static Elemental.Native;

namespace Elemental;

sealed class WallpaperWindow : Form
{
    readonly WebView2 _wv = new() { Dock = DockStyle.Fill, DefaultBackgroundColor = Color.Black };
    public Rectangle Monitor { get; }
    public IntPtr Host { get; private set; }
    public bool PageReady { get; private set; }
    public event Action<WallpaperWindow>? Loaded;
    public event Action<WallpaperWindow, string>? Message;

    public WallpaperWindow(Rectangle monitor)
    {
        Monitor = monitor;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        Bounds = monitor;
        BackColor = Color.Black;
        Controls.Add(_wv);
    }

    protected override bool ShowWithoutActivation => true;
    protected override CreateParams CreateParams
    {
        get { var cp = base.CreateParams; cp.ExStyle |= (int)(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE); return cp; }
    }

    public async Task InitAsync(CoreWebView2Environment env, string webFolder)
    {
        await _wv.EnsureCoreWebView2Async(env);
        var core = _wv.CoreWebView2;
        core.Settings.AreDefaultContextMenusEnabled = false;
        core.Settings.AreDevToolsEnabled = false;
        core.Settings.IsStatusBarEnabled = false;
        core.Settings.IsZoomControlEnabled = false;
        core.Settings.AreBrowserAcceleratorKeysEnabled = false;
        core.SetVirtualHostNameToFolderMapping("elemental.local", webFolder, CoreWebView2HostResourceAccessKind.Allow);
        core.WebMessageReceived += (_, e) => { try { Message?.Invoke(this, e.WebMessageAsJson); } catch { } };
        core.NavigationCompleted += (_, e) => { PageReady = e.IsSuccess; Log.Write($"nav completed ok={e.IsSuccess} on {Monitor}"); Loaded?.Invoke(this); };
        core.ProcessFailed += (_, e) => Log.Write("webview process failed: " + e.ProcessFailedKind);
        ApplyScale();
        core.Navigate("https://elemental.local/index.html");
    }

    void ApplyScale()
    {
        try
        {
            var c = _wv.CoreWebView2Controller; if (c == null) return;
            var m = MonitorFromPoint(new POINT { X = Monitor.X + 1, Y = Monitor.Y + 1 }, 2);
            if (GetDpiForMonitor(m, 0, out var dx, out _) == 0 && dx > 0)
            {
                c.ShouldDetectMonitorScaleChanges = false;
                c.RasterizationScale = dx / 96.0;
            }
        }
        catch (Exception e) { Log.Write("scale failed: " + e.Message); }
    }

    public bool AttachTo(IntPtr host)
    {
        if (!IsHandleCreated) _ = Handle;
        Host = host;
        var ok = DesktopAttach.Attach(Handle, host, Monitor);
        Log.Write($"attach {Monitor} -> {host:X} ok={ok}");
        return ok;
    }

    public bool IsAttached => IsHandleCreated && Host != IntPtr.Zero && IsWindow(Host) && GetParent(Handle) == Host;

    public void Reposition() { if (IsHandleCreated && Host != IntPtr.Zero) DesktopAttach.Place(Handle, Host, Monitor); }

    public void Run(string script)
    {
        if (_wv.CoreWebView2 != null && PageReady)
            _ = _wv.CoreWebView2.ExecuteScriptAsync(script);
    }

    protected override void OnHandleDestroyed(EventArgs e) { base.OnHandleDestroyed(e); }
    protected override void Dispose(bool disposing)
    {
        if (disposing) { try { _wv.Dispose(); } catch { } }
        base.Dispose(disposing);
    }
}
