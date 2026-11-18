using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Win32;

namespace Elemental;

sealed class SettingsStore
{
    public static readonly string FilePath = Path.Combine(Log.Dir, "settings.json");
    public JsonObject Current { get; private set; } = new();

    public void Load()
    {
        try
        {
            if (File.Exists(FilePath) && JsonNode.Parse(File.ReadAllText(FilePath)) is JsonObject o) Current = o;
        }
        catch (Exception e) { Log.Write("settings load failed: " + e.Message); Current = new JsonObject(); }
    }

    /// <summary>Shallow merge; a null value removes the key.</summary>
    public void Merge(JsonObject patch)
    {
        foreach (var kv in patch)
        {
            if (kv.Value is null) Current.Remove(kv.Key);
            else Current[kv.Key] = kv.Value.DeepClone();
        }
        Save();
    }

    void Save()
    {
        try
        {
            Directory.CreateDirectory(Log.Dir);
            var tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, Current.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
            File.Move(tmp, FilePath, true);
        }
        catch (Exception e) { Log.Write("settings save failed: " + e.Message); }
    }

    public bool GetBool(string key, bool def) =>
        Current.TryGetPropertyValue(key, out var n) && n is JsonValue v && v.TryGetValue<bool>(out var b) ? b : def;

    public double? GetNumber(string key)
    {
        if (Current.TryGetPropertyValue(key, out var n) && n is JsonValue v)
        {
            if (v.TryGetValue<double>(out var d)) return d;
            if (v.TryGetValue<string>(out var s) && double.TryParse(s, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out d)) return d;
        }
        return null;
    }

    public string GetString(string key) =>
        Current.TryGetPropertyValue(key, out var n) && n is JsonValue v && v.TryGetValue<string>(out var s) ? s : "";

    // ---- start with Windows ----
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    public static bool StartWithWindowsEnabled()
    {
        try { using var k = Registry.CurrentUser.OpenSubKey(RunKey); return k?.GetValue("Elemental") != null; }
        catch { return false; }
    }
    public static void SetStartWithWindows(bool on)
    {
        try
        {
            using var k = Registry.CurrentUser.CreateSubKey(RunKey);
            if (on) k.SetValue("Elemental", "\"" + Environment.ProcessPath + "\"");
            else k.DeleteValue("Elemental", false);
        }
        catch (Exception e) { Log.Write("run key failed: " + e.Message); }
    }
}
