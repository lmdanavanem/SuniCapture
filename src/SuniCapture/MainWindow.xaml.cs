using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;
using SuniCapture.Editor;
using SuniCapture.Models;
using SuniCapture.Services;
using SuniCapture.Windows;
using Forms = System.Windows.Forms;
using Drawing = System.Drawing;

namespace SuniCapture;

public partial class MainWindow : Window
{
    private readonly LibraryStore _store;
    private readonly ObservableCollection<CaptureItem> _items = new();
    private readonly DispatcherTimer _saveTimer = new() { Interval = TimeSpan.FromMilliseconds(800) };
    private readonly Dictionary<EditorTool, Button> _toolButtons = new();
    private ICollectionView? _view;
    private GlobalHotkeys? _hotkeys;
    private Forms.NotifyIcon? _tray;
    private Drawing.Icon? _trayIcon;
    private CaptureItem? _current;
    private bool _ready, _loadingCanvas, _busy, _quitting, _videoPlaying, _fit = true;
    private string _filter = "all";
    private double _zoom = 1;
    private VideoRecorder? _recorder;
    private Window? _recordingBar;
    private TextBlock? _recordingTime;
    private readonly Stopwatch _recordingWatch = new();
    private readonly DispatcherTimer _recordingTimer = new() { Interval = TimeSpan.FromSeconds(1) };
    private bool _stoppingRecording, _exitAfterRecording, _recordingRequested;
    private string? _lastRecordingFailure;
    private int _modalDepth;

    public MainWindow()
    {
        _store = new LibraryStore(App.DataRoot);
        L.SetLanguage(_store.Settings.Language);
        InitializeComponent();
        Language = System.Windows.Markup.XmlLanguage.GetLanguage(L.Culture.IetfLanguageTag);
        LanguageLabel.Text = L.Language.ToUpperInvariant();
        VersionLabel.Text = AppVersion;
        AnnotationTextBox.Text = L.T("edit.defaultText");
        Width = _store.Settings.WindowWidth;
        Height = _store.Settings.WindowHeight;
        ApplyTheme();
        foreach (ComboBoxItem option in DelayBox.Items)
            if ((string)option.Tag == _store.Settings.CaptureDelay.ToString(CultureInfo.InvariantCulture)) DelayBox.SelectedItem = option;
        CreateToolButtons();
        CreateColors();
        Canvas.Tool = EditorTool.Arrow;
        SetTool(EditorTool.Arrow);
        Canvas.TextValue = AnnotationTextBox.Text;
        Canvas.FontSize = FontSlider.Value;
        foreach (var item in _store.Items.OrderByDescending(item => item.CreatedAt))
        {
            if (_items.Count < 120) _store.LoadThumbnail(item);
            _items.Add(item);
        }
        _view = CollectionViewSource.GetDefaultView(_items);
        _view.Filter = FilterItem;
        CaptureList.ItemsSource = _view;
        _saveTimer.Tick += (_, _) => { _saveTimer.Stop(); SaveCurrent(); };
        _recordingTimer.Tick += (_, _) => UpdateRecordingControls();
        RecordingAudioBox.IsChecked = _store.Settings.SystemAudio;
        _ready = true;
        UpdateFilters();
        RefreshLibrary();
        UpdateEditorControls();
        UpdateRecordingControls();
        Loaded += (_, _) =>
        {
            Icon = CreateIcon();
            if (!App.IsQa)
            {
                _hotkeys = new GlobalHotkeys(this);
                _hotkeys.Pressed += HandleHotkey;
                var warnings = _hotkeys.Register();
                if (warnings.Count > 0) SetStatus(string.Join(" ", warnings));
                CreateTray();
            }
            if (_store.LoadWarning != null) SetStatus(_store.LoadWarning);
        };
        StateChanged += (_, _) =>
        {
            if (WindowState == WindowState.Minimized && _store.Settings.MinimizeToTray && _tray != null) Hide();
        };
    }

    private void CreateToolButtons()
    {
        var active = Canvas.Tool;
        ToolBar.Children.Clear();
        _toolButtons.Clear();
        var tools = new[]
        {
            (EditorTool.Select, "\uE8B0", L.T("tool.select"), "V"),
            (EditorTool.Arrow, "\uE72A", L.T("tool.arrow"), "A"),
            (EditorTool.Rectangle, "\uE739", L.T("tool.rectangle"), "R"),
            (EditorTool.Ellipse, "\uEA3A", L.T("tool.ellipse"), "O"),
            (EditorTool.Pen, "\uED63", L.T("tool.pen"), "P"),
            (EditorTool.Highlight, "\uE7E6", L.T("tool.highlight"), "H"),
            (EditorTool.Text, "\uE8D2", L.T("tool.text"), "T"),
            (EditorTool.Step, "\uE8FD", L.T("tool.step"), "N"),
            (EditorTool.Pixelate, "\uE72E", L.T("tool.redact"), "B"),
            (EditorTool.Crop, "\uE7A8", L.T("tool.crop"), "C")
        };
        foreach (var (tool, glyph, label, key) in tools)
        {
            var button = new Button
            {
                Content = new TextBlock { Text = glyph, FontFamily = new FontFamily("Segoe Fluent Icons"), FontSize = 18 },
                Width = 34, Padding = new Thickness(6), Margin = new Thickness(2, 0, 2, 0),
                ToolTip = tool == EditorTool.Pixelate ? L.T("tool.redactHint") : $"{label} ({key})", Tag = tool
            };
            System.Windows.Automation.AutomationProperties.SetName(button, label);
            button.Click += (_, _) => SetTool(tool);
            ToolBar.Children.Add(button);
            _toolButtons[tool] = button;
        }
        SetTool(active);
    }

    private void CreateColors()
    {
        foreach (var value in new[] { "#2563EB", "#DC2626", "#16A34A", "#F59E0B", "#8B5CF6", "#0F172A", "#FFFFFF", "#E11D48" })
        {
            var color = (Color)ColorConverter.ConvertFromString(value);
            var button = new Button { Width = 32, Height = 28, Margin = new Thickness(3), Padding = new Thickness(3), ToolTip = value };
            button.Content = new Border { Background = new SolidColorBrush(color), CornerRadius = new CornerRadius(4), Width = 20, Height = 17, BorderBrush = Brushes.LightGray, BorderThickness = new Thickness(0.5) };
            button.Click += (_, _) => { Canvas.InkColor = color; HexColorBox.Text = value; };
            ColorPalette.Children.Add(button);
        }
    }

    private void SetTool(EditorTool tool, string? label = null)
    {
        Canvas.Tool = tool;
        ToolNameLabel.Text = label ?? tool switch
        {
            EditorTool.Select => L.T("tool.select"), EditorTool.Arrow => L.T("tool.arrow"), EditorTool.Rectangle => L.T("tool.rectangle"), EditorTool.Ellipse => L.T("tool.ellipse"),
            EditorTool.Pen => L.T("tool.pen"), EditorTool.Highlight => L.T("tool.highlight"), EditorTool.Text => L.T("tool.text"), EditorTool.Step => L.T("tool.step"), EditorTool.Pixelate => L.T("tool.redact"), _ => L.T("tool.crop")
        };
        ToolHintLabel.Text = tool switch
        {
            EditorTool.Select => L.T("tool.selectHint"),
            EditorTool.Text => L.T("tool.textHint"),
            EditorTool.Step => L.T("tool.stepHint"),
            EditorTool.Pixelate => L.T("tool.redactionHint"),
            EditorTool.Crop => L.T("tool.cropHint"),
            EditorTool.Highlight => L.T("tool.highlightHint"),
            _ => L.T("tool.drawHint")
        };
        DrawingOptionsPanel.Visibility = tool is EditorTool.Select or EditorTool.Crop or EditorTool.Pixelate ? Visibility.Collapsed : Visibility.Visible;
        StrokeOptionsPanel.Visibility = tool is EditorTool.Text or EditorTool.Step ? Visibility.Collapsed : Visibility.Visible;
        TextOptionsPanel.Visibility = tool == EditorTool.Text ? Visibility.Visible : Visibility.Collapsed;
        foreach (var (kind, button) in _toolButtons)
        {
            button.SetResourceReference(BackgroundProperty, kind == tool ? "AccentSoftBrush" : "SurfaceBrush");
            button.SetResourceReference(BorderBrushProperty, kind == tool ? "AccentBrush" : "BorderBrush");
        }
    }

    private bool FilterItem(object value)
    {
        if (value is not CaptureItem item) return false;
        var search = SearchBox.Text.Trim();
        if (search.Length > 0 && !item.Name.Contains(search, StringComparison.CurrentCultureIgnoreCase)) return false;
        return _filter switch
        {
            "trash" => item.IsTrashed,
            "favorite" => !item.IsTrashed && item.Favorite,
            "video" => !item.IsTrashed && item.IsVideo,
            _ => !item.IsTrashed
        };
    }

    private void RefreshLibrary()
    {
        _view?.Refresh();
        CountLabel.Text = _items.Count(item => !item.IsTrashed).ToString(CultureInfo.InvariantCulture);
        EmptyLibraryLabel.Visibility = _view?.IsEmpty == false ? Visibility.Collapsed : Visibility.Visible;
        EmptyLibraryLabel.Text = SearchBox.Text.Length > 0 ? L.T("library.noMatch") : _filter == "trash" ? L.T("library.emptyTrash") : _filter == "video" ? L.T("library.emptyVideo") : L.T("library.empty");
    }

    private void UpdateFilters()
    {
        foreach (var (button, name) in new[] { (AllFilterButton, "all"), (FavoriteFilterButton, "favorite"), (VideoFilterButton, "video"), (TrashFilterButton, "trash") })
            button.SetResourceReference(BackgroundProperty, name == _filter && RecorderView.Visibility != Visibility.Visible ? "AccentSoftBrush" : "SurfaceBrush");
        LibrarySectionLabel.Text = _filter switch { "favorite" => L.T("library.yourFavorites"), "video" => L.T("library.yourRecordings"), "trash" => L.T("library.toRestore"), _ => L.T("library.recent") };
        RecorderNavButton.SetResourceReference(BackgroundProperty, RecorderView.Visibility == Visibility.Visible ? "AccentSoftBrush" : "SurfaceBrush");
    }

    private void OnFilter(object sender, RoutedEventArgs e)
    {
        if (!SaveCurrent()) return;
        _filter = (string)((Button)sender).Tag;
        UpdateFilters();
        RefreshLibrary();
    }

    private void OnSearch(object sender, TextChangedEventArgs e) { if (_ready) RefreshLibrary(); }

    private void OnCaptureSelected(object sender, SelectionChangedEventArgs e)
    {
        if (!_ready || CaptureList.SelectedItem is not CaptureItem item || ReferenceEquals(item, _current)) return;
        if (!SaveCurrent()) { CaptureList.SelectedItem = _current; return; }
        OpenItem(item);
    }

    private void OpenItem(CaptureItem item)
    {
        try
        {
            Title = "SuniCapture";
            VideoPlayer.Stop();
            VideoPlayer.Source = null;
            _videoPlaying = false;
            if (item.IsVideo)
            {
                var path = _store.CurrentFile(item);
                if (!File.Exists(path)) throw new FileNotFoundException(L.T("video.missing"));
                _current = item;
                HomeView.Visibility = EditorView.Visibility = RecorderView.Visibility = Visibility.Collapsed;
                VideoView.Visibility = Visibility.Visible;
                VideoNameLabel.Text = item.Name;
                VideoInfoLabel.Text = L.F("video.info", item.DurationSeconds, item.CreatedAt.LocalDateTime);
                VideoPlayer.Source = new Uri(path);
                UpdateFilters();
                SetStatus(L.T("video.ready"));
                return;
            }
            var image = ImageExport.Load(_store.CurrentFile(item));
            _current = item;
            _loadingCanvas = true;
            Canvas.Image = image;
            _loadingCanvas = false;
            HomeView.Visibility = VideoView.Visibility = RecorderView.Visibility = Visibility.Collapsed;
            EditorView.Visibility = Visibility.Visible;
            _fit = true;
            UpdateItemLabels();
            UpdateEditorControls();
            UpdateFilters();
            Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(FitCanvas));
            SetStatus(item.IsTrashed ? L.T("status.trashed") : L.T("status.imageOpen"));
        }
        catch (Exception error) { _loadingCanvas = false; Error(L.T("error.openCapture"), error); }
    }

    private void UpdateItemLabels()
    {
        if (_current == null) return;
        ImageNameLabel.Text = _current.Name;
        ImageSourceLabel.Text = L.F("library.sourceDate", L.TranslateSource(_current.Source), _current.CreatedAt.LocalDateTime);
        FavoriteButton.Content = _current.Favorite ? "★" : "☆";
        FavoriteButton.ToolTip = _current.Favorite ? L.T("favorite.remove") : L.T("favorite.add");
        TrashButton.Content = _current.IsTrashed ? L.T("action.restore") : L.T("library.trash");
        VideoNameLabel.Text = _current.Name;
    }

    private void AddImage(BitmapSource image, string source, string? name = null)
    {
        if (!SaveCurrent()) return;
        var item = _store.AddImage(image, source, name);
        _items.Insert(0, item);
        _filter = "all";
        SearchBox.Clear();
        UpdateFilters();
        RefreshLibrary();
        CaptureList.SelectedItem = item;
        CaptureList.ScrollIntoView(item);
        if (!ReferenceEquals(_current, item)) OpenItem(item);
        if (_store.Settings.CopyAfterCapture && !App.IsQa)
        {
            try { Clipboard.SetImage(image); } catch (ExternalException) { SetStatus(L.T("status.clipboardBusy")); }
        }
    }

    private async void CaptureAsync(int mode)
    {
        if (_busy || _recorder?.IsRecording == true || !SaveCurrent()) return;
        WindowTarget? target = null;
        if (mode == 3)
        {
            target = PickWindow();
            if (target == null) return;
        }
        _busy = true;
        try
        {
            Hide();
            var delay = _store.Settings.CaptureDelay;
            if (delay > 0) await Countdown(delay);
            await System.Threading.Tasks.Task.Delay(200);
            BitmapSource? bitmap;
            if (mode == 1) bitmap = RegionSelectorWindow.Select()?.Bitmap;
            else if (mode == 2) bitmap = DesktopCapture.CaptureVirtualDesktop();
            else bitmap = DesktopCapture.CaptureWindow(target!);
            if (bitmap != null) AddImage(bitmap, mode == 1 ? L.T("source.region") : mode == 2 ? L.T("source.desktop") : L.T("capture.window"));
            else SetStatus(L.T("status.cancelled"));
        }
        catch (Exception error) { Error(L.T("error.capture"), error); }
        finally { _busy = false; ShowMain(); }
    }

    private async System.Threading.Tasks.Task Countdown(int seconds)
    {
        var label = new TextBlock { FontSize = 44, Foreground = Brushes.White, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        var counter = new Window { Width = 100, Height = 100, WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize, AllowsTransparency = true, Background = Brushes.Transparent, Topmost = true, ShowInTaskbar = false, WindowStartupLocation = WindowStartupLocation.CenterScreen, Content = new Border { Background = new SolidColorBrush(Color.FromArgb(230, 15, 23, 42)), CornerRadius = new CornerRadius(20), Child = label } };
        try
        {
            counter.Show();
            for (var remaining = seconds; remaining > 0; remaining--)
            {
                label.Text = remaining.ToString(CultureInfo.InvariantCulture);
                await System.Threading.Tasks.Task.Delay(1000);
            }
        }
        finally { counter.Close(); }
    }

    private WindowTarget? PickWindow()
    {
        using var modal = EnterModal();
        var windows = DesktopCapture.GetWindows(new WindowInteropHelper(this).Handle);
        var dialog = NewDialog(L.T("capture.chooseWindow"), 560, 440);
        var panel = new DockPanel { Margin = new Thickness(22) };
        var description = new TextBlock { Text = L.T("capture.windowDescription"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 15) };
        DockPanel.SetDock(description, Dock.Top); panel.Children.Add(description);
        var confirm = new Button { Content = PrimaryLabel(L.T("capture.confirmWindow")), Style = (Style)FindResource("PrimaryButton"), Margin = new Thickness(0, 16, 0, 0), IsDefault = true };
        DockPanel.SetDock(confirm, Dock.Bottom); panel.Children.Add(confirm);
        var list = new ListBox { ItemsSource = windows, DisplayMemberPath = "Title", SelectedIndex = windows.Count > 0 ? 0 : -1 };
        panel.Children.Add(list);
        confirm.IsEnabled = windows.Count > 0;
        confirm.Click += (_, _) => { if (list.SelectedItem != null) dialog.DialogResult = true; };
        list.MouseDoubleClick += (_, _) => { if (list.SelectedItem != null) dialog.DialogResult = true; };
        dialog.Content = panel;
        return dialog.ShowDialog() == true ? (WindowTarget?)list.SelectedItem : null;
    }

    private void OnCaptureRegion(object sender, RoutedEventArgs e) => CaptureAsync(1);
    private void OnCaptureScreen(object sender, RoutedEventArgs e) => CaptureAsync(2);
    private void OnCaptureWindow(object sender, RoutedEventArgs e) => CaptureAsync(3);
    private void HandleHotkey(int number)
    {
        if (_busy || _modalDepth > 0) return;
        if (number == 4)
        {
            if (_recorder?.IsRecording == true) StopRecording();
            else { ShowRecordingWorkspace(); _ = StartRecordingAsync(); }
        }
        else { ShowMain(); CaptureAsync(number); }
    }

    public void ImportPaths(IEnumerable<string> paths)
    {
        if (_busy || !SaveCurrent()) return;
        var imported = 0;
        var errors = new List<string>();
        foreach (var path in paths)
        {
            try
            {
                var image = ImageExport.Load(path);
                AddImage(image, L.T("source.imported"), Path.GetFileNameWithoutExtension(path));
                imported++;
            }
            catch (Exception error) { errors.Add(Path.GetFileName(path) + " : " + error.Message); }
        }
        SetStatus(errors.Count == 0 ? L.F("import.count", imported) : L.F("import.partialCount", imported, errors.Count));
        if (errors.Count > 0) MessageBox.Show(this, string.Join("\n", errors.Take(8)), L.T("import.incomplete"), MessageBoxButton.OK, MessageBoxImage.Warning);
    }

    private void OnImport(object sender, RoutedEventArgs e)
    {
        using var modal = EnterModal();
        var dialog = new OpenFileDialog { Title = L.T("import.title"), Filter = L.T("import.filter"), Multiselect = true };
        if (dialog.ShowDialog(this) == true) ImportPaths(dialog.FileNames);
    }

    private void OnPaste(object sender, RoutedEventArgs e)
    {
        try
        {
            var image = Clipboard.GetImage();
            if (image == null) { SetStatus(L.T("status.noClipboard")); return; }
            image.Freeze();
            AddImage(image, L.T("source.clipboard"));
            SetStatus(L.T("status.pasted"));
        }
        catch (Exception error) { Error(L.T("error.paste"), error); }
    }

    private void OnFileDrop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is string[] paths) ImportPaths(paths);
        e.Handled = true;
    }
    private void OnDragOver(object sender, DragEventArgs e) { e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None; e.Handled = true; }

    private bool SaveCurrent(bool announce = false)
    {
        _saveTimer.Stop();
        if (_current == null || _current.IsVideo || Canvas.Image == null || !Canvas.IsDirty) return true;
        try
        {
            _store.SaveEdited(_current, Canvas.Render());
            Canvas.MarkClean();
            SetStatus(announce ? L.T("status.annotationsSaved") : L.T("status.localSaved"));
            return true;
        }
        catch (Exception error) { Error(L.T("error.saveAnnotations"), error); return false; }
    }

    private void OnCanvasChanged(object? sender, EventArgs e)
    {
        if (!_ready || _loadingCanvas) return;
        UpdateEditorControls();
        if (Canvas.IsDirty)
        {
            _saveTimer.Stop(); _saveTimer.Start();
            SetStatus(L.T("status.savingAnnotations"));
        }
        if (_fit) Dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(FitCanvas));
    }

    private void UpdateEditorControls()
    {
        UndoButton.IsEnabled = Canvas.CanUndo;
        RedoButton.IsEnabled = Canvas.CanRedo;
        SaveButton.IsEnabled = Canvas.IsDirty;
        if (Canvas.Image != null) ImageDimensionsLabel.Text = $"{Canvas.Image.PixelWidth:N0} × {Canvas.Image.PixelHeight:N0} px · {(Canvas.IsDirty ? L.T("status.saving") : L.T("status.saved"))}";
    }

    private void OnSave(object sender, RoutedEventArgs e) => SaveCurrent(true);
    private void OnUndo(object sender, RoutedEventArgs e) => Canvas.Undo();
    private void OnRedo(object sender, RoutedEventArgs e) => Canvas.Redo();
    private void OnCopy(object sender, RoutedEventArgs e)
    {
        if (Canvas.Image == null || _current?.IsVideo == true) return;
        try { Clipboard.SetImage(Canvas.Render()); SetStatus(L.T("status.copied")); }
        catch (Exception error) { Error(L.T("error.copy"), error); }
    }

    private void OnExport(object sender, RoutedEventArgs e)
    {
        if (Canvas.Image == null || _current == null || _current.IsVideo) return;
        using var modal = EnterModal();
        var dialog = new SaveFileDialog { Title = L.T("export.title"), FileName = SafeFileName(_current.Name) + ".png", Filter = L.T("export.filter"), AddExtension = true };
        if (dialog.ShowDialog(this) != true) return;
        try { ImageExport.Save(Canvas.Render(), dialog.FileName); SaveCurrent(); SetStatus(L.T("export.done") + Path.GetFileName(dialog.FileName)); }
        catch (Exception error) { Error(L.T("error.export"), error); }
    }

    private void OnRestoreOriginal(object sender, RoutedEventArgs e)
    {
        if (_current == null || _current.IsVideo) return;
        using var modal = EnterModal();
        if (MessageBox.Show(this, L.T("original.confirm"), L.T("edit.original"), MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
        var previousEdited = _current.EditedFile;
        var previousWidth = _current.Width;
        var previousHeight = _current.Height;
        try
        {
            _saveTimer.Stop();
            _loadingCanvas = true;
            var image = ImageExport.Load(_store.Resolve(_current.OriginalFile));
            _current.EditedFile = null;
            _current.Width = image.PixelWidth; _current.Height = image.PixelHeight;
            _store.Save();
            _store.LoadThumbnail(_current);
            Canvas.Image = image;
            _loadingCanvas = false;
            UpdateEditorControls();
            FitCanvas();
            SetStatus(L.T("original.done"));
        }
        catch (Exception error)
        {
            _current.EditedFile = previousEdited; _current.Width = previousWidth; _current.Height = previousHeight;
            _loadingCanvas = false; Error(L.T("error.original"), error);
        }
    }

    private void OnFavorite(object sender, RoutedEventArgs e)
    {
        if (_current == null) return;
        try { _current.Favorite = !_current.Favorite; _store.Save(); UpdateItemLabels(); RefreshLibrary(); SetStatus(_current.Favorite ? L.T("favorite.added") : L.T("favorite.removed")); }
        catch (Exception error) { Error(L.T("error.favorites"), error); }
    }

    private void OnRename(object sender, RoutedEventArgs e)
    {
        if (_current == null) return;
        using var modal = EnterModal();
        var dialog = NewDialog(L.T("rename.title"), 420, 205);
        var panel = new StackPanel { Margin = new Thickness(24) };
        var input = new TextBox { Text = _current.Name, MaxLength = 140, Margin = new Thickness(0, 0, 0, 18) };
        var button = new Button { Content = PrimaryLabel(L.T("rename.save")), IsDefault = true, Style = (Style)FindResource("PrimaryButton") };
        button.Click += (_, _) => { if (input.Text.Trim().Length > 0) dialog.DialogResult = true; };
        panel.Children.Add(input); panel.Children.Add(button); dialog.Content = panel;
        dialog.Loaded += (_, _) => { input.Focus(); input.SelectAll(); };
        if (dialog.ShowDialog() == true)
        {
            try { _current.Name = input.Text.Trim(); _store.Save(); UpdateItemLabels(); RefreshLibrary(); SetStatus(L.T("rename.done")); }
            catch (Exception error) { Error(L.T("rename.title"), error); }
        }
    }

    private void OnTrash(object sender, RoutedEventArgs e)
    {
        if (_current == null || !SaveCurrent()) return;
        try
        {
            _current.IsTrashed = !_current.IsTrashed;
            _current.TrashedAt = _current.IsTrashed ? DateTimeOffset.Now : null;
            _store.Save();
            var trashed = _current.IsTrashed;
            ShowHome(); RefreshLibrary();
            SetStatus(trashed ? L.T("trash.done") : L.T("trash.restored"));
        }
        catch (Exception error) { Error(L.T("error.move"), error); }
    }

    private void OnHome(object sender, RoutedEventArgs e) { if (SaveCurrent()) ShowHome(); }
    private void ShowHome()
    {
        Title = "SuniCapture";
        _current = null; CaptureList.SelectedItem = null;
        VideoPlayer.Stop(); VideoPlayer.Source = null; _videoPlaying = false;
        HomeView.Visibility = Visibility.Visible;
        EditorView.Visibility = VideoView.Visibility = RecorderView.Visibility = Visibility.Collapsed;
        _loadingCanvas = true; Canvas.Image = null; _loadingCanvas = false;
        UpdateFilters();
    }

    private void OnStrokeChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (!_ready) return;
        Canvas.StrokeWidth = StrokeSlider.Value;
        StrokeLabel.Text = $"{StrokeSlider.Value:0} px";
    }
    private void OnFontChanged(object sender, RoutedPropertyChangedEventArgs<double> e) { if (_ready) Canvas.FontSize = FontSlider.Value; }
    private void OnAnnotationTextChanged(object sender, TextChangedEventArgs e) { if (_ready) Canvas.TextValue = AnnotationTextBox.Text; }
    private void OnColorTyped(object sender, RoutedEventArgs e)
    {
        if (!_ready) return;
        try { Canvas.InkColor = (Color)ColorConverter.ConvertFromString(HexColorBox.Text.Trim()); }
        catch (FormatException) { HexColorBox.Text = Canvas.InkColor.ToString(); SetStatus(L.T("color.hint")); }
    }

    private void FitCanvas()
    {
        if (!_fit || Canvas.Image == null || EditorView.Visibility != Visibility.Visible) return;
        var width = Math.Max(10, CanvasScroll.ActualWidth - 76);
        var height = Math.Max(10, CanvasScroll.ActualHeight - 76);
        SetZoom(Math.Min(1, Math.Min(width / Canvas.Image.PixelWidth, height / Canvas.Image.PixelHeight)), false);
    }
    private void SetZoom(double zoom, bool manual = true)
    {
        if (manual) _fit = false;
        _zoom = Math.Clamp(zoom, 0.03, 6);
        CanvasScale.ScaleX = CanvasScale.ScaleY = _zoom;
        ZoomLabel.Text = $"{_zoom * 100:0} %";
    }
    private void OnFit(object sender, RoutedEventArgs e) { _fit = true; FitCanvas(); }
    private void OnZoomIn(object sender, RoutedEventArgs e) => SetZoom(_zoom * 1.25);
    private void OnZoomOut(object sender, RoutedEventArgs e) => SetZoom(_zoom / 1.25);
    private void OnCanvasSizeChanged(object sender, SizeChangedEventArgs e) { if (_ready && _fit) FitCanvas(); }

    private void OnDelayChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_ready || DelayBox.SelectedItem is not ComboBoxItem item) return;
        _store.Settings.CaptureDelay = int.Parse((string)item.Tag, CultureInfo.InvariantCulture);
        TrySaveSettings();
    }
    private void OnTheme(object sender, RoutedEventArgs e) { _store.Settings.DarkMode = !_store.Settings.DarkMode; ApplyTheme(); TrySaveSettings(); }

    private void ApplyTheme()
    {
        var dark = _store.Settings.DarkMode;
        var colors = new Dictionary<string, string>
        {
            ["ChromeBrush"] = dark ? "#191E2E" : "#F8FAFC", ["SurfaceBrush"] = dark ? "#22283A" : "#FFFFFF",
            ["BorderBrush"] = dark ? "#343C52" : "#E2E8F0", ["TextBrush"] = dark ? "#F1F5F9" : "#0F172A",
            ["MutedBrush"] = dark ? "#A5B4CA" : "#64748B", ["AccentSoftBrush"] = dark ? "#2C3C59" : "#E9EFFD",
            ["HoverBrush"] = dark ? "#2A3648" : "#EEF2F7", ["CanvasBrush"] = dark ? "#0B101A" : "#E5E7EB", ["GreenBrush"] = dark ? "#86EFAC" : "#15803D"
        };
        foreach (var (key, value) in colors) Application.Current.Resources[key] = new SolidColorBrush((Color)ColorConverter.ConvertFromString(value));
        ThemeButton.ToolTip = dark ? L.T("theme.light") : L.T("theme.dark");
        System.Windows.Automation.AutomationProperties.SetName(ThemeButton, (string)ThemeButton.ToolTip);
    }

    private void OnRecord(object sender, RoutedEventArgs e)
    {
        if (_recorder?.IsRecording == true) { StopRecording(); return; }
        ShowRecordingWorkspace();
    }

    private async System.Threading.Tasks.Task<bool> StartRecordingAsync()
    {
        if (_busy || _recorder?.IsRecording == true || _stoppingRecording || _modalDepth > 0 || !SaveCurrent()) return false;
        _busy = _recordingRequested = true;
        _lastRecordingFailure = null;
        UpdateRecordingControls();
        try
        {
            _store.Settings.SystemAudio = RecordingAudioBox.IsChecked == true; TrySaveSettings();
            Hide();
            await Countdown(Math.Max(3, _store.Settings.CaptureDelay));
            await System.Threading.Tasks.Task.Delay(200);
            _recorder?.Dispose();
            _recorder = new VideoRecorder();
            _recorder.Completed += OnRecordingCompleted;
            _recorder.Failed += OnRecordingFailed;
            var path = Path.Combine(_store.VideoDirectory, "recording-" + Guid.NewGuid().ToString("N") + ".mp4");
            _recordingWatch.Restart();
            _recorder.Start(path, _store.Settings.SystemAudio);
            if (!_recorder.IsRecording) return false;
            _stoppingRecording = false;
            ShowRecordingBar();
            _recordingTimer.Start();
            UpdateRecordingControls();
            SetStatus(L.T("record.running"));
            return true;
        }
        catch (Exception error) { _lastRecordingFailure = error.Message; FinishRecordingUi(); ShowMain(); Error(L.T("error.startVideo"), error); return false; }
        finally { _busy = _recordingRequested = false; UpdateRecordingControls(); }
    }

    private void ShowRecordingBar()
    {
        var bar = new Window { Title = L.T("record.barTitle"), Width = 285, Height = 58, WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize, ShowInTaskbar = false, Topmost = true, Background = new SolidColorBrush(Color.FromRgb(15, 23, 42)), Left = SystemParameters.WorkArea.Right - 305, Top = SystemParameters.WorkArea.Top + 22 };
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(17, 10, 14, 10) };
        panel.Children.Add(new System.Windows.Shapes.Ellipse { Fill = Brushes.OrangeRed, Width = 9, Height = 9, Margin = new Thickness(0, 0, 9, 0), VerticalAlignment = VerticalAlignment.Center });
        _recordingTime = new TextBlock { Text = "00:00", Foreground = Brushes.White, Width = 63, VerticalAlignment = VerticalAlignment.Center, FontSize = 17 };
        panel.Children.Add(_recordingTime);
        var stop = new Button { Content = new TextBlock { Text = L.T("record.stop"), Foreground = Brushes.Black }, Background = Brushes.White, Foreground = Brushes.Black, Padding = new Thickness(13, 6, 13, 6), Margin = new Thickness(8, 0, 0, 0) };
        stop.Click += (_, _) => { stop.IsEnabled = false; StopRecording(); };
        panel.Children.Add(stop); bar.Content = panel;
        bar.MouseLeftButtonDown += (_, _) => { if (Mouse.LeftButton == MouseButtonState.Pressed) bar.DragMove(); };
        bar.Closing += (_, args) => { if (_recorder?.IsRecording == true || _stoppingRecording) { args.Cancel = true; StopRecording(); } };
        _recordingBar = bar;
        bar.Show();
    }

    private void StopRecording()
    {
        if (_stoppingRecording || _recorder?.IsRecording != true) return;
        _stoppingRecording = true;
        if (_recordingTime != null) { _recordingTime.Text = L.T("record.finishing"); _recordingTime.FontSize = 14; }
        _recordingTimer.Stop();
        _recordingWatch.Stop();
        SetStatus(L.T("record.finalizing"));
        UpdateRecordingControls();
        try { _recorder.Stop(); }
        catch (Exception error) { OnRecordingFailed(error.Message); }
    }

    private void OnRecordingCompleted(string path)
    {
        Dispatcher.InvokeAsync(() =>
        {
            try
            {
                FinishRecordingUi();
                var item = _store.AddVideo(path, _recordingWatch.Elapsed.TotalSeconds);
                _items.Insert(0, item);
                _filter = "all"; SearchBox.Clear(); UpdateFilters(); RefreshLibrary();
                if (SaveCurrent()) CaptureList.SelectedItem = item;
                SetStatus(L.T("record.done"));
            }
            catch (Exception error) { Error(L.T("error.addVideo"), error); }
            finally { ShowMain(); if (_exitAfterRecording) { _quitting = true; Close(); } }
        });
    }

    private void OnRecordingFailed(string message)
    {
        Dispatcher.InvokeAsync(() =>
        {
            _lastRecordingFailure = message;
            FinishRecordingUi(); ShowMain();
            SetStatus(L.T("record.interrupted") + message);
            if (!App.IsQa) MessageBox.Show(this, message, L.T("record.failedTitle"), MessageBoxButton.OK, MessageBoxImage.Warning);
            _exitAfterRecording = false;
        });
    }

    private void FinishRecordingUi()
    {
        _recordingTimer.Stop(); _recordingWatch.Stop();
        _stoppingRecording = false;
        if (_recorder != null)
        {
            _recorder.Completed -= OnRecordingCompleted; _recorder.Failed -= OnRecordingFailed;
            _recorder.Dispose(); _recorder = null;
        }
        var bar = _recordingBar; _recordingBar = null; bar?.Close();
        _recordingTime = null;
        UpdateRecordingControls();
    }

    private void OnPlayVideo(object sender, RoutedEventArgs e)
    {
        if (VideoPlayer.Source == null) return;
        if (_videoPlaying) VideoPlayer.Pause(); else VideoPlayer.Play();
        _videoPlaying = !_videoPlaying;
    }
    private void OnVideoEnded(object sender, RoutedEventArgs e) { _videoPlaying = false; VideoPlayer.Stop(); }
    private void OnVideoFailed(object sender, ExceptionRoutedEventArgs e) => SetStatus(L.T("video.noPreview"));
    private void OnOpenVideo(object sender, RoutedEventArgs e) { if (_current?.IsVideo == true) OpenPath(_store.CurrentFile(_current)); }
    private void OnExportVideo(object sender, RoutedEventArgs e)
    {
        if (_current?.IsVideo != true) return;
        using var modal = EnterModal();
        var dialog = new SaveFileDialog { FileName = SafeFileName(_current.Name) + ".mp4", Filter = L.T("video.filter"), Title = L.T("video.exportTitle") };
        if (dialog.ShowDialog(this) != true) return;
        try
        {
            if (!Path.GetFullPath(dialog.FileName).Equals(Path.GetFullPath(_store.CurrentFile(_current)), StringComparison.OrdinalIgnoreCase)) File.Copy(_store.CurrentFile(_current), dialog.FileName, true);
            SetStatus(L.T("video.exported") + Path.GetFileName(dialog.FileName));
        }
        catch (Exception error) { Error(L.T("error.exportVideo"), error); }
    }

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (!_ready || _busy) return;
        if (e.Key == Key.F1 && Keyboard.Modifiers == ModifierKeys.None) { OnHelp(this, new RoutedEventArgs()); e.Handled = true; return; }
        var ctrl = (Keyboard.Modifiers & ModifierKeys.Control) != 0;
        var textInput = Keyboard.FocusedElement is TextBox;
        if (ctrl)
        {
            if (e.Key == Key.O) OnImport(this, new RoutedEventArgs());
            else if (e.Key == Key.V && !textInput) OnPaste(this, new RoutedEventArgs());
            else if (e.Key == Key.N) CaptureAsync(1);
            else if (e.Key == Key.S) SaveCurrent(true);
            else if (e.Key == Key.E) { if (_current?.IsVideo == true) OnExportVideo(this, new RoutedEventArgs()); else OnExport(this, new RoutedEventArgs()); }
            else if (e.Key == Key.C && !textInput) OnCopy(this, new RoutedEventArgs());
            else if (e.Key == Key.Z && !textInput) Canvas.Undo();
            else if (e.Key == Key.Y && !textInput) Canvas.Redo();
            else return;
            e.Handled = true; return;
        }
        if (textInput || EditorView.Visibility != Visibility.Visible || Keyboard.Modifiers != ModifierKeys.None) return;
        EditorTool? tool = e.Key switch { Key.V => EditorTool.Select, Key.A => EditorTool.Arrow, Key.R => EditorTool.Rectangle, Key.O => EditorTool.Ellipse, Key.P => EditorTool.Pen, Key.H => EditorTool.Highlight, Key.T => EditorTool.Text, Key.N => EditorTool.Step, Key.B => EditorTool.Pixelate, Key.C => EditorTool.Crop, _ => null };
        if (tool != null) { SetTool(tool.Value); e.Handled = true; }
    }

    private BitmapSource CreateIcon()
    {
        var iconResource = Application.GetResourceStream(new Uri("pack://application:,,,/Brand/SuniCapture.ico"));
        using (var stream = iconResource.Stream)
        using (var icon = new Drawing.Icon(stream, new Drawing.Size(32, 32))) _trayIcon = (Drawing.Icon)icon.Clone();
        var pngResource = Application.GetResourceStream(new Uri("pack://application:,,,/Brand/sunicapture-icon.png"));
        using var pngStream = pngResource.Stream;
        var image = BitmapFrame.Create(pngStream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
        image.Freeze();
        return image;
    }

    private void CreateTray()
    {
        _tray = new Forms.NotifyIcon { Icon = _trayIcon, Text = L.T("tray.hint"), Visible = true };
        _tray.DoubleClick += (_, _) => Dispatcher.Invoke(ShowMain);
        UpdateTrayMenu();
    }

    private void UpdateTrayMenu()
    {
        if (_tray == null) return;
        _tray.Text = L.T("tray.hint");
        _tray.ContextMenuStrip?.Dispose();
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add(L.T("tray.open"), null, (_, _) => Dispatcher.Invoke(ShowMain));
        menu.Items.Add(L.T("capture.region"), null, (_, _) => Dispatcher.Invoke(() => CaptureAsync(1)));
        menu.Items.Add(L.T("tray.screen"), null, (_, _) => Dispatcher.Invoke(() => CaptureAsync(2)));
        menu.Items.Add(L.T("record.title"), null, (_, _) => Dispatcher.Invoke(ShowRecordingWorkspace));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add(L.T("settings.title"), null, (_, _) => Dispatcher.Invoke(() => { ShowMain(); OnSettings(this, new RoutedEventArgs()); }));
        menu.Items.Add(L.T("about.title"), null, (_, _) => Dispatcher.Invoke(() => { ShowMain(); OnAbout(this, new RoutedEventArgs()); }));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add(L.T("action.quit"), null, (_, _) => Dispatcher.Invoke(() => { _quitting = true; Close(); }));
        _tray.ContextMenuStrip = menu;
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        if (_recorder?.IsRecording == true || _stoppingRecording)
        {
            e.Cancel = true; _exitAfterRecording = true; StopRecording(); return;
        }
        if (!SaveCurrent()) { e.Cancel = true; return; }
        if (!_quitting && !App.IsQa && _store.Settings.MinimizeToTray && _tray != null)
        {
            e.Cancel = true; Hide(); SetStatus(L.T("tray.available")); return;
        }
        _store.Settings.WindowWidth = RestoreBounds.Width;
        _store.Settings.WindowHeight = RestoreBounds.Height;
        TrySaveSettings();
        _hotkeys?.Dispose();
        _tray?.Dispose(); _trayIcon?.Dispose();
        VideoPlayer.Close();
        _saveTimer.Stop(); _recordingTimer.Stop();
    }

    private void ShowMain() { if (!IsVisible) Show(); if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal; Activate(); }
    private void OnOpenFolder(object sender, RoutedEventArgs e) => OpenPath(_store.Root);
    private void OpenPath(string path) { try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); } catch (Exception error) { Error(L.T("error.openPath"), error); } }
    private void TrySaveSettings() { try { _store.SaveSettings(); } catch (Exception error) { Error(L.T("settings.save"), error); } }
    private void SetStatus(string text) => StatusLabel.Text = text;
    private void Error(string action, Exception error) => SetStatus(action + " : " + error.Message);
    private static string SafeFileName(string name) => string.Concat(name.Select(character => Path.GetInvalidFileNameChars().Contains(character) ? '_' : character)).Trim().TrimEnd('.');
    private Window NewDialog(string title, double width, double height) => new() { Owner = this, Title = title, Width = width, Height = height, MinWidth = width, MinHeight = height, ResizeMode = ResizeMode.NoResize, WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false };
    private static TextBlock PrimaryLabel(string text) => new() { Text = text, Foreground = Brushes.White };

    private IDisposable EnterModal() { _modalDepth++; DialogBackdrop.Visibility = Visibility.Visible; return new ModalScope(this); }
    private sealed class ModalScope : IDisposable
    {
        private MainWindow? _owner;
        public ModalScope(MainWindow owner) => _owner = owner;
        public void Dispose() { if (_owner != null) { _owner._modalDepth--; if (_owner._modalDepth == 0) _owner.DialogBackdrop.Visibility = Visibility.Collapsed; _owner = null; } }
    }

    public void SeedQaImage()
    {
        var fixture = Diagnostics.SmokeChecks.CreateFixture();
        AddImage(fixture, "Image synthétique de vérification", "Projet de démonstration");
        SetStatus("Mode de vérification · bibliothèque isolée · image synthétique.");
    }

}
