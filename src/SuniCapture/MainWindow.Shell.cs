using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using SuniCapture.Models;

namespace SuniCapture;

public partial class MainWindow
{
    internal static string AppVersion => typeof(App).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0]
        ?? typeof(App).Assembly.GetName().Version?.ToString(3) ?? "";

    private void OnLanguageMenu(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu { PlacementTarget = LanguageButton, Placement = PlacementMode.Bottom };
        foreach (var (code, name) in new[] { ("fr", "Français"), ("en", "English") })
        {
            var option = new MenuItem { Header = name, IsCheckable = true, IsChecked = L.Language == code };
            option.Click += (_, _) => ChangeLanguage(code);
            menu.Items.Add(option);
        }
        LanguageButton.ContextMenu = menu;
        menu.IsOpen = true;
    }

    private bool ChangeLanguage(string code)
    {
        code = L.Normalize(code);
        var previous = _store.Settings.Language;
        _store.Settings.Language = code;
        try { _store.SaveSettings(); }
        catch (Exception error) { _store.Settings.Language = previous; Error(L.T("settings.save"), error); return false; }
        RefreshLanguage();
        SetStatus(L.T("language.changed"));
        return true;
    }

    private void RefreshLanguage()
    {
        L.SetLanguage(_store.Settings.Language);
        Language = XmlLanguage.GetLanguage(L.Culture.IetfLanguageTag);
        LanguageLabel.Text = L.Language.ToUpperInvariant();
        CreateToolButtons();
        foreach (var item in _items) item.RefreshLanguage();
        UpdateFilters();
        RefreshLibrary();
        UpdateEditorControls();
        UpdateRecordingControls();
        if (_current != null)
        {
            UpdateItemLabels();
            if (_current.IsVideo) VideoInfoLabel.Text = L.F("video.info", _current.DurationSeconds, _current.CreatedAt.LocalDateTime);
        }
        Title = RecorderView.Visibility == Visibility.Visible ? L.T("record.workspaceTitle") : "SuniCapture";
        ApplyTheme();
        if (_tray != null) UpdateTrayMenu();
    }

    private void OnAbout(object sender, RoutedEventArgs e)
    {
        string? next;
        using (EnterModal())
        {
            var dialog = CreateAboutDialog();
            dialog.ShowDialog();
            next = dialog.Tag as string;
        }
        if (next == "settings") OnSettings(this, new RoutedEventArgs());
        else if (next == "help") OnHelp(this, new RoutedEventArgs());
    }

    private Window CreateAboutDialog()
    {
        var (dialog, body, footer) = CreateShellDialog("about.title", "\uE946", 740, 850);
        var logo = new Image { Source = new BitmapImage(new Uri("pack://application:,,,/Brand/sunicapture-logo.png")), Width = 170, Height = 152, Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Center };
        RenderOptions.SetBitmapScalingMode(logo, BitmapScalingMode.HighQuality);
        body.Children.Add(logo);
        var version = new Border { CornerRadius = new CornerRadius(10), Padding = new Thickness(15, 5, 15, 5), Margin = new Thickness(0, 7, 0, 14), HorizontalAlignment = HorizontalAlignment.Center, Child = new TextBlock { Text = L.F("about.version", AppVersion), FontSize = 14 } };
        version.SetResourceReference(BackgroundProperty, "AccentSoftBrush");
        body.Children.Add(version);
        var tagline = Label("about.tagline", 23, false, true);
        tagline.HorizontalAlignment = HorizontalAlignment.Center; tagline.TextAlignment = TextAlignment.Center;
        body.Children.Add(tagline);
        var subtitle = Label("about.subtitle", 14, true);
        subtitle.HorizontalAlignment = HorizontalAlignment.Center; subtitle.TextAlignment = TextAlignment.Center; subtitle.Margin = new Thickness(0, 10, 0, 14);
        body.Children.Add(subtitle);
        var badges = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 16) };
        foreach (var (key, glyph) in new[] { ("about.offline", "\uE704"), ("about.telemetry", "\uE890"), ("about.account", "\uE77B") })
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            row.Children.Add(Glyph(glyph, 17));
            var text = Label(key, 13); text.Margin = new Thickness(8, 0, 0, 0); row.Children.Add(text);
            var badge = Card(row, true); badge.CornerRadius = new CornerRadius(22); badge.Padding = new Thickness(14, 10, 14, 10); badge.Margin = new Thickness(4);
            badges.Children.Add(badge);
        }
        body.Children.Add(badges);
        var privacy = new Grid(); privacy.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(55) }); privacy.ColumnDefinitions.Add(new ColumnDefinition());
        var shield = Glyph("\uE73E", 32); shield.VerticalAlignment = VerticalAlignment.Center; privacy.Children.Add(shield);
        var privacyText = new StackPanel(); Grid.SetColumn(privacyText, 1);
        privacyText.Children.Add(Label("about.privacyTitle", 17, false, true));
        var detail = Label("about.privacy", 13); detail.Margin = new Thickness(0, 8, 0, 0); privacyText.Children.Add(detail);
        var note = Label("about.privacyNote", 12, true); note.Margin = new Thickness(0, 6, 0, 0); privacyText.Children.Add(note);
        privacy.Children.Add(privacyText); body.Children.Add(Card(privacy, true));
        Section(body, "about.storage");
        body.Children.Add(Label("about.storageHint", 13, true));
        var path = new TextBox { Text = _store.Root, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 10, 0, 10), FontSize = 12 };
        AutomationProperties.SetName(path, L.T("about.storage")); body.Children.Add(path);
        var folder = ActionButton("action.openFolder", (_, _) => OpenPath(_store.Root)); folder.HorizontalAlignment = HorizontalAlignment.Left; body.Children.Add(folder);
        Section(body, "settings.personalization");
        var preferences = new Grid(); preferences.ColumnDefinitions.Add(new ColumnDefinition()); preferences.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var summary = new TextBlock { Text = L.F("about.preferences", L.Language == "en" ? "English" : "Français", L.T(_store.Settings.DarkMode ? "theme.darkName" : "theme.lightName")), TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 15, 0) };
        preferences.Children.Add(summary);
        var configure = ActionButton("settings.open", (_, _) => { dialog.Tag = "settings"; dialog.Close(); }); Grid.SetColumn(configure, 1); preferences.Children.Add(configure);
        body.Children.Add(preferences);
        Section(body, "about.updates");
        body.Children.Add(Label("about.updateStatus", 13));
        var updates = Label("about.updateHint", 12, true); updates.Margin = new Thickness(0, 7, 0, 0); body.Children.Add(updates);
        Section(body, "about.credits");
        body.Children.Add(Label("about.developer", 13, false, true));
        var engine = Label("about.engine", 12, true); engine.Margin = new Thickness(0, 6, 0, 10); body.Children.Add(engine);
        var notices = ActionButton("about.licenses", (_, _) => OpenBundledDocument("THIRD-PARTY-NOTICES.md")); notices.HorizontalAlignment = HorizontalAlignment.Left; body.Children.Add(notices);
        var help = ActionButton("help.open", (_, _) => { dialog.Tag = "help"; dialog.Close(); }); DockPanel.SetDock(help, Dock.Left); footer.Children.Add(help);
        AddCloseButton(dialog, footer);
        return dialog;
    }

    private void OnSettings(object sender, RoutedEventArgs e)
    {
        using var modal = EnterModal();
        CreateSettingsDialog().ShowDialog();
    }

    private Window CreateSettingsDialog()
    {
        var (dialog, body, footer) = CreateShellDialog("settings.title", "\uE713", 690, 720);
        body.Children.Add(Label("settings.heading", 22, false, true));
        var intro = Label("settings.immediate", 13, true); intro.Margin = new Thickness(0, 8, 0, 0); body.Children.Add(intro);
        Section(body, "settings.personalization");
        var language = new ComboBox { MinWidth = 185 };
        language.Items.Add(new ComboBoxItem { Content = "Français", Tag = "fr" }); language.Items.Add(new ComboBoxItem { Content = "English", Tag = "en" });
        language.SelectedIndex = L.Language == "en" ? 1 : 0;
        AutomationProperties.SetName(language, L.T("language.label"));
        AddPreferenceRow(body, "language.label", language);
        var theme = new ComboBox { MinWidth = 185 };
        theme.Items.Add(new ComboBoxItem { Content = L.T("theme.lightName") }); theme.Items.Add(new ComboBoxItem { Content = L.T("theme.darkName") });
        theme.SelectedIndex = _store.Settings.DarkMode ? 1 : 0;
        AutomationProperties.SetName(theme, L.T("theme.label"));
        AddPreferenceRow(body, "theme.label", theme);
        Section(body, "settings.capture");
        var copy = PreferenceCheck("settings.copy", _store.Settings.CopyAfterCapture);
        var tray = PreferenceCheck("settings.tray", _store.Settings.MinimizeToTray);
        var audio = PreferenceCheck("settings.audio", _store.Settings.SystemAudio);
        body.Children.Add(copy); body.Children.Add(tray); body.Children.Add(audio);
        Section(body, "help.globalShortcuts");
        var shortcuts = Label("help.shortcutList", 12, true); shortcuts.LineHeight = 25; body.Children.Add(shortcuts);
        var hint = Label("settings.storageHint", 12, true); hint.Margin = new Thickness(0, 18, 0, 0); body.Children.Add(hint);
        var cancel = ActionButton("action.cancel", (_, _) => dialog.Close()); cancel.IsCancel = true; DockPanel.SetDock(cancel, Dock.Left); footer.Children.Add(cancel);
        var save = ActionButton("settings.save", (_, _) =>
        {
            var old = (_store.Settings.Language, _store.Settings.DarkMode, _store.Settings.CopyAfterCapture, _store.Settings.MinimizeToTray, _store.Settings.SystemAudio);
            _store.Settings.Language = (string)((ComboBoxItem)language.SelectedItem).Tag;
            _store.Settings.DarkMode = theme.SelectedIndex == 1;
            _store.Settings.CopyAfterCapture = copy.IsChecked == true;
            _store.Settings.MinimizeToTray = tray.IsChecked == true;
            _store.Settings.SystemAudio = audio.IsChecked == true;
            try { _store.SaveSettings(); }
            catch (Exception error)
            {
                (_store.Settings.Language, _store.Settings.DarkMode, _store.Settings.CopyAfterCapture, _store.Settings.MinimizeToTray, _store.Settings.SystemAudio) = old;
                Error(L.T("settings.save"), error);
                MessageBox.Show(dialog, L.T("settings.saveFailed") + "\n" + error.Message, L.T("settings.title"), MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            RefreshLanguage();
            RecordingAudioBox.IsChecked = _store.Settings.SystemAudio;
            SetStatus(L.T("settings.saved"));
            dialog.Close();
        }, true);
        save.IsDefault = true; DockPanel.SetDock(save, Dock.Right); footer.Children.Add(save);
        return dialog;
    }

    private void OnHelp(object sender, RoutedEventArgs e)
    {
        using var modal = EnterModal();
        CreateHelpDialog().ShowDialog();
    }

    private Window CreateHelpDialog()
    {
        var (dialog, body, footer) = CreateShellDialog("help.title", "\uE897", 720, 760);
        foreach (var (title, text) in new[] { ("help.captureTitle", "help.captureBody"), ("help.editTitle", "help.editBody"), ("help.videoTitle", "help.videoBody"), ("help.storageTitle", "help.storageBody") })
        {
            Section(body, title); body.Children.Add(Label(text, 13, true));
        }
        Section(body, "help.globalShortcuts");
        var shortcuts = Label("help.shortcutList", 13); shortcuts.LineHeight = 25; body.Children.Add(shortcuts);
        Section(body, "help.editorShortcuts");
        body.Children.Add(Label("help.editorShortcutList", 12, true));
        AddCloseButton(dialog, footer);
        return dialog;
    }

    private (Window Dialog, StackPanel Body, DockPanel Footer) CreateShellDialog(string titleKey, string icon, double width, double height)
    {
        var area = SystemParameters.WorkArea;
        var dialog = new Window { Owner = this, Title = L.T(titleKey), Width = Math.Min(width, area.Width - 32), Height = Math.Min(height, area.Height - 32), WindowStartupLocation = WindowStartupLocation.CenterOwner,
            ShowInTaskbar = false, ResizeMode = ResizeMode.NoResize, WindowStyle = WindowStyle.None, AllowsTransparency = true, Background = Brushes.Transparent, Icon = Icon, Language = Language };
        dialog.PreviewKeyDown += (_, args) =>
        {
            if (args.Key == Key.Escape && Keyboard.Modifiers == ModifierKeys.None)
            {
                args.Handled = true;
                dialog.Close();
            }
        };
        AutomationProperties.SetName(dialog, L.T(titleKey));
        var grid = new Grid(); grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); grid.RowDefinitions.Add(new RowDefinition()); grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var frame = new Border { CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(1), Child = grid, Margin = new Thickness(8), Padding = new Thickness(0, 0, 0, 1) };
        frame.SetResourceReference(BackgroundProperty, "SurfaceBrush"); frame.SetResourceReference(Border.BorderBrushProperty, "BorderBrush"); dialog.Content = frame;
        var header = new Grid { Margin = new Thickness(20, 14, 14, 14) }; header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(44) }); header.ColumnDefinitions.Add(new ColumnDefinition()); header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var iconBox = new Border { Background = (Brush)FindResource("AccentSoftBrush"), CornerRadius = new CornerRadius(8), Width = 34, Height = 34, HorizontalAlignment = HorizontalAlignment.Left, Child = Glyph(icon, 19) }; header.Children.Add(iconBox);
        var title = Label(titleKey, 21, false, true); title.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(title, 1); header.Children.Add(title);
        var close = new Button { Content = "×", FontSize = 23, Width = 34, Height = 34, Padding = new Thickness(0), Style = (Style)FindResource("QuietButton"), ToolTip = L.T("action.close"), IsCancel = true };
        AutomationProperties.SetName(close, L.T("action.close")); close.Click += (_, _) => dialog.Close(); Grid.SetColumn(close, 2); header.Children.Add(close);
        header.MouseLeftButtonDown += (_, args) => { if (args.OriginalSource is TextBlock && Mouse.LeftButton == MouseButtonState.Pressed) dialog.DragMove(); };
        var headerFrame = new Border { Child = header, BorderThickness = new Thickness(0, 0, 0, 1), CornerRadius = new CornerRadius(12, 12, 0, 0) }; headerFrame.SetResourceReference(BackgroundProperty, "ChromeBrush"); headerFrame.SetResourceReference(Border.BorderBrushProperty, "BorderBrush"); grid.Children.Add(headerFrame);
        var body = new StackPanel { Margin = new Thickness(26, 18, 26, 22) };
        var scroll = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled }; Grid.SetRow(scroll, 1); grid.Children.Add(scroll);
        var footer = new DockPanel { LastChildFill = false, Margin = new Thickness(20, 12, 20, 12) };
        var footerFrame = new Border { Child = footer, BorderThickness = new Thickness(0, 1, 0, 0), CornerRadius = new CornerRadius(0, 0, 12, 12) }; footerFrame.SetResourceReference(BackgroundProperty, "ChromeBrush"); footerFrame.SetResourceReference(Border.BorderBrushProperty, "BorderBrush"); Grid.SetRow(footerFrame, 2); grid.Children.Add(footerFrame);
        return (dialog, body, footer);
    }

    private TextBlock Label(string key, double size = 13, bool muted = false, bool bold = false)
    {
        var text = new TextBlock { Text = L.T(key), FontSize = size, TextWrapping = TextWrapping.Wrap, FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal, LineHeight = size * 1.55 };
        text.SetResourceReference(ForegroundProperty, muted ? "MutedBrush" : "TextBrush");
        return text;
    }
    private TextBlock Glyph(string glyph, double size) => new() { Text = glyph, FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontSize = size, Foreground = (Brush)FindResource("AccentBrush"), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private Border Card(UIElement content, bool accent = false)
    {
        var card = new Border { Child = content, Padding = new Thickness(18), CornerRadius = new CornerRadius(10), BorderThickness = new Thickness(1) };
        card.SetResourceReference(BackgroundProperty, accent ? "AccentSoftBrush" : "ChromeBrush"); card.SetResourceReference(Border.BorderBrushProperty, "BorderBrush"); return card;
    }
    private void Section(StackPanel body, string title)
    {
        var section = new Border { BorderThickness = new Thickness(0, 1, 0, 0), Margin = new Thickness(0, 20, 0, 10), Padding = new Thickness(0, 16, 0, 0), Child = Label(title, 17, false, true) };
        section.SetResourceReference(Border.BorderBrushProperty, "BorderBrush"); body.Children.Add(section);
    }
    private Button ActionButton(string key, RoutedEventHandler action, bool primary = false)
    {
        var button = new Button { Content = primary ? PrimaryLabel(L.T(key)) : L.T(key), Padding = new Thickness(15, 9, 15, 9) };
        if (primary) button.Style = (Style)FindResource("PrimaryButton");
        AutomationProperties.SetName(button, L.T(key)); button.Click += action; return button;
    }
    private void AddCloseButton(Window dialog, DockPanel footer)
    {
        var button = ActionButton("action.close", (_, _) => dialog.Close(), true); button.MinWidth = 110; button.IsCancel = true; button.IsDefault = true; DockPanel.SetDock(button, Dock.Right); footer.Children.Add(button);
    }
    private CheckBox PreferenceCheck(string key, bool value)
    {
        var checkbox = new CheckBox { Content = Label(key), IsChecked = value, Margin = new Thickness(0, 9, 0, 9) };
        AutomationProperties.SetName(checkbox, L.T(key));
        return checkbox;
    }
    private void AddPreferenceRow(StackPanel body, string key, Control control)
    {
        var grid = new Grid { Margin = new Thickness(0, 4, 0, 10) }; grid.ColumnDefinitions.Add(new ColumnDefinition()); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var label = Label(key); label.VerticalAlignment = VerticalAlignment.Center; grid.Children.Add(label); Grid.SetColumn(control, 1); grid.Children.Add(control); body.Children.Add(grid);
    }
    private void OpenBundledDocument(string name)
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        for (var level = 0; level < 7 && directory != null; level++, directory = directory.Parent)
        {
            var path = Path.Combine(directory.FullName, name);
            if (File.Exists(path)) { OpenPath(path); return; }
        }
        SetStatus(L.T("about.licensesMissing"));
    }
}
