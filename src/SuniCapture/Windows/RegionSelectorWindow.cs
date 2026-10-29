using System;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using SuniCapture.Services;

namespace SuniCapture.Windows;

public sealed record RegionSelection(DesktopArea Area, BitmapSource Bitmap);

/// <summary>Opaque, snapshot-backed region picker. All selected bounds are physical pixels.</summary>
public sealed class RegionSelectorWindow : Window
{
    private readonly DesktopArea _desktop;
    private readonly BitmapSource _snapshot;
    private readonly SelectionSurface _surface;
    private RegionSelection? _selection;

    private RegionSelectorWindow(BitmapSource snapshot, DesktopArea desktop)
    {
        _snapshot = snapshot;
        _desktop = desktop;
        Title = L.T("region.title");
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.Manual;
        ShowInTaskbar = false;
        Topmost = true;
        Background = Brushes.Black;
        Cursor = Cursors.Cross;
        Left = 0; Top = 0; Width = 600; Height = 400;
        _surface = new SelectionSurface(this, snapshot, desktop);
        Content = _surface;
        SourceInitialized += (_, _) => PositionOnPhysicalDesktop();
        Loaded += (_, _) => { PositionOnPhysicalDesktop(); Activate(); Focus(); _surface.Focus(); };
        PreviewKeyDown += (_, args) =>
        {
            if (args.Key == Key.Escape) { args.Handled = true; DialogResult = false; }
            else if (args.Key == Key.Enter && _surface.SelectedArea is DesktopArea selected)
            {
                args.Handled = true;
                Complete(selected);
            }
        };
    }

    public static RegionSelection? Select()
    {
        // No overlay exists while reading the desktop: selection always reveals the frozen original.
        DesktopArea desktop = DesktopCapture.VirtualBounds;
        BitmapSource snapshot = DesktopCapture.Capture(desktop);
        var picker = new RegionSelectorWindow(snapshot, desktop);
        return picker.ShowDialog() == true ? picker._selection : null;
    }

    private void PositionOnPhysicalDesktop()
    {
        nint handle = new WindowInteropHelper(this).Handle;
        if (handle != 0 && !SetWindowPos(handle, new nint(-1), _desktop.X, _desktop.Y,
                _desktop.Width, _desktop.Height, 0x0040))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), L.T("region.displayFailed"));
    }

    private void Complete(DesktopArea area)
    {
        if (area.Width < 2 || area.Height < 2) return;
        var crop = new CroppedBitmap(_snapshot, new Int32Rect(area.X - _desktop.X,
            area.Y - _desktop.Y, area.Width, area.Height));
        crop.Freeze();
        _selection = new RegionSelection(area, crop);
        DialogResult = true;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(nint window, nint after, int x, int y, int width, int height, uint flags);

    private sealed class SelectionSurface : FrameworkElement
    {
        private readonly RegionSelectorWindow _window;
        private readonly BitmapSource _snapshot;
        private readonly DesktopArea _desktop;
        private Point? _start;
        private Point _end;
        private bool _dragging;
        private static readonly SolidColorBrush Shade = FrozenBrush(Color.FromArgb(130, 9, 15, 28));
        private static readonly SolidColorBrush Accent = FrozenBrush(Color.FromRgb(37, 99, 235));
        private static readonly SolidColorBrush Panel = FrozenBrush(Color.FromArgb(245, 15, 23, 42));

        internal SelectionSurface(RegionSelectorWindow window, BitmapSource snapshot, DesktopArea desktop)
        {
            _window = window; _snapshot = snapshot; _desktop = desktop;
            Focusable = true;
            ClipToBounds = true;
            MouseLeftButtonDown += Start;
            MouseMove += Move;
            MouseLeftButtonUp += Finish;
            LostMouseCapture += (_, _) => { if (_dragging) { _dragging = false; InvalidateVisual(); } };
        }

        internal DesktopArea? SelectedArea
        {
            get
            {
                if (_start is not Point start) return null;
                int left = (int)Math.Min(start.X, _end.X), top = (int)Math.Min(start.Y, _end.Y);
                int right = (int)Math.Max(start.X, _end.X), bottom = (int)Math.Max(start.Y, _end.Y);
                return right - left >= 2 && bottom - top >= 2
                    ? new DesktopArea(left, top, right - left, bottom - top) : null;
            }
        }

        private Point PhysicalPosition(MouseEventArgs args)
        {
            Point screen = PointToScreen(args.GetPosition(this));
            return new Point(Math.Clamp(Math.Round(screen.X), _desktop.X, (long)_desktop.X + _desktop.Width),
                Math.Clamp(Math.Round(screen.Y), _desktop.Y, (long)_desktop.Y + _desktop.Height));
        }

        private void Start(object sender, MouseButtonEventArgs args)
        {
            _start = PhysicalPosition(args);
            _end = _start.Value;
            _dragging = CaptureMouse();
            Focus();
            args.Handled = true;
            InvalidateVisual();
        }

        private void Move(object sender, MouseEventArgs args)
        {
            if (!_dragging) return;
            _end = PhysicalPosition(args);
            args.Handled = true;
            InvalidateVisual();
        }

        private void Finish(object sender, MouseButtonEventArgs args)
        {
            if (!_dragging) return;
            _end = PhysicalPosition(args);
            _dragging = false;
            ReleaseMouseCapture();
            args.Handled = true;
            InvalidateVisual();
            if (SelectedArea is DesktopArea selected) _window.Complete(selected);
        }

        protected override void OnRender(DrawingContext drawing)
        {
            base.OnRender(drawing);
            if (ActualWidth <= 0 || ActualHeight <= 0) return;
            var all = new Rect(0, 0, ActualWidth, ActualHeight);
            drawing.DrawImage(_snapshot, all);
            Rect selected = Rect.Empty;
            if (SelectedArea is DesktopArea area)
            {
                Point topLeft = PointFromScreen(new Point(area.X, area.Y));
                Point bottomRight = PointFromScreen(new Point((long)area.X + area.Width, (long)area.Y + area.Height));
                selected = new Rect(topLeft, bottomRight);
                var outside = new CombinedGeometry(GeometryCombineMode.Exclude,
                    new RectangleGeometry(all), new RectangleGeometry(selected));
                drawing.DrawGeometry(Shade, null, outside);
                drawing.DrawRectangle(null, new Pen(Accent, 2), selected);
                DrawHandle(drawing, selected.TopLeft);
                DrawHandle(drawing, selected.TopRight);
                DrawHandle(drawing, selected.BottomLeft);
                DrawHandle(drawing, selected.BottomRight);
                DrawLabel(drawing, $"{area.Width} × {area.Height} px", selected.Left,
                    selected.Bottom + 12, Math.Max(0, selected.Top - 38));
            }
            else drawing.DrawRectangle(Shade, null, all);

            // Use the physical screen under the pointer, so instructions stay visible in multi-monitor layouts.
            var cursor = System.Windows.Forms.Cursor.Position;
            var monitor = System.Windows.Forms.Screen.FromPoint(cursor).Bounds;
            Point panelPosition = PointFromScreen(new Point(monitor.Left + monitor.Width / 2.0, monitor.Top + 26));
            string instruction = L.T("region.instruction");
            FormattedText text = MakeText(instruction, 13);
            double width = text.Width + 36;
            var pill = new Rect(Math.Clamp(panelPosition.X - width / 2, 8, Math.Max(8, ActualWidth - width - 8)),
                Math.Clamp(panelPosition.Y, 8, Math.Max(8, ActualHeight - 48)), width, 38);
            drawing.DrawRoundedRectangle(Panel, null, pill, 8, 8);
            drawing.DrawText(text, new Point(pill.Left + 18, pill.Top + 10));
        }

        private void DrawLabel(DrawingContext drawing, string label, double x, double preferredY, double fallbackY)
        {
            FormattedText text = MakeText(label, 12);
            double width = text.Width + 20;
            double y = preferredY + 30 < ActualHeight ? preferredY : fallbackY;
            var rect = new Rect(Math.Clamp(x, 8, Math.Max(8, ActualWidth - width - 8)),
                Math.Clamp(y, 4, Math.Max(4, ActualHeight - 32)), width, 28);
            drawing.DrawRoundedRectangle(Panel, null, rect, 5, 5);
            drawing.DrawText(text, new Point(rect.Left + 10, rect.Top + 6));
        }

        private FormattedText MakeText(string text, double size) => new(text,
            CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
            new Typeface("Segoe UI"), size, Brushes.White, VisualTreeHelper.GetDpi(this).PixelsPerDip);

        private static void DrawHandle(DrawingContext drawing, Point point) =>
            drawing.DrawRectangle(Brushes.White, new Pen(Accent, 1), new Rect(point.X - 3, point.Y - 3, 6, 6));

        private static SolidColorBrush FrozenBrush(Color color)
        {
            var brush = new SolidColorBrush(color); brush.Freeze(); return brush;
        }
    }
}
