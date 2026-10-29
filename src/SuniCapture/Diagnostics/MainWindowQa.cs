using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using SuniCapture.Editor;
using SuniCapture.Services;

namespace SuniCapture;

public partial class MainWindow
{
    public async Task<bool> RunUiChecks(string outputRoot)
    {
        var directory = Path.Combine(outputRoot, "screenshots");
        Directory.CreateDirectory(directory);
        var checks = new List<string>();
        string? failure = null;
        void Require(bool value, string label) { if (!value) throw new InvalidOperationException(label); checks.Add(label); }
        async Task Snapshot(string name)
        {
            await Dispatcher.InvokeAsync(() => UpdateLayout(), DispatcherPriority.Render);
            var root = (FrameworkElement)Content;
            var bitmap = new RenderTargetBitmap((int)Math.Ceiling(root.ActualWidth), (int)Math.Ceiling(root.ActualHeight), 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(root);
            ImageExport.Save(bitmap, Path.Combine(directory, name));
        }
        try
        {
            WindowState = WindowState.Normal;
            _store.Settings.DarkMode = false; ApplyTheme(); ShowHome();
            await Snapshot("home-light.png");
            Require(HomeView.Visibility == Visibility.Visible, "Home renders with capture entry points");
            AddImage(Diagnostics.SmokeChecks.CreateFixture(), "Image synthétique de vérification", "Projet de démonstration");
            Require(_current != null && Canvas.Image?.PixelWidth == 1120 && EditorView.Visibility == Visibility.Visible, "New image opens in editor and library");
            SetTool(EditorTool.Arrow);
            Canvas.InkColor = Color.FromRgb(37, 99, 235);
            Canvas.AddShape(EditorTool.Arrow, new Point(700, 175), new Point(820, 285));
            Canvas.AddShape(EditorTool.Rectangle, new Point(248, 552), new Point(1080, 638));
            Canvas.AddShape(EditorTool.Step, new Point(1040, 408), new Point(1040, 408));
            Canvas.TextValue = "À vérifier";
            Canvas.FontSize = 25;
            Canvas.AddShape(EditorTool.Text, new Point(800, 370), new Point(800, 370));
            Require(Canvas.CanUndo && Canvas.IsDirty, "Drawing enables undo and marks pending save");
            Require(SaveCurrent() && !Canvas.IsDirty && _current?.EditedFile != null, "Editor autosave persists flattened annotations");
            FitCanvas();
            await Snapshot("editor-light.png");
            OnFavorite(this, new RoutedEventArgs());
            Require(_current!.Favorite, "Favorite action updates active capture");
            _filter = "favorite"; UpdateFilters(); RefreshLibrary();
            Require(_view?.Cast<object>().Count() == 1, "Favorites filter includes saved capture");
            SearchBox.Text = "introuvable";
            Require(_view?.IsEmpty == true, "Library search excludes nonmatching captures");
            SearchBox.Clear();
            _filter = "all"; UpdateFilters(); RefreshLibrary();
            var saved = _current!;
            OnTrash(this, new RoutedEventArgs());
            Require(saved.IsTrashed && HomeView.Visibility == Visibility.Visible, "Trash action returns home and preserves file");
            _filter = "trash"; UpdateFilters(); RefreshLibrary(); CaptureList.SelectedItem = saved;
            Require(_current == saved && TrashButton.Content?.ToString() == "Restaurer", "Trash view opens capture with restore action");
            OnTrash(this, new RoutedEventArgs());
            Require(!saved.IsTrashed, "Restore action returns capture to library");
            _filter = "all"; UpdateFilters(); RefreshLibrary(); CaptureList.SelectedItem = saved;
            _store.Settings.DarkMode = true; ApplyTheme(); SetTool(EditorTool.Pixelate);
            await Snapshot("editor-dark.png");
            Require(((SolidColorBrush)Application.Current.Resources["SurfaceBrush"]).Color == Color.FromRgb(34, 40, 58), "Dark theme applies SuniPDF surface token");
            var originalWidth = Canvas.Image!.PixelWidth;
            Canvas.Crop(new Rect(210, 75, 890, 610));
            Require(Canvas.Image.PixelWidth == 890, "Crop updates integrated canvas dimensions");
            Canvas.Undo();
            Require(Canvas.Image.PixelWidth == originalWidth, "Undo crop restores integrated canvas");
            SaveCurrent();
            Width = 1100; Height = 700;
            await Snapshot("editor-compact-dark.png");
            Require(ToolBar.ActualWidth > 0 && CanvasScroll.ActualWidth > 200, "Minimum window size keeps editor and toolbar visible");
            Width = 1440; Height = 940;
            _store.Settings.DarkMode = false; ApplyTheme();
            checks.AddRange(await RunShellChecks(directory));
            OnRecord(this, new RoutedEventArgs());
            Require(RecorderView.Visibility == Visibility.Visible && StartRecordingButton.IsEnabled, "Record screen toolbar opens dedicated workspace with working start action");
            Require(!StopRecordingButton.IsEnabled && RecordLabel.Text == "Enregistrer l’écran", "Idle recorder clearly distinguishes recording from image saving");
            RecordingAudioBox.IsChecked = false;
            await Snapshot("recorder-light.png");
            _store.Settings.DarkMode = true; ApplyTheme();
            await Snapshot("recorder-dark.png");
            checks.AddRange(await Diagnostics.VideoSmoke.RunWorkflow(Path.Combine(outputRoot, "video"), async () =>
            {
                var started = await StartRecordingAsync();
                Require(started && _recorder?.IsRecording == true && _recordingBar?.IsVisible == true, "Start recording action creates native session and floating stop control");
                Require(!StartRecordingButton.IsEnabled && StopRecordingButton.IsEnabled, "Running recorder disables duplicate start and enables stop");
                var completion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                _recorder!.Completed += _ => completion.TrySetResult(true);
                _recorder.Failed += message => completion.TrySetException(new InvalidOperationException(message));
                await Task.Delay(3500);
                OnStopRecording(this, new RoutedEventArgs());
                Require(_stoppingRecording && !StopRecordingButton.IsEnabled, "Stop action waits for MP4 finalization");
                if (await Task.WhenAny(completion.Task, Task.Delay(55000)) != completion.Task) throw new TimeoutException("Le parcours vidéo n’a pas été finalisé.");
                await completion.Task;
                await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
                Require(_recorder == null && _recordingBar == null && StartRecordingButton.IsEnabled, "Finished recording releases floating bar and restores start action");
                Require(_current?.IsVideo == true && VideoView.Visibility == Visibility.Visible, "Completed MP4 is indexed and opens in video preview");
                var finalPath = _store.CurrentFile(_current!);
                Require(File.Exists(finalPath) && _store.Items.Any(item => item.IsVideo && _store.CurrentFile(item) == finalPath), "Video remains accessible through persisted library path");
                return finalPath;
            }));
            await Snapshot("video-saved.png");
        }
        catch (Exception error) { failure = error.ToString(); }
        var report = new { success = failure == null, count = checks.Count, checks, failure, screenshots = directory, checkedAt = DateTimeOffset.Now };
        File.WriteAllText(Path.Combine(outputRoot, "ui-report.json"), JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));
        return failure == null;
    }
}
