using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace ConsoleTR.App;

/// <summary>A window's client area in physical screen pixels.</summary>
internal sealed record PixelRect(int X, int Y, int Width, int Height, double DpiScale);

/// <summary>A game source is a Remote Play window or an OBS projector, which ConsoleTR should read.</summary>
internal sealed record WindowItem(IntPtr Handle, string Title, bool IsGameSource, long Area)
{
    public override string ToString() => Title;
}

internal static class TargetWindows
{
    /// <summary>Visible top-level windows of other apps, game sources first.</summary>
    internal static List<WindowItem> List()
    {
        var items = new List<WindowItem>();
        uint self = (uint)Environment.ProcessId;
        Native.EnumWindows((window, _) =>
        {
            if (!Native.IsWindowVisible(window)) return true;
            Native.GetWindowThreadProcessId(window, out uint process);
            if (process == self) return true;
            if (Native.DwmGetWindowAttribute(window, Native.DWMWA_CLOAKED, out int cloaked, sizeof(int)) == 0 && cloaked != 0) return true;
            int length = Native.GetWindowTextLength(window);
            if (length == 0) return true;
            var text = new StringBuilder(length + 1);
            Native.GetWindowText(window, text, text.Capacity);
            if (Client(window) is not { Width: > 100, Height: > 100 } client) return true;
            string title = text.ToString();
            string app = "";
            try { app = Process.GetProcessById((int)process).ProcessName; } catch (ArgumentException) { } catch (InvalidOperationException) { }
            bool remotePlay = title.Contains("Remote Play", StringComparison.OrdinalIgnoreCase) || app.Contains("RemotePlay", StringComparison.OrdinalIgnoreCase);
            // OBS's main window shows the game only as a preview next to OBS's own text.
            bool projector = app.StartsWith("obs", StringComparison.OrdinalIgnoreCase) &&
                (title.Contains("Projector", StringComparison.OrdinalIgnoreCase) || title.Contains("Projektör", StringComparison.OrdinalIgnoreCase));
            bool game = remotePlay || projector;
            items.Add(new WindowItem(window, game ? title + " (oyun görüntüsü)" : title, game, (long)client.Width * client.Height));
            return true;
        }, IntPtr.Zero);
        // The largest game source first: Remote Play's video window over its dialogs, a projector.
        return items.OrderByDescending(i => i.IsGameSource).ThenByDescending(i => i.IsGameSource ? i.Area : 0)
            .ThenBy(i => i.Title, StringComparer.CurrentCultureIgnoreCase).ToList();
    }

    /// <summary>The client area, or null when the window is minimized or too small.</summary>
    internal static PixelRect? Client(IntPtr window)
    {
        if (!Native.IsWindow(window) || Native.IsIconic(window) || !Native.GetClientRect(window, out var rect)) return null;
        var origin = new Native.POINT();
        if (!Native.ClientToScreen(window, ref origin)) return null;
        int width = rect.Right - rect.Left, height = rect.Bottom - rect.Top;
        if (width < 60 || height < 30) return null;
        uint dpi = Native.GetDpiForWindow(window);
        return new PixelRect(origin.X, origin.Y, width, height, dpi == 0 ? 1 : dpi / 96.0);
    }
}

internal static class ScreenGrabber
{
    /// <summary>
    /// Copies a screen area into a top-down BGRA buffer, scaled to at most maxWidth pixels
    /// wide like the macOS capture. Layered windows, including ConsoleTR's overlays, are not
    /// part of a plain StretchBlt, so the app never reads its own translations.
    /// </summary>
    internal static (byte[] Pixels, int Width, int Height) Capture(PixelRect area, int maxWidth, uint maxDimension)
    {
        double scale = Math.Min(1.0, Math.Min((double)maxWidth / area.Width, (double)maxDimension / Math.Max(area.Width, area.Height)));
        int width = Math.Max(2, (int)(area.Width * scale)), height = Math.Max(2, (int)(area.Height * scale));
        IntPtr screen = Native.GetDC(IntPtr.Zero);
        IntPtr memory = Native.CreateCompatibleDC(screen);
        var info = new Native.BITMAPINFO
        {
            bmiHeader = new Native.BITMAPINFOHEADER
            {
                biSize = (uint)Marshal.SizeOf<Native.BITMAPINFOHEADER>(), biWidth = width, biHeight = -height,
                biPlanes = 1, biBitCount = 32, biCompression = 0,
            },
        };
        IntPtr bitmap = Native.CreateDIBSection(screen, ref info, 0, out IntPtr bits, IntPtr.Zero, 0);
        try
        {
            if (bitmap == IntPtr.Zero) throw new InvalidOperationException("Ekran görüntüsü için bellek ayrılamadı.");
            IntPtr previous = Native.SelectObject(memory, bitmap);
            Native.SetStretchBltMode(memory, Native.HALFTONE);
            Native.SetBrushOrgEx(memory, 0, 0, IntPtr.Zero);
            bool copied = Native.StretchBlt(memory, 0, 0, width, height, screen, area.X, area.Y, area.Width, area.Height, Native.SRCCOPY);
            var pixels = new byte[width * height * 4];
            if (copied) Marshal.Copy(bits, pixels, 0, pixels.Length);
            Native.SelectObject(memory, previous);
            if (!copied) throw new InvalidOperationException("Pencere görüntüsü alınamadı.");
            return (pixels, width, height);
        }
        finally
        {
            if (bitmap != IntPtr.Zero) Native.DeleteObject(bitmap);
            Native.DeleteDC(memory);
            Native.ReleaseDC(IntPtr.Zero, screen);
        }
    }
}
