using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace SuniCapture.Editor;

public enum EditorTool { Select, Arrow, Rectangle, Ellipse, Pen, Highlight, Text, Step, Pixelate, Crop }

/// <summary>Edits in image pixels; the hosting view controls display zoom independently.</summary>
public sealed class AnnotationCanvas : FrameworkElement
{
    private sealed record Annotation(EditorTool Kind, Point Start, Point End, Color Color,
        double Thickness, double TextSize, string Text, int Number, Point[] Points);
    private sealed record CanvasState(BitmapSource Bitmap, Annotation[] Annotations, int NextStep);

    private readonly List<CanvasState> _undo = new();
    private readonly List<CanvasState> _redo = new();
    private readonly List<Point> _points = new();
    private CanvasState? _state;
    private CanvasState? _cleanState;
    private BitmapSource? _original;
    private EditorTool _tool;
    private Point? _start;
    private Point _end;
    private bool _releasingCapture;

    public AnnotationCanvas()
    {
        Focusable = true;
        ClipToBounds = true;
        SnapsToDevicePixels = true;
        RenderOptions.SetBitmapScalingMode(this, BitmapScalingMode.HighQuality);
        SetBinding(ToolTipProperty, new Binding("[edit.canvasHint]") { Source = L.Current, Mode = BindingMode.OneWay });
    }

    public BitmapSource? Image
    {
        get => _state?.Bitmap;
        set
        {
            CancelGesture();
            _undo.Clear();
            _redo.Clear();
            _original = value;
            _state = value is null ? null : new CanvasState(value, Array.Empty<Annotation>(), 1);
            _cleanState = _state;
            UpdateSize();
            NotifyChanged();
        }
    }

    public EditorTool Tool
    {
        get => _tool;
        set
        {
            CancelGesture();
            _tool = value;
            Cursor = value == EditorTool.Select ? Cursors.Arrow : value == EditorTool.Text ? Cursors.IBeam : Cursors.Cross;
        }
    }

    public Color InkColor { get; set; } = Color.FromRgb(0x25, 0x63, 0xEB);
    public Color MaskColor { get; set; } = Color.FromRgb(0x0F, 0x17, 0x2A);
    public double StrokeWidth { get; set; } = 4;
    public string TextValue { get; set; } = "Texte";
    public double FontSize { get; set; } = 24;
    public bool CanUndo => _undo.Count > 0;
    public bool CanRedo => _redo.Count > 0;
    public bool IsDirty => !ReferenceEquals(_state, _cleanState);
    public int AnnotationCount => _state?.Annotations.Length ?? 0;
    public event EventHandler? Changed;

    /// <summary>Marks the current state as saved without clearing undo history.</summary>
    public void MarkClean()
    {
        _cleanState = _state;
        NotifyChanged();
    }

    public void Undo()
    {
        CancelGesture();
        if (_state is null || _undo.Count == 0) return;
        _redo.Add(_state);
        _state = Pop(_undo);
        UpdateSize();
        NotifyChanged();
    }

    public void Redo()
    {
        CancelGesture();
        if (_state is null || _redo.Count == 0) return;
        _undo.Add(_state);
        _state = Pop(_redo);
        UpdateSize();
        NotifyChanged();
    }

    /// <summary>Restores the initially opened image. This action itself can be undone.</summary>
    public void Reset()
    {
        CancelGesture();
        if (_original is null || _state is null ||
            (ReferenceEquals(_state.Bitmap, _original) && _state.Annotations.Length == 0)) return;
        Commit(new CanvasState(_original, Array.Empty<Annotation>(), 1));
    }

    public BitmapSource Render()
    {
        if (_state is null) throw new InvalidOperationException(L.T("edit.noImage"));
        return RenderState(_state);
    }

    /// <summary>Adds one shape using current tool properties, also usable by local diagnostics.</summary>
    public void AddShape(EditorTool kind, Point start, Point end)
    {
        if (_state is null) return;
        start = Clamp(start);
        end = Clamp(end);
        if (kind == EditorTool.Select) return;
        if (kind == EditorTool.Crop) { Crop(new Rect(start, end)); return; }
        if (kind == EditorTool.Text && string.IsNullOrWhiteSpace(TextValue)) return;
        var number = _state.NextStep;
        var annotation = new Annotation(kind, start, end,
            kind == EditorTool.Pixelate ? Opaque(MaskColor) : Opaque(InkColor),
            Math.Clamp(StrokeWidth, 1, 50), Math.Clamp(FontSize, 10, 200),
            TextValue ?? string.Empty, number,
            kind == EditorTool.Pen ? new[] { start, end } : Array.Empty<Point>());
        CommitAnnotation(annotation);
    }

    public void Crop(Rect selection)
    {
        if (_state is null || selection.IsEmpty) return;
        var bounds = new Rect(0, 0, _state.Bitmap.PixelWidth, _state.Bitmap.PixelHeight);
        selection.Intersect(bounds);
        if (selection.IsEmpty || selection.Width < 2 || selection.Height < 2) return;
        var x = Math.Clamp((int)Math.Floor(selection.X), 0, _state.Bitmap.PixelWidth - 1);
        var y = Math.Clamp((int)Math.Floor(selection.Y), 0, _state.Bitmap.PixelHeight - 1);
        var width = Math.Min((int)Math.Ceiling(selection.Right) - x, _state.Bitmap.PixelWidth - x);
        var height = Math.Min((int)Math.Ceiling(selection.Bottom) - y, _state.Bitmap.PixelHeight - y);
        if (width == _state.Bitmap.PixelWidth && height == _state.Bitmap.PixelHeight) return;
        // Flatten first: annotations and opaque masks retain exactly their visible position.
        var cropped = new CroppedBitmap(RenderState(_state), new Int32Rect(x, y, width, height));
        cropped.Freeze();
        Commit(new CanvasState(cropped, Array.Empty<Annotation>(), _state.NextStep));
    }

    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc);
        if (_state is null) return;
        DrawState(dc, _state);
        if (_start is not Point start) return;
        if (Tool == EditorTool.Crop)
        {
            var rect = new Rect(start, _end);
            var exclusion = new CombinedGeometry(GeometryCombineMode.Exclude,
                new RectangleGeometry(new Rect(0, 0, Width, Height)), new RectangleGeometry(rect));
            dc.DrawGeometry(new SolidColorBrush(Color.FromArgb(120, 15, 23, 42)), null, exclusion);
            var pen = new Pen(new SolidColorBrush(Color.FromRgb(37, 99, 235)), 2) { DashStyle = DashStyles.Dash };
            dc.DrawRectangle(null, pen, rect);
        }
        else
        {
            DrawAnnotation(dc, CreateGestureAnnotation(start));
        }
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonDown(e);
        if (_state is null || Tool == EditorTool.Select) return;
        Focus();
        var point = Clamp(e.GetPosition(this));
        if (Tool is EditorTool.Text or EditorTool.Step)
        {
            AddShape(Tool, point, point);
            e.Handled = true;
            return;
        }
        _start = point;
        _end = point;
        _points.Clear();
        _points.Add(point);
        CaptureMouse();
        e.Handled = true;
        InvalidateVisual();
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (_start is null) return;
        _end = Clamp(e.GetPosition(this));
        if (Tool == EditorTool.Pen && (_points.Count == 0 || (_end - _points[^1]).Length >= 0.75))
            _points.Add(_end);
        InvalidateVisual();
        e.Handled = true;
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonUp(e);
        if (_start is not Point start) return;
        _end = Clamp(e.GetPosition(this));
        var annotation = CreateGestureAnnotation(start);
        var selection = new Rect(start, _end);
        var tool = Tool;
        CancelGesture();
        if (tool == EditorTool.Crop) Crop(selection);
        else if ((annotation.End - annotation.Start).Length >= 2 ||
            (tool == EditorTool.Pen && annotation.Points.Length > 1)) CommitAnnotation(annotation);
        e.Handled = true;
    }

    protected override void OnLostMouseCapture(MouseEventArgs e)
    {
        base.OnLostMouseCapture(e);
        if (!_releasingCapture) CancelGesture();
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (e.Key == Key.Escape && _start is not null)
        {
            CancelGesture();
            e.Handled = true;
        }
        else if ((Keyboard.Modifiers & ModifierKeys.Control) != 0 && e.Key == Key.Z)
        {
            if ((Keyboard.Modifiers & ModifierKeys.Shift) != 0) Redo(); else Undo();
            e.Handled = true;
        }
        else if ((Keyboard.Modifiers & ModifierKeys.Control) != 0 && e.Key == Key.Y)
        {
            Redo();
            e.Handled = true;
        }
    }

    private Annotation CreateGestureAnnotation(Point start) => new(Tool, start, _end,
        Tool == EditorTool.Pixelate ? Opaque(MaskColor) : Opaque(InkColor),
        Math.Clamp(StrokeWidth, 1, 50), Math.Clamp(FontSize, 10, 200), TextValue ?? string.Empty, 0,
        Tool == EditorTool.Pen ? _points.ToArray() : Array.Empty<Point>());

    private void CommitAnnotation(Annotation annotation)
    {
        if (_state is null) return;
        var annotations = new Annotation[_state.Annotations.Length + 1];
        _state.Annotations.CopyTo(annotations, 0);
        annotations[^1] = annotation;
        Commit(new CanvasState(_state.Bitmap, annotations,
            _state.NextStep + (annotation.Kind == EditorTool.Step ? 1 : 0)));
    }

    private void Commit(CanvasState next)
    {
        if (_state is not null) _undo.Add(_state);
        _redo.Clear();
        _state = next;
        TrimHistory();
        UpdateSize();
        NotifyChanged();
    }

    private void TrimHistory()
    {
        // State snapshots share immutable bitmap/annotation references. Bound both gesture count
        // and distinct retained image pixels to avoid accumulating large cropped screenshots.
        while (_undo.Count > 60) _undo.RemoveAt(0);
        while (_undo.Count > 1)
        {
            var bitmaps = _undo.Select(s => s.Bitmap).Append(_state!.Bitmap).Distinct();
            var pixels = bitmaps.Sum(b => (long)b.PixelWidth * b.PixelHeight);
            if (pixels <= 128_000_000) break;
            _undo.RemoveAt(0);
        }
    }

    private void CancelGesture()
    {
        _start = null;
        _points.Clear();
        if (IsMouseCaptured)
        {
            _releasingCapture = true;
            ReleaseMouseCapture();
            _releasingCapture = false;
        }
        InvalidateVisual();
    }

    private void UpdateSize()
    {
        Width = _state?.Bitmap.PixelWidth ?? 0;
        Height = _state?.Bitmap.PixelHeight ?? 0;
        InvalidateMeasure();
    }

    private void NotifyChanged()
    {
        InvalidateVisual();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private Point Clamp(Point point) => _state is null ? new Point() : new Point(
        Math.Clamp(point.X, 0, _state.Bitmap.PixelWidth), Math.Clamp(point.Y, 0, _state.Bitmap.PixelHeight));

    private static CanvasState Pop(List<CanvasState> stack)
    {
        var result = stack[^1];
        stack.RemoveAt(stack.Count - 1);
        return result;
    }

    private static Color Opaque(Color value) => Color.FromRgb(value.R, value.G, value.B);

    private static BitmapSource RenderState(CanvasState state)
    {
        if ((long)state.Bitmap.PixelWidth * state.Bitmap.PixelHeight > 100_000_000)
            throw new InvalidOperationException(L.T("edit.imageLimit"));
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen()) DrawState(dc, state);
        var bitmap = new RenderTargetBitmap(state.Bitmap.PixelWidth, state.Bitmap.PixelHeight,
            96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        bitmap.Freeze();
        return bitmap;
    }

    private static void DrawState(DrawingContext dc, CanvasState state)
    {
        dc.PushClip(new RectangleGeometry(new Rect(0, 0, state.Bitmap.PixelWidth, state.Bitmap.PixelHeight)));
        dc.DrawImage(state.Bitmap, new Rect(0, 0, state.Bitmap.PixelWidth, state.Bitmap.PixelHeight));
        foreach (var annotation in state.Annotations) DrawAnnotation(dc, annotation);
        dc.Pop();
    }

    private static void DrawAnnotation(DrawingContext dc, Annotation a)
    {
        var brush = new SolidColorBrush(a.Color);
        var pen = new Pen(brush, a.Thickness)
        {
            StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round
        };
        var bounds = new Rect(a.Start, a.End);
        switch (a.Kind)
        {
            case EditorTool.Arrow:
                var vector = a.End - a.Start;
                if (vector.Length < 0.1) break;
                vector.Normalize();
                var headSize = Math.Min(Math.Max(13, a.Thickness * 3.5), (a.End - a.Start).Length * 0.65);
                var normal = new Vector(-vector.Y, vector.X);
                var headBase = a.End - vector * headSize;
                dc.DrawLine(pen, a.Start, a.End - vector * (headSize * 0.3));
                var head = new StreamGeometry();
                using (var g = head.Open())
                {
                    g.BeginFigure(a.End, true, true);
                    g.LineTo(headBase + normal * headSize * 0.45, true, false);
                    g.LineTo(headBase - normal * headSize * 0.45, true, false);
                }
                dc.DrawGeometry(brush, null, head);
                break;
            case EditorTool.Rectangle:
                dc.DrawRoundedRectangle(null, pen, bounds, 3, 3);
                break;
            case EditorTool.Ellipse:
                dc.DrawEllipse(null, pen, new Point(bounds.X + bounds.Width / 2, bounds.Y + bounds.Height / 2),
                    bounds.Width / 2, bounds.Height / 2);
                break;
            case EditorTool.Pen:
                if (a.Points.Length < 2) break;
                var path = new StreamGeometry();
                using (var g = path.Open())
                {
                    g.BeginFigure(a.Points[0], false, false);
                    g.PolyLineTo(a.Points.Skip(1).ToArray(), true, false);
                }
                dc.DrawGeometry(null, pen, path);
                break;
            case EditorTool.Highlight:
                dc.DrawRectangle(new SolidColorBrush(Color.FromArgb(85, a.Color.R, a.Color.G, a.Color.B)), null, bounds);
                break;
            case EditorTool.Pixelate:
                // Solid opaque redaction is intentional. Export contains no recoverable source pixels.
                dc.DrawRectangle(brush, null, bounds);
                break;
            case EditorTool.Text:
                if (string.IsNullOrWhiteSpace(a.Text)) break;
                var text = FormatText(a.Text, a.TextSize, brush);
                text.MaxTextWidth = 4000;
                dc.DrawRoundedRectangle(Brushes.White, null,
                    new Rect(a.Start.X - 7, a.Start.Y - 4, text.Width + 14, text.Height + 8), 4, 4);
                dc.DrawText(text, a.Start);
                break;
            case EditorTool.Step:
                var radius = Math.Max(17, a.TextSize * 0.7);
                dc.DrawEllipse(brush, new Pen(Brushes.White, Math.Max(2, radius * 0.12)), a.Start, radius, radius);
                var number = FormatText(a.Number.ToString(CultureInfo.InvariantCulture), radius * 1.13, Brushes.White);
                dc.DrawText(number, new Point(a.Start.X - number.Width / 2, a.Start.Y - number.Height / 2));
                break;
        }
    }

    private static FormattedText FormatText(string text, double size, Brush brush) => new(text,
        CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
        new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal),
        size, brush, 1.0);
}
