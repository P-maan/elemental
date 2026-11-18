namespace Elemental;

static class Log
{
    static readonly object L = new();
    public static readonly string Dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Elemental");
    public static void Write(string s)
    {
        try
        {
            lock (L)
            {
                Directory.CreateDirectory(Dir);
                var p = Path.Combine(Dir, "host.log");
                if (File.Exists(p) && new FileInfo(p).Length > 512 * 1024) File.Move(p, p + ".old", true);
                File.AppendAllText(p, $"{DateTime.Now:HH:mm:ss.fff} {s}{Environment.NewLine}");
            }
        }
        catch { }
    }
}
