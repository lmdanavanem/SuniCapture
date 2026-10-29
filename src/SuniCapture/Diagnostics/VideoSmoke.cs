using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using SuniCapture.Services;

namespace SuniCapture.Diagnostics;

/// <summary>Records a fully covered primary display containing synthetic pixels only, without audio.</summary>
public static class VideoSmoke
{
    public static async Task<IReadOnlyList<string>> Run(string directory)
    {
        return await RunCovered(directory, async () =>
        {
            using var recorder = new VideoRecorder();
            var completion = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
            recorder.Completed += path => completion.TrySetResult(path);
            recorder.Failed += message => completion.TrySetException(new InvalidOperationException(message));
            recorder.Start(Path.Combine(directory, "screen-synthetic.mp4"), false);
            await Task.Delay(3500);
            recorder.Stop();
            var finished = await Task.WhenAny(completion.Task, Task.Delay(55000));
            if (finished != completion.Task) throw new TimeoutException("La vidéo de test n’a pas été finalisée.");
            var finalPath = await completion.Task;
            if (recorder.IsRecording) throw new InvalidOperationException("Le moteur reste actif après finalisation.");
            return finalPath;
        });
    }

    public static Task<IReadOnlyList<string>> RunWorkflow(string directory, Func<Task<string>> recordFromUi) => RunCovered(directory, recordFromUi);

    private static async Task<IReadOnlyList<string>> RunCovered(string directory, Func<Task<string>> record)
    {
        Directory.CreateDirectory(directory);
        var checks = new List<string>();
        var area = System.Windows.Forms.Screen.PrimaryScreen!.Bounds;
        var image = new Image { Source = SmokeChecks.CreateFixture(), Stretch = Stretch.Fill };
        var cover = new Window
        {
            Title = "SuniCapture · Image synthétique de vérification", WindowStyle = WindowStyle.None,
            ResizeMode = ResizeMode.NoResize, ShowInTaskbar = false, Topmost = true,
            Background = Brushes.White, Content = image, Left = 0, Top = 0, Width = area.Width, Height = area.Height
        };
        cover.SourceInitialized += (_, _) => SetWindowPos(new WindowInteropHelper(cover).Handle, new nint(-1), area.X, area.Y, area.Width, area.Height, 0x0040);
        try
        {
            cover.Show();
            await cover.Dispatcher.InvokeAsync(() => cover.UpdateLayout(), DispatcherPriority.Render);
            await Task.Delay(350);
            // Assert coverage before recording; the task never starts on an uncovered display.
            GetWindowRect(new WindowInteropHelper(cover).Handle, out var visible);
            if (visible.Left != area.Left || visible.Top != area.Top || visible.Right != area.Right || visible.Bottom != area.Bottom)
                throw new InvalidOperationException("La fenêtre synthétique ne couvre pas exactement l’écran principal ; vidéo de test non démarrée.");
            checks.Add("Synthetic cover exactly fills the primary display before capture");
            var finalPath = await record();
            if (!File.Exists(finalPath) || new FileInfo(finalPath).Length < 1024) throw new InvalidDataException("MP4 absent ou trop court.");
            checks.Add("Primary display produces a finalized MP4 from the tested recording flow");
            cover.Hide();
            var player = new MediaPlayer();
            var opened = new TaskCompletionSource<bool>();
            player.MediaOpened += (_, _) => opened.TrySetResult(true);
            player.MediaFailed += (_, error) => opened.TrySetException(error.ErrorException);
            try
            {
                player.Open(new Uri(finalPath));
                var ready = await Task.WhenAny(opened.Task, Task.Delay(10000));
                if (ready != opened.Task) throw new TimeoutException("Le lecteur Windows n’a pas ouvert la vidéo de test.");
                await opened.Task;
                if (!player.NaturalDuration.HasTimeSpan || player.NaturalDuration.TimeSpan.TotalSeconds < 1 || player.NaturalVideoWidth < 100)
                    throw new InvalidDataException("Durée ou dimensions MP4 invalides.");
                checks.Add($"Windows media decoder reads MP4: {player.NaturalVideoWidth}×{player.NaturalVideoHeight}, {player.NaturalDuration.TimeSpan.TotalSeconds:0.00}s");
            }
            finally { player.Close(); }
        }
        finally { cover.Close(); }
        return checks;
    }

    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern bool SetWindowPos(nint hwnd, nint after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(nint hwnd, out Rect rect);
}
