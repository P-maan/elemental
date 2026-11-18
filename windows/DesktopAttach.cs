using System.Drawing;
using static Elemental.Native;

namespace Elemental;

/// <summary>Finds the window that sits behind the desktop icons and parents our windows to it.</summary>
static class DesktopAttach
{
    public static IntPtr FindProgman() => FindWindow("Progman", null);

    /// <summary>Returns the window to parent wallpaper windows to, or Zero.</summary>
    public static IntPtr FindHost()
    {
        var progman = FindProgman();
        if (progman == IntPtr.Zero) return IntPtr.Zero;
        SendMessageTimeout(progman, 0x052C, new IntPtr(0xD), new IntPtr(1), 0, 1000, out _);

        // Classic layout (Win10 / Win11 <= 23H2): a top-level WorkerW holds SHELLDLL_DefView;
        // the WorkerW that is its next sibling is the one behind the icons.
        IntPtr worker = IntPtr.Zero;
        EnumWindows((h, _) =>
        {
            if (FindWindowEx(h, IntPtr.Zero, "SHELLDLL_DefView", null) != IntPtr.Zero)
                worker = FindWindowEx(IntPtr.Zero, h, "WorkerW", null);
            return true;
        }, IntPtr.Zero);
        if (worker != IntPtr.Zero) { Log.Write($"attach: classic WorkerW {worker:X}"); return worker; }

        // Windows 11 24H2+: Progman holds SHELLDLL_DefView and a child WorkerW behind it.
        if (FindWindowEx(progman, IntPtr.Zero, "SHELLDLL_DefView", null) != IntPtr.Zero)
        {
            var child = FindWindowEx(progman, IntPtr.Zero, "WorkerW", null);
            if (child != IntPtr.Zero) { Log.Write($"attach: 24H2 child WorkerW {child:X}"); return child; }
            Log.Write("attach: 24H2 Progman only");
            return progman;
        }
        return IntPtr.Zero;
    }

    public static bool Attach(IntPtr hwnd, IntPtr host, Rectangle screenBounds)
    {
        if (host == IntPtr.Zero || !IsWindow(hwnd)) return false;
        long style = GetLong(hwnd, GWL_STYLE);
        style = (style & ~(WS_POPUP | WS_CAPTION | WS_THICKFRAME)) | WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | WS_CLIPCHILDREN;
        SetLong(hwnd, GWL_STYLE, style);
        long ex = GetLong(hwnd, GWL_EXSTYLE);
        SetLong(hwnd, GWL_EXSTYLE, (ex | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE) & ~WS_EX_APPWINDOW);
        SetParent(hwnd, host);
        return Place(hwnd, host, screenBounds);
    }

    public static bool Place(IntPtr hwnd, IntPtr host, Rectangle b)
    {
        var p = new POINT { X = b.X, Y = b.Y };
        ScreenToClient(host, ref p);
        return SetWindowPos(hwnd, IntPtr.Zero, p.X, p.Y, b.Width, b.Height,
            SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_FRAMECHANGED);
    }

    public static void RestoreWallpaper()
    {
        try { SystemParametersInfo(SPI_SETDESKWALLPAPER, 0, null, SPIF_UPDATEINIFILE | SPIF_SENDCHANGE); }
        catch (Exception e) { Log.Write("restore wallpaper failed: " + e.Message); }
    }
}
