using System.Runtime.InteropServices;
using System.Text;

namespace ConsoleTR.App;

/// <summary>Win32 calls for window listing, screen capture, overlays and the hotkey.</summary>
internal static class Native
{
    internal const int GWL_EXSTYLE = -20;
    internal const long WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80, WS_EX_LAYERED = 0x80000, WS_EX_NOACTIVATE = 0x8000000;
    internal const uint WDA_EXCLUDEFROMCAPTURE = 0x11;
    internal static readonly IntPtr HWND_TOPMOST = new(-1);
    internal const uint SWP_NOSIZE = 0x1, SWP_NOACTIVATE = 0x10, SWP_SHOWWINDOW = 0x40;
    internal const uint MOD_ALT = 0x1, MOD_CONTROL = 0x2, MOD_NOREPEAT = 0x4000, VK_T = 0x54;
    internal const int WM_HOTKEY = 0x0312;
    internal const int DWMWA_CLOAKED = 14;
    internal const uint SRCCOPY = 0x00CC0020;
    internal const int HALFTONE = 4;

    [StructLayout(LayoutKind.Sequential)] internal struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] internal struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    internal struct BITMAPINFOHEADER
    {
        public uint biSize;
        public int biWidth, biHeight;
        public ushort biPlanes, biBitCount;
        public uint biCompression, biSizeImage;
        public int biXPelsPerMeter, biYPelsPerMeter;
        public uint biClrUsed, biClrImportant;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct BITMAPINFO
    {
        public BITMAPINFOHEADER bmiHeader;
        public uint bmiColors;
    }

    internal delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

    [DllImport("user32.dll")] internal static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
    [DllImport("user32.dll")] internal static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] internal static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")] internal static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern int GetWindowTextLength(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern int GetWindowText(IntPtr window, StringBuilder text, int count);
    [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] internal static extern bool GetClientRect(IntPtr window, out RECT rect);
    [DllImport("user32.dll")] internal static extern bool ClientToScreen(IntPtr window, ref POINT point);
    [DllImport("user32.dll")] internal static extern uint GetDpiForWindow(IntPtr window);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] internal static extern IntPtr GetWindowLongPtr(IntPtr window, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] internal static extern IntPtr SetWindowLongPtr(IntPtr window, int index, IntPtr value);
    [DllImport("user32.dll")] internal static extern bool SetWindowDisplayAffinity(IntPtr window, uint affinity);
    [DllImport("user32.dll")] internal static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] internal static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] internal static extern bool UnregisterHotKey(IntPtr window, int id);
    [DllImport("user32.dll")] internal static extern IntPtr GetDC(IntPtr window);
    [DllImport("user32.dll")] internal static extern int ReleaseDC(IntPtr window, IntPtr context);
    [DllImport("gdi32.dll")] internal static extern IntPtr CreateCompatibleDC(IntPtr context);
    [DllImport("gdi32.dll")] internal static extern bool DeleteDC(IntPtr context);
    [DllImport("gdi32.dll")] internal static extern IntPtr CreateDIBSection(IntPtr context, ref BITMAPINFO info, uint usage, out IntPtr bits, IntPtr section, uint offset);
    [DllImport("gdi32.dll")] internal static extern IntPtr SelectObject(IntPtr context, IntPtr item);
    [DllImport("gdi32.dll")] internal static extern bool DeleteObject(IntPtr item);
    [DllImport("gdi32.dll")] internal static extern int SetStretchBltMode(IntPtr context, int mode);
    [DllImport("gdi32.dll")] internal static extern bool SetBrushOrgEx(IntPtr context, int x, int y, IntPtr previous);
    [DllImport("gdi32.dll")]
    internal static extern bool StretchBlt(IntPtr target, int x, int y, int width, int height, IntPtr source, int sourceX, int sourceY, int sourceWidth, int sourceHeight, uint operation);
    [DllImport("dwmapi.dll")] internal static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out int value, int size);
}
