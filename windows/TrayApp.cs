using System.Drawing;
using System.Text.Json.Nodes;
using Microsoft.Web.WebView2.Core;
using Microsoft.Win32;
using static Elemental.Native;

namespace Elemental;

sealed class TrayApp : ApplicationContext
{
    readonly SettingsStore _store = new();
    readonly NotifyIcon _tray;
    readonly ToolStripMenuItem _pauseItem, _startItem;
    readonly System.Windows.Forms.Timer _poll = new() { Interval = 2000 };
    readonly System.Windows.Forms.Timer _watchdog = new() { Interval = 5000 };
    readonly System.Windows.Forms.Timer _displayDebounce = new() { Interval = 1500 };
    readonly List<WallpaperWindow> _windows = new();
    readonly Icon _icon;
    readonly SynchronizationContext _ui;
    readonly MsgWindow _msgWin;
    readonly string _webFolder = Path.Combine(AppContext.BaseDirectory, "web");

    CoreWebView2Environment? _env;
    SettingsWindow? _settings;
    JsonObject? _location;
    bool _userPaused, _locked, _fullscreen, _onBattery, _building, _closing, _cleaned;

    public TrayApp(bool openSettings)
    {
        _ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
        _store.Load();
        _icon = LoadIcon();

        _pauseItem = new ToolStripMenuItem("Pause", null, (_, _) => SetUserPaused(!_userPaused));
        _startItem = new ToolStripMenuItem("Start with Windows") { CheckOnClick = false };
        _startItem.Click += (_, _) => ToggleStart();
        var menu = new ContextMenuStrip();
        menu.Items.Add(_pauseItem);
        menu.Items.Add(new ToolStripMenuItem("Settings...", null, (_, _) => OpenSettings()));
        menu.Items.Add(_startItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Quit", null, (_, _) => Quit()));
        menu.Opening += (_, _) => _startItem.Checked = SettingsStore.StartWithWindowsEnabled();

        _tray = new NotifyIcon { Icon = _icon, Text = "Elemental", ContextMenuStrip = menu, Visible = true };
        _tray.DoubleClick += (_, _) => OpenSettings();
        _startItem.Checked = SettingsStore.StartWithWindowsEnabled();
        Log.Write("tray created visible=" + _tray.Visible + " menu=" + string.Join(" | ", menu.Items.Cast<ToolStripItem>().Select(i => i.Text)));

        _msgWin = new MsgWindow(this);
        SystemEvents.DisplaySettingsChanged += OnDisplayChanged;
        SystemEvents.SessionSwitch += OnSessionSwitch;
        SystemEvents.PowerModeChanged += (_, _) => PollState();
        _displayDebounce.Tick += async (_, _) => { _displayDebounce.Stop(); await RebuildAsync(); };
        _poll.Tick += (_, _) => PollState();
        _watchdog.Tick += (_, _) => Watchdog();

        AppDomain.CurrentDomain.ProcessExit += (_, _) => Cleanup();
        _ = StartAsync(openSettings);
    }

    static Icon LoadIcon()
    {
        try { var i = Icon.ExtractAssociatedIcon(Environment.ProcessPath!); if (i != null) return i; } catch { }
        return SystemIcons.Application;
    }

    async Task StartAsync(bool openSettings)
    {
        try
        {
            var opts = new CoreWebView2EnvironmentOptions("--autoplay-policy=no-user-gesture-required --disable-features=CalculateNativeWinOcclusion");
            var udf = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Elemental", "WebView2");
            _env = await CoreWebView2Environment.CreateAsync(null, udf, opts);
        }
        catch (Exception e)
        {
            Log.Write("WebView2 runtime unavailable: " + e);
            _tray.ShowBalloonTip(8000, "Elemental", "The Microsoft WebView2 runtime is missing. Install it from microsoft.com/edge/webview2.", ToolTipIcon.Error);
            return;
        }
        PollState();
        _poll.Start(); _watchdog.Start();
        await RebuildAsync();
        await RefreshLocationAsync();
        ApplyAll();
        if (openSettings) OpenSettings();
    }

    // ---------- wallpaper windows ----------
    async Task RebuildAsync()
    {
        if (_building || _closing || _env == null) return;
        _building = true;
        try
        {
            foreach (var w in _windows) { try { w.Close(); w.Dispose(); } catch { } }
            _windows.Clear();
            var host = DesktopAttach.FindHost();
            if (host == IntPtr.Zero) { Log.Write("rebuild: desktop host not found yet, will retry"); return; }
            Log.Write($"rebuild: {Screen.AllScreens.Length} monitors, host={host:X}");
            foreach (var s in Screen.AllScreens)
            {
                var w = new WallpaperWindow(s.Bounds);
                w.Loaded += x => ApplyTo(x);
                w.Message += OnPageMessage;
                _windows.Add(w);
                w.Show();
                w.AttachTo(host);
                await w.InitAsync(_env, _webFolder);
            }
        }
        catch (Exception e) { Log.Write("rebuild failed: " + e); }
        finally { _building = false; }
    }

    void Watchdog()
    {
        if (_building || _closing) return;
        if (_windows.Count == 0) { _ = RebuildAsync(); return; }
        if (_windows.All(w => w.IsAttached)) return;
        // explorer restarted: the old WorkerW (and our child windows with it) is gone -> rebuild from scratch
        if (_windows.Any(w => w.IsDisposed || !w.IsHandleCreated || w.Host == IntPtr.Zero || !IsWindow(w.Host)))
        {
            Log.Write("watchdog: host gone, rebuilding");
            _ = RebuildAsync();
            return;
        }
        var host = DesktopAttach.FindHost();
        if (host == IntPtr.Zero) return;
        Log.Write("watchdog: re-attaching");
        foreach (var w in _windows) w.AttachTo(host);
    }

    void OnDisplayChanged(object? s, EventArgs e) { _ui.Post(_ => { _displayDebounce.Stop(); _displayDebounce.Start(); }, null); }

    void OnSessionSwitch(object? s, SessionSwitchEventArgs e)
    {
        _ui.Post(_ =>
        {
            if (e.Reason == SessionSwitchReason.SessionLock) { _locked = true; ApplyAll(); }
            else if (e.Reason == SessionSwitchReason.SessionUnlock || e.Reason == SessionSwitchReason.ConsoleConnect)
            { _locked = false; PollState(); Watchdog(); ApplyAll(); }
        }, null);
    }

    internal void OnTaskbarCreated()
    {
        Log.Write("TaskbarCreated (explorer restarted)");
        _ui.Post(_ => { _ = Task.Delay(1500).ContinueWith(__ => _ui.Post(___ => Watchdog(), null)); }, null);
    }

    internal void OnDisplayChangeMsg() => OnDisplayChanged(null, EventArgs.Empty);

    // ---------- state ----------
    void PollState()
    {
        bool battery = SystemInformation.PowerStatus.PowerLineStatus == PowerLineStatus.Offline;
        bool fs = FullscreenAppActive();
        if (battery != _onBattery || fs != _fullscreen)
        {
            _onBattery = battery; _fullscreen = fs;
            Log.Write($"state: onBattery={battery} fullscreen={fs}");
            ApplyAll();
        }
    }

    bool Paused => _userPaused || _locked || _fullscreen;

    static bool FullscreenAppActive()
    {
        try
        {
            if (SHQueryUserNotificationState(out int st) == 0 && (st == 2 || st == 3 || st == 4)) return true;
            var fg = GetForegroundWindow();
            if (fg == IntPtr.Zero || fg == GetShellWindow() || fg == GetDesktopWindow() || IsIconic(fg) || !IsWindowVisible(fg)) return false;
            GetWindowThreadProcessId(fg, out uint pid);
            if (pid == Environment.ProcessId) return false;
            var cls = ClassOf(fg);
            if (cls is "Progman" or "WorkerW" or "Shell_TrayWnd" or "Shell_SecondaryTrayWnd" or "SHELLDLL_DefView") return false;
            if (DwmGetWindowAttribute(fg, 14, out int cloaked, 4) == 0 && cloaked != 0) return false;
            if ((GetLong(fg, GWL_STYLE) & WS_CAPTION) == WS_CAPTION) return false;
            if (!GetWindowRect(fg, out var r)) return false;
            var mi = new MONITORINFO { cbSize = System.Runtime.InteropServices.Marshal.SizeOf<MONITORINFO>() };
            if (!GetMonitorInfo(MonitorFromWindow(fg, 2), ref mi)) return false;
            var m = mi.rcMonitor;
            return r.Left <= m.Left && r.Top <= m.Top && r.Right >= m.Right && r.Bottom >= m.Bottom;
        }
        catch { return false; }
    }

    public void TogglePause() => SetUserPaused(!_userPaused);

    void SetUserPaused(bool p)
    {
        _userPaused = p;
        Log.Write("user paused=" + p);
        _pauseItem.Text = p ? "Resume" : "Pause";
        _tray.Text = p ? "Elemental (paused)" : "Elemental";
        ApplyAll();
    }

    // ---------- page contract ----------
    string BuildPayload()
    {
        var settings = (JsonObject)_store.Current.DeepClone();
        settings["startWithWindows"] = SettingsStore.StartWithWindowsEnabled();
        var o = new JsonObject
        {
            ["settings"] = settings,
            ["location"] = _location?.DeepClone(),
            ["paused"] = Paused,
            ["onBattery"] = _onBattery,
        };
        return o.ToJsonString();
    }

    void ApplyTo(WallpaperWindow w)
    {
        bool hide = _locked || _fullscreen;   // user Pause keeps the last frame on screen
        if (!hide) w.SetWebViewVisible(true);
        w.Run(BuildScript());
        if (hide) w.SetWebViewVisible(false);
    }
    string BuildScript() => ("window.elementalApply&&window.elementalApply(" + BuildPayload() + ")");
    void ApplyAll() { foreach (var w in _windows) ApplyTo(w); }

    async Task RefreshLocationAsync()
    {
        try { _location = await LocationService.Resolve(_store); } catch (Exception e) { Log.Write("location failed: " + e.Message); }
    }

    void OnPageMessage(WallpaperWindow w, string json)
    {
        try
        {
            if (JsonNode.Parse(json) is not JsonObject m) return;
            switch ((string?)m["type"])
            {
                case "needLocation":
                    _ = RefreshLocationAsync().ContinueWith(_ => _ui.Post(__ => ApplyAll(), null));
                    break;
                case "setSettings":
                    if (m["settings"] is JsonObject s) SaveSettings(s);
                    break;
                default:
                    Log.Write("page msg: " + json);
                    break;
            }
        }
        catch (Exception e) { Log.Write("page msg failed: " + e.Message); }
    }

    void SaveSettings(JsonObject patch)
    {
        _store.Merge(patch);
        if (patch["startWithWindows"] is JsonValue v && v.TryGetValue<bool>(out var sw)) SettingsStore.SetStartWithWindows(sw);
        _startItem.Checked = SettingsStore.StartWithWindowsEnabled();
        _ = RefreshLocationAsync().ContinueWith(_ => _ui.Post(__ => { ApplyAll(); _settings?.RefreshInit(); }, null));
        ApplyAll();
    }

    void ToggleStart()
    {
        bool on = !SettingsStore.StartWithWindowsEnabled();
        SettingsStore.SetStartWithWindows(on);
        _store.Merge(new JsonObject { ["startWithWindows"] = on });
        _startItem.Checked = on;
        ApplyAll();
    }

    // ---------- settings window ----------
    public void OpenSettings()
    {
        if (_env == null) return;
        if (_settings != null && !_settings.IsDisposed) { _settings.TopMost = true; _settings.Show(); _settings.Activate(); _settings.TopMost = false; return; }
        _settings = new SettingsWindow(_store, SaveSettings, _icon);
        _settings.FormClosed += (_, _) => _settings = null;
        _settings.TopMost = true;      // come to front even when launched from the background
        _settings.Show();
        _settings.Activate();
        _settings.TopMost = false;
        _ = _settings.InitAsync(_env, _webFolder);
    }

    // ---------- quit ----------
    public void Quit()
    {
        _closing = true;
        Cleanup();
        ExitThread();
    }

    void Cleanup()
    {
        if (_cleaned) return;
        _cleaned = true;
        _closing = true;
        try { _poll.Stop(); _watchdog.Stop(); } catch { }
        try { SystemEvents.DisplaySettingsChanged -= OnDisplayChanged; SystemEvents.SessionSwitch -= OnSessionSwitch; } catch { }
        try { foreach (var w in _windows) { w.Close(); w.Dispose(); } _windows.Clear(); } catch { }
        try { _settings?.Close(); } catch { }
        try { _tray.Visible = false; _tray.Dispose(); } catch { }
        DesktopAttach.RestoreWallpaper();
        Log.Write("cleanup done");
    }

    sealed class MsgWindow : NativeWindow
    {
        readonly TrayApp _app; readonly uint _taskbarCreated = RegisterWindowMessage("TaskbarCreated");
        public MsgWindow(TrayApp app) { _app = app; CreateHandle(new CreateParams()); }
        protected override void WndProc(ref Message m)
        {
            if (m.Msg == _taskbarCreated) _app.OnTaskbarCreated();
            else if (m.Msg == WM_DISPLAYCHANGE) _app.OnDisplayChangeMsg();
            base.WndProc(ref m);
        }
    }
}
