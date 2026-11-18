using System.Diagnostics;

namespace Elemental;

static class Program
{
    const string MutexName = "Local\\Elemental.Host.v1", EvtSettings = "Local\\Elemental.Evt.Settings", EvtQuit = "Local\\Elemental.Evt.Quit", EvtPause = "Local\\Elemental.Evt.Pause";

    [STAThread]
    static void Main(string[] args)
    {
        bool quit = args.Contains("--quit"), settings = args.Contains("--settings");
        using var mutex = new Mutex(true, MutexName, out bool first);
        if (!first)
        {
            var name = quit ? EvtQuit : args.Contains("--toggle-pause") ? EvtPause : EvtSettings;
            if (EventWaitHandle.TryOpenExisting(name, out var ev)) ev.Set();
            if (quit)
            {
                // wait for the running instance to really exit (file locks!) so installers can replace/delete files
                var me = Environment.ProcessId;
                var sw = Stopwatch.StartNew();
                foreach (var p in Process.GetProcessesByName("Elemental").Where(p => p.Id != me))
                {
                    try { p.WaitForExit(Math.Max(1000, 12000 - (int)sw.ElapsedMilliseconds)); } catch { }
                }
            }
            return;
        }
        if (quit) return;

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.ThreadException += (_, e) => Log.Write("UI exception: " + e.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
        {
            Log.Write("fatal: " + e.ExceptionObject);
            DesktopAttach.RestoreWallpaper();
        };

        using var evSettings = new EventWaitHandle(false, EventResetMode.AutoReset, EvtSettings);
        using var evPause = new EventWaitHandle(false, EventResetMode.AutoReset, EvtPause);
        using var evQuit = new EventWaitHandle(false, EventResetMode.AutoReset, EvtQuit);
        var app = new TrayApp(settings);
        var ui = SynchronizationContext.Current!;
        RegisterWait(evSettings, () => ui.Post(_ => app.OpenSettings(), null));
        RegisterWait(evPause, () => ui.Post(_ => app.TogglePause(), null));
        RegisterWait(evQuit, () => ui.Post(_ => app.Quit(), null));
        try { Application.Run(app); }
        finally { DesktopAttach.RestoreWallpaper(); }
    }

    static void RegisterWait(EventWaitHandle h, Action a) =>
        ThreadPool.RegisterWaitForSingleObject(h, (_, _) => a(), null, Timeout.Infinite, false);
}
