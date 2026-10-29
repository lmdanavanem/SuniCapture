using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using SuniCapture.Editor;
using SuniCapture.Services;

namespace SuniCapture;

public partial class MainWindow
{
    private async Task<IReadOnlyList<string>> RunShellChecks(string directory)
    {
        var checks = new List<string>();
        void Require(bool value, string label) { if (!value) throw new InvalidOperationException(label); checks.Add(label); }
        static byte[] Pixels(BitmapSource bitmap)
        {
            var stride = (bitmap.PixelWidth * bitmap.Format.BitsPerPixel + 7) / 8;
            var buffer = new byte[stride * bitmap.PixelHeight]; bitmap.CopyPixels(buffer, stride, 0); return SHA256.HashData(buffer);
        }
        static IEnumerable<T> Descendants<T>(DependencyObject node) where T : DependencyObject
        {
            for (int i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++)
            {
                var child = VisualTreeHelper.GetChild(node, i);
                if (child is T result) yield return result;
                foreach (var nested in Descendants<T>(child)) yield return nested;
            }
        }
        void Snapshot(Window window, string name)
        {
            window.UpdateLayout();
            var root = (FrameworkElement)window.Content;
            var bitmap = new RenderTargetBitmap((int)Math.Ceiling(root.ActualWidth), (int)Math.Ceiling(root.ActualHeight), 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(root); ImageExport.Save(bitmap, Path.Combine(directory, name));
        }
        void VerifyDialog(Window dialog, string file, Action<Window>? action = null)
        {
            Exception? failure = null;
            using (EnterModal())
            {
                dialog.Loaded += (_, _) => Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, new Action(() =>
                {
                    try
                    {
                        Require(_modalDepth > 0 && DialogBackdrop.Visibility == Visibility.Visible, file + ": dialog blocks capture shortcuts and dims owner");
                        HandleHotkey(4);
                        Require(_recorder == null && !_recordingRequested, file + ": global recording shortcut cannot start behind modal");
                        Snapshot(dialog, file);
                        var close = Descendants<Button>(dialog).FirstOrDefault(button => button.IsCancel);
                        Require(close != null && close.ActualHeight > 0 && dialog.ActualHeight <= SystemParameters.WorkArea.Height, file + ": close action and dialog fit work area");
                        Require(Descendants<ScrollViewer>(dialog).Any(scroll => scroll.ActualHeight > 100), file + ": long content scrolls above a fixed footer");
                        action?.Invoke(dialog);
                    }
                    catch (Exception error) { failure = error; }
                    finally { dialog.Close(); }
                }));
                dialog.ShowDialog();
            }
            if (failure != null) throw failure;
            Require(_modalDepth == 0 && DialogBackdrop.Visibility == Visibility.Collapsed, file + ": closing restores owner interaction");
        }

        var item = _current ?? throw new InvalidOperationException("Language QA requires an open capture.");
        var name = item.Name;
        var originalHash = SHA256.HashData(File.ReadAllBytes(_store.Resolve(item.OriginalFile)));
        var image = Canvas.Image;
        var previousText = AnnotationTextBox.Text;
        Canvas.AddShape(EditorTool.Rectangle, new Point(35, 35), new Point(130, 95));
        _saveTimer.Stop();
        var hash = Pixels(Canvas.Render());
        SetTool(EditorTool.Highlight);
        AnnotationTextBox.Text = "Texte personnalisé / custom text";
        Require(ChangeLanguage("en"), "Header language change saves English preference");
        Require(ReferenceEquals(_current, item) && ReferenceEquals(Canvas.Image, image) && Canvas.IsDirty && Canvas.Tool == EditorTool.Highlight && hash.SequenceEqual(Pixels(Canvas.Render())), "Live language change preserves open image, unsaved drawings, active tool and rendered pixels");
        Require(AnnotationTextBox.Text == "Texte personnalisé / custom text" && item.Name == name, "Language changes preserve user-entered annotation text and capture names");
        Require(new LibraryStore(_store.Root).Settings.Language == "en" && L.ReadSavedLanguage(_store.Root) == "en", "English preference survives storage reload and startup language read");
        await Dispatcher.InvokeAsync(UpdateLayout, DispatcherPriority.ApplicationIdle);
        Require(LanguageLabel.Text == "EN" && AutomationProperties.GetName(SettingsButton) == "Preferences and shortcuts" && ToolNameLabel.Text == "Highlight", "Live English updates XAML bindings, accessibility names and tool properties");
        Require(Descendants<TextBlock>(CaptureButton).Any(label => label.Text == "Capture a region"), "Primary capture action is translated in the existing view");
        Require(item.Subtitle.StartsWith(item.CreatedAt.LocalDateTime.ToString("dd MMM · HH:mm", L.Culture)), "Library dates follow the selected locale across dispatcher callbacks");
        Snapshot(this, "editor-en-light.png");
        VerifyDialog(CreateAboutDialog(), "about-en-light.png");
        var previousSettings = (_store.Settings.Language, _store.Settings.DarkMode, _store.Settings.CopyAfterCapture);
        VerifyDialog(CreateSettingsDialog(), "preferences-en-light.png", dialog =>
        {
            var choices = Descendants<ComboBox>(dialog).ToArray(); choices[0].SelectedIndex = 0; choices[1].SelectedIndex = 1;
            Descendants<CheckBox>(dialog).First().IsChecked = !_store.Settings.CopyAfterCapture;
            Descendants<Button>(dialog).Single(button => AutomationProperties.GetName(button) == "Cancel").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        });
        Require(previousSettings == (_store.Settings.Language, _store.Settings.DarkMode, _store.Settings.CopyAfterCapture), "Cancelling preferences discards language, theme and capture-option changes");
        VerifyDialog(CreateHelpDialog(), "help-en-light.png");
        SaveCurrent(); ShowHome(); await Dispatcher.InvokeAsync(UpdateLayout, DispatcherPriority.ApplicationIdle); Snapshot(this, "home-en-light.png");
        ShowRecordingWorkspace(); await Dispatcher.InvokeAsync(UpdateLayout, DispatcherPriority.ApplicationIdle);
        Require(RecordLabel.Text == "Record screen" && RecordingStateLabel.Text == "Ready to record", "Recorder state and start action use English");
        Snapshot(this, "recorder-en-light.png");
        VerifyDialog(CreateSettingsDialog(), "preferences-save-en.png", dialog =>
        {
            Descendants<ComboBox>(dialog).First().SelectedIndex = 0;
            Descendants<Button>(dialog).Single(button => AutomationProperties.GetName(button) == "Save preferences").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        });
        Require(L.Language == "fr" && new LibraryStore(_store.Root).Settings.Language == "fr", "Saving preferences applies and persists French without restarting");
        Width = 1100; Height = 700;
        _store.Settings.DarkMode = true; ApplyTheme();
        VerifyDialog(CreateAboutDialog(), "about-fr-dark-compact.png");
        VerifyDialog(CreateSettingsDialog(), "preferences-fr-dark-compact.png");
        VerifyDialog(CreateHelpDialog(), "help-fr-dark-compact.png");
        Require(ChangeLanguage("en"), "English can be selected while the dark theme is active");
        VerifyDialog(CreateAboutDialog(), "about-en-dark-compact.png");
        VerifyDialog(CreateSettingsDialog(), "preferences-en-dark-compact.png");
        ChangeLanguage("fr"); Width = 1440; Height = 940; _store.Settings.DarkMode = false; ApplyTheme();
        VerifyDialog(CreateAboutDialog(), "about-fr-light.png");
        VerifyDialog(CreateHelpDialog(), "help-escape-fr-light.png", dialog =>
        {
            dialog.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(dialog), 0, Key.Escape) { RoutedEvent = Keyboard.PreviewKeyDownEvent });
            Require(!dialog.IsVisible, "Escape closes a custom modal without changing application preferences");
        });
        ShowHome(); CaptureList.SelectedItem = item;
        AnnotationTextBox.Text = previousText;
        Require(originalHash.SequenceEqual(SHA256.HashData(File.ReadAllBytes(_store.Resolve(item.OriginalFile)))) && item.Name == name, "FR/EN dialogs and preference changes preserve original capture bytes and user metadata");
        Require(L.Normalize("unsupported") == "fr" && L.Normalize(null) == "fr", "Invalid or missing locale keeps French compatibility with older settings");
        return checks;
    }
}
