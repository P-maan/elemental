using System.Text.Json.Nodes;
using Windows.Devices.Geolocation;

namespace Elemental;

static class LocationService
{
    public static string Tz()
    {
        var id = TimeZoneInfo.Local.Id;
        return TimeZoneInfo.TryConvertWindowsIdToIanaId(id, out var iana) && iana != null ? iana : id;
    }

    static async Task<(double, double)?> FromWindows()
    {
        try
        {
            var work = Task.Run(async () =>
            {
                var acc = await Geolocator.RequestAccessAsync();
                if (acc != GeolocationAccessStatus.Allowed) return ((double, double)?)null;
                var g = new Geolocator { DesiredAccuracyInMeters = 5000 };
                var pos = await g.GetGeopositionAsync(TimeSpan.FromHours(6), TimeSpan.FromSeconds(8));
                return (pos.Coordinate.Point.Position.Latitude, pos.Coordinate.Point.Position.Longitude);
            });
            if (await Task.WhenAny(work, Task.Delay(10000)) == work) return await work;
        }
        catch (Exception e) { Log.Write("geolocator: " + e.Message); }
        return null;
    }

    public static async Task<JsonObject?> Resolve(SettingsStore s)
    {
        string city = s.GetString("city");
        if (s.GetBool("useWindowsLocation", true))
        {
            var p = await FromWindows();
            if (p is { } v)
            {
                Log.Write($"location from Windows {v.Item1:F2},{v.Item2:F2}");
                return new JsonObject { ["lat"] = v.Item1, ["lon"] = v.Item2, ["city"] = city, ["tz"] = Tz() };
            }
            Log.Write("Windows location unavailable");
        }
        var lat = s.GetNumber("lat"); var lon = s.GetNumber("lon");
        if (lat != null && lon != null)
            return new JsonObject { ["lat"] = lat, ["lon"] = lon, ["city"] = city, ["tz"] = Tz() };
        return null;
    }
}
