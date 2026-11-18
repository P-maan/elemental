using System.Drawing;
using System.Text.Json.Nodes;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace Elemental;

sealed class SettingsWindow : Form
{
    readonly WebView2 _wv = new() { Dock = DockStyle.Fill };
    readonly SettingsStore _store;
    readonly Action<JsonObject> _onSave;

    public SettingsWindow(SettingsStore store, Action<JsonObject> onSave, Icon icon)
    {
        _store = store; _onSave = onSave;
        Text = "Elemental Settings";
        Icon = icon;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(560 * DeviceDpi / 96, 700 * DeviceDpi / 96);
        MinimumSize = new Size(420, 400);
        Controls.Add(_wv);
    }

    public async Task InitAsync(CoreWebView2Environment env, string webFolder)
    {
        await _wv.EnsureCoreWebView2Async(env);
        var core = _wv.CoreWebView2;
        core.Settings.AreDevToolsEnabled = false;
        core.Settings.AreDefaultContextMenusEnabled = false;
        core.SetVirtualHostNameToFolderMapping("elemental.local", webFolder, CoreWebView2HostResourceAccessKind.Allow);
        core.WebMessageReceived += (_, e) =>
        {
            try
            {
                if (JsonNode.Parse(e.WebMessageAsJson) is JsonObject m && ((string?)m["type"] is "saveSettings" or "elemental-settings") && m["settings"] is JsonObject s)
                    _onSave(s);
            }
            catch (Exception ex) { Log.Write("settings msg failed: " + ex.Message); }
        };
        core.NavigationCompleted += (_, _) => Push();
        core.Navigate("https://elemental.local/settings.html");
    }

    void Push()
    {
        var o = (JsonObject)_store.Current.DeepClone();
        o["startWithWindows"] = SettingsStore.StartWithWindowsEnabled();
        var js = o.ToJsonString();
        _ = _wv.CoreWebView2.ExecuteScriptAsync("window.ELEMENTAL_SETTINGS=" + js + ";window.elementalSettingsInit&&window.elementalSettingsInit(" + js + ")");
        _wv.CoreWebView2.PostWebMessageAsJson("{\"type\":\"elemental-settings\",\"settings\":" + js + "}");
    }

    public void RefreshInit() { if (_wv.CoreWebView2 != null) Push(); }
}
