using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Effects;
using ConsoleTR.Core;

namespace ConsoleTR.App;

internal sealed record OverlayStyle(double FontSize = 23, double Position = 4, double Opacity = 0.45, bool Light = false, bool SubtitleBand = true);

/// <summary>A click-through, always-on-top translation bubble next to the source text.</summary>
internal sealed class OverlayWindow : Window
{
    private readonly TextBlock label = new()
    {
        TextWrapping = TextWrapping.Wrap,
        TextAlignment = TextAlignment.Center,
        FontWeight = FontWeights.SemiBold,
        Effect = new DropShadowEffect { BlurRadius = 4, ShadowDepth = 0, Color = Colors.Black },
    };
    private readonly Border border;
    private IntPtr handle;

    internal OverlayWindow()
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        ResizeMode = ResizeMode.NoResize;
        IsHitTestVisible = false;
        Focusable = false;
        SizeToContent = SizeToContent.WidthAndHeight;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Left = -10000;
        Top = -10000;
        border = new Border { CornerRadius = new CornerRadius(10), Padding = new Thickness(20, 9, 20, 9), Child = label };
        Content = border;
        SourceInitialized += (_, _) =>
        {
            handle = new WindowInteropHelper(this).Handle;
            long style = Native.GetWindowLongPtr(handle, Native.GWL_EXSTYLE).ToInt64();
            Native.SetWindowLongPtr(handle, Native.GWL_EXSTYLE,
                new IntPtr(style | Native.WS_EX_TRANSPARENT | Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE | Native.WS_EX_LAYERED));
            // Keeps the bubble out of every screen capture, including ConsoleTR's own.
            Native.SetWindowDisplayAffinity(handle, Native.WDA_EXCLUDEFROMCAPTURE);
        };
    }

    /// <summary>
    /// Places the translation below the source text, or above it near the bottom edge. With
    /// <paramref name="above"/> it always goes above the box, as the caption band does.
    /// </summary>
    internal void Present(string text, NormRect box, PixelRect frame, OverlayStyle style, bool above = false)
    {
        double scale = frame.DpiScale;
        label.Text = text;
        label.FontSize = style.FontSize;
        label.Foreground = style.Light ? Brushes.Black : Brushes.White;
        byte alpha = (byte)Math.Clamp(style.Opacity * 255, 0, 255);
        border.Background = new SolidColorBrush(style.Light ? Color.FromArgb(alpha, 255, 255, 255) : Color.FromArgb(alpha, 0, 0, 0));
        double sourceX = frame.X + box.MinX * frame.Width, sourceY = frame.Y + box.MinY * frame.Height;
        double sourceWidth = box.Width * frame.Width, sourceHeight = box.Height * frame.Height;
        double widest = Math.Min(frame.Width, Math.Max(220 * scale, sourceWidth * 1.45));
        label.MaxWidth = Math.Max(20, widest / scale - 40);
        if (!IsVisible) Show();
        UpdateLayout();
        double width = ActualWidth * scale, height = ActualHeight * scale, gap = style.Position * scale;
        double left = Math.Min(frame.X + frame.Width - width, Math.Max(frame.X, sourceX + sourceWidth / 2 - width / 2));
        double below = sourceY + sourceHeight + gap;
        double over = Math.Max(frame.Y, sourceY - gap - height);
        double top = !above && below + height <= frame.Y + frame.Height ? below : over;
        Native.SetWindowPos(handle, Native.HWND_TOPMOST, (int)Math.Round(left), (int)Math.Round(top), 0, 0,
            Native.SWP_NOSIZE | Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
    }
}
