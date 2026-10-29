using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Globalization;
using System.Windows.Markup;
using System.Windows;
using System.Windows.Threading;

namespace SuniCapture;

public partial class App : Application
{
    private Mutex? _instanceMutex;
    public static string? DataRoot { get; private set; }
    public static bool IsQa { get; private set; }

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var dataIndex = Array.IndexOf(e.Args, "--data-dir");
        if (dataIndex >= 0 && dataIndex + 1 < e.Args.Length) DataRoot = Path.GetFullPath(e.Args[dataIndex + 1]);
        IsQa = e.Args.Contains("--qa") || e.Args.Contains("--self-test") || e.Args.Contains("--ui-self-test");
        if (IsQa && DataRoot == null) DataRoot = Path.Combine(Path.GetTempPath(), "SuniCapture-QA", Guid.NewGuid().ToString("N"));
        L.SetLanguage(L.ReadSavedLanguage(DataRoot));
        FrameworkElement.LanguageProperty.OverrideMetadata(typeof(FrameworkElement), new FrameworkPropertyMetadata(XmlLanguage.GetLanguage(L.Culture.IetfLanguageTag)));
        if (!IsQa)
        {
            _instanceMutex = new Mutex(true, "Local\\SuniCapture.Desktop.v1", out var isNew);
            if (!isNew)
            {
                MessageBox.Show(L.T("app.alreadyOpen"), "SuniCapture", MessageBoxButton.OK, MessageBoxImage.Information);
                Shutdown();
                return;
            }
        }
        DispatcherUnhandledException += OnUnhandled;
        if (e.Args.Contains("--self-test"))
        {
            var passed = Diagnostics.SmokeChecks.Run(DataRoot ?? Path.Combine(AppContext.BaseDirectory, "qa-data"));
            Shutdown(passed ? 0 : 1);
            return;
        }
        try
        {
            var window = new MainWindow();
            MainWindow = window;
            if (e.Args.Contains("--ui-self-test"))
            {
                window.Loaded += async (_, _) =>
                {
                    await System.Threading.Tasks.Task.Delay(250);
                    var passed = await window.RunUiChecks(DataRoot ?? Path.Combine(AppContext.BaseDirectory, "qa-data"));
                    Shutdown(passed ? 0 : 1);
                };
            }
            window.Show();
            var image = e.Args.FirstOrDefault(arg => !arg.StartsWith("--") && File.Exists(arg) && !Directory.Exists(arg));
            if (image != null && image != DataRoot) window.ImportPaths(new[] { image });
            if (e.Args.Contains("--qa")) window.SeedQaImage();
            if (e.Args.Contains("--record")) window.ShowRecordingWorkspace();
        }
        catch (Exception error)
        {
            MessageBox.Show(L.T("app.startFailed") + error.Message, "SuniCapture", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
        }
    }

    private void OnUnhandled(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        e.Handled = true;
        MessageBox.Show(L.T("app.actionFailed") + e.Exception.Message, "SuniCapture", MessageBoxButton.OK, MessageBoxImage.Warning);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _instanceMutex?.Dispose();
        base.OnExit(e);
    }
}
