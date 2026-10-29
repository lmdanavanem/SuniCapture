using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Imaging;

namespace SuniCapture.Services;

/// <summary>Rectangle in physical desktop pixels, including negative monitor coordinates.</summary>
public readonly record struct DesktopArea(int X, int Y, int Width, int Height);

public sealed record WindowTarget(nint Handle, string Title, DesktopArea Bounds);

/// <summary>
/// Captures the visible Windows desktop. Protected surfaces, minimized applications and
/// an application's occluded content are not reconstructed by this GDI capture route.
/// </summary>
public static class DesktopCapture
{
    public static DesktopArea VirtualBounds => new(
        Native.GetSystemMetrics(76), Native.GetSystemMetrics(77),
        Native.GetSystemMetrics(78), Native.GetSystemMetrics(79));

    public static IReadOnlyList<WindowTarget> GetWindows(nint excludeHandle)
    {
        var windows = new List<WindowTarget>();
        Native.EnumWindows((handle, _) =>
        {
            if (handle == excludeHandle || !Native.IsWindowVisible(handle)
                || Native.GetWindow(handle, 4) != 0) return true;
            long extendedStyle = Native.GetWindowLongPtr(handle, -20).ToInt64();
            if ((extendedStyle & 0x80) != 0) return true; // Tool windows are not user capture targets.
            int cloaked;
            if (Native.DwmGetWindowAttribute(handle, 14, out cloaked, sizeof(int)) == 0 && cloaked != 0)
                return true;
            int length = Native.GetWindowTextLength(handle);
            if (length <= 0) return true;
            var title = new StringBuilder(Math.Min(length + 1, 4096));
            Native.GetWindowText(handle, title, title.Capacity);
            string caption = title.ToString().Trim();
            if (caption.Length == 0) return true;
            try
            {
                DesktopArea bounds = GetWindowBounds(handle);
                if (bounds.Width > 1 && bounds.Height > 1)
                    windows.Add(new WindowTarget(handle, caption, bounds));
            }
            catch (InvalidOperationException) { /* Window closed during enumeration. */ }
            return true;
        }, 0);
        windows.Sort((a, b) => string.Compare(a.Title, b.Title, true, CultureInfo.CurrentCulture));
        return windows;
    }

    public static DesktopArea GetWindowBounds(nint handle)
    {
        if (!Native.IsWindow(handle))
            throw new InvalidOperationException(L.T("desktop.closedRefresh"));
        Native.Rect rect;
        if (Native.DwmGetWindowAttribute(handle, 9, out rect, Marshal.SizeOf<Native.Rect>()) != 0
            && !Native.GetWindowRect(handle, out rect))
            throw new InvalidOperationException(L.T("desktop.noPosition"));
        return new DesktopArea(rect.Left, rect.Top, Math.Max(0, rect.Right - rect.Left), Math.Max(0, rect.Bottom - rect.Top));
    }

    public static BitmapSource CaptureVirtualDesktop() => Capture(VirtualBounds);

    public static BitmapSource Capture(DesktopArea area)
    {
        DesktopArea desktop = VirtualBounds;
        if (area.Width <= 0 || area.Height <= 0 || area.Width > 32768 || area.Height > 32768
            || (long)area.Width * area.Height > 160_000_000)
            throw new ArgumentOutOfRangeException(nameof(area), L.T("desktop.tooLarge"));
        if (area.X < desktop.X || area.Y < desktop.Y
            || (long)area.X + area.Width > (long)desktop.X + desktop.Width
            || (long)area.Y + area.Height > (long)desktop.Y + desktop.Height)
            throw new ArgumentOutOfRangeException(nameof(area), L.T("desktop.outside"));

        nint screen = 0, memory = 0, bitmap = 0, previous = 0;
        try
        {
            screen = Native.GetDC(0);
            if (screen == 0) throw CaptureError();
            memory = Native.CreateCompatibleDC(screen);
            if (memory == 0) throw CaptureError();
            bitmap = Native.CreateCompatibleBitmap(screen, area.Width, area.Height);
            if (bitmap == 0) throw CaptureError();
            previous = Native.SelectObject(memory, bitmap);
            if (previous == 0 || previous == new nint(-1)) throw CaptureError();
            // CAPTUREBLT includes ordinary layered desktop windows; protected content remains protected.
            if (!Native.BitBlt(memory, 0, 0, area.Width, area.Height, screen, area.X, area.Y, 0x40CC0020))
                throw CaptureError();
            BitmapSource result = Imaging.CreateBitmapSourceFromHBitmap(bitmap, 0, Int32Rect.Empty,
                BitmapSizeOptions.FromEmptyOptions());
            result.Freeze();
            return result;
        }
        finally
        {
            if (previous != 0 && previous != new nint(-1) && memory != 0) Native.SelectObject(memory, previous);
            if (bitmap != 0) Native.DeleteObject(bitmap);
            if (memory != 0) Native.DeleteDC(memory);
            if (screen != 0) Native.ReleaseDC(0, screen);
        }
    }

    public static BitmapSource CaptureWindow(WindowTarget target)
    {
        if (!Native.IsWindow(target.Handle))
            throw new InvalidOperationException(L.T("desktop.closed"));
        if (Native.IsIconic(target.Handle)) Native.ShowWindow(target.Handle, 9);
        bool foreground = Native.SetForegroundWindow(target.Handle);
        if (!foreground && Native.GetForegroundWindow() != target.Handle)
            throw new InvalidOperationException(L.T("desktop.activation"));
        Native.DwmFlush();
        Thread.Sleep(180); // Allow restored hardware-composited windows to repaint before reading the desktop.
        DesktopArea window = GetWindowBounds(target.Handle);
        DesktopArea desktop = VirtualBounds;
        int left = Math.Max(window.X, desktop.X), top = Math.Max(window.Y, desktop.Y);
        int right = (int)Math.Min((long)window.X + window.Width, (long)desktop.X + desktop.Width);
        int bottom = (int)Math.Min((long)window.Y + window.Height, (long)desktop.Y + desktop.Height);
        if (right <= left || bottom <= top)
            throw new InvalidOperationException(L.T("desktop.offscreen"));
        return Capture(new DesktopArea(left, top, right - left, bottom - top));
    }

    private static Win32Exception CaptureError() => new(Marshal.GetLastWin32Error(),
        L.T("desktop.failed"));

    private static class Native
    {
        [StructLayout(LayoutKind.Sequential)]
        internal struct Rect { public int Left, Top, Right, Bottom; }
        internal delegate bool EnumWindowsProc(nint handle, nint parameter);
        [DllImport("user32.dll")] internal static extern int GetSystemMetrics(int index);
        [DllImport("user32.dll")] internal static extern bool EnumWindows(EnumWindowsProc callback, nint parameter);
        [DllImport("user32.dll")] internal static extern bool IsWindowVisible(nint handle);
        [DllImport("user32.dll")] internal static extern bool IsWindow(nint handle);
        [DllImport("user32.dll")] internal static extern bool IsIconic(nint handle);
        [DllImport("user32.dll")] internal static extern nint GetWindow(nint handle, uint command);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] internal static extern nint GetWindowLongPtr(nint handle, int index);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern int GetWindowTextLength(nint handle);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern int GetWindowText(nint handle, StringBuilder text, int count);
        [DllImport("user32.dll")] internal static extern bool GetWindowRect(nint handle, out Rect rect);
        [DllImport("user32.dll")] internal static extern bool ShowWindow(nint handle, int command);
        [DllImport("user32.dll")] internal static extern bool SetForegroundWindow(nint handle);
        [DllImport("user32.dll")] internal static extern nint GetForegroundWindow();
        [DllImport("user32.dll", SetLastError = true)] internal static extern nint GetDC(nint window);
        [DllImport("user32.dll")] internal static extern int ReleaseDC(nint window, nint dc);
        [DllImport("gdi32.dll", SetLastError = true)] internal static extern nint CreateCompatibleDC(nint dc);
        [DllImport("gdi32.dll", SetLastError = true)] internal static extern nint CreateCompatibleBitmap(nint dc, int width, int height);
        [DllImport("gdi32.dll", SetLastError = true)] internal static extern nint SelectObject(nint dc, nint value);
        [DllImport("gdi32.dll", SetLastError = true)] internal static extern bool BitBlt(nint destination, int x, int y, int width, int height, nint source, int sourceX, int sourceY, uint operation);
        [DllImport("gdi32.dll")] internal static extern bool DeleteObject(nint value);
        [DllImport("gdi32.dll")] internal static extern bool DeleteDC(nint dc);
        [DllImport("dwmapi.dll")] internal static extern int DwmGetWindowAttribute(nint handle, int attribute, out Rect value, int size);
        [DllImport("dwmapi.dll")] internal static extern int DwmGetWindowAttribute(nint handle, int attribute, out int value, int size);
        [DllImport("dwmapi.dll")] internal static extern int DwmFlush();
    }
}
