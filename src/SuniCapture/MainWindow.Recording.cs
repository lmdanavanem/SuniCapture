using System;
using System.Windows;

namespace SuniCapture;

public partial class MainWindow
{
    private void OnOpenRecorder(object sender, RoutedEventArgs e) => ShowRecordingWorkspace();
    private async void OnStartRecording(object sender, RoutedEventArgs e) => await StartRecordingAsync();
    private void OnStopRecording(object sender, RoutedEventArgs e) => StopRecording();

    internal void ShowRecordingWorkspace()
    {
        if (_busy || !SaveCurrent()) return;
        ShowHome();
        HomeView.Visibility = Visibility.Collapsed;
        RecorderView.Visibility = Visibility.Visible;
        Title = L.T("record.workspaceTitle");
        RecordingAudioBox.IsChecked = _store.Settings.SystemAudio;
        if (_recorder?.IsRecording != true) _recordingWatch.Reset();
        UpdateRecordingControls();
        UpdateFilters();
        ShowMain();
        SetStatus(L.T("record.workspaceHint"));
    }

    private void UpdateRecordingControls()
    {
        var running = _recorder?.IsRecording == true;
        var preparing = _recordingRequested && _busy && !running;
        var elapsed = _recordingWatch.Elapsed.ToString(@"hh\:mm\:ss");
        if (_recordingTime != null && !_stoppingRecording) _recordingTime.Text = _recordingWatch.Elapsed.ToString(@"mm\:ss");
        RecordingElapsedLabel.Text = elapsed;
        RecordingStateLabel.Text = _stoppingRecording ? L.T("record.savingMp4") : running ? L.T("record.inProgress") : preparing ? L.T("record.preparing") : _lastRecordingFailure != null ? L.T("record.failed") : L.T("record.ready");
        RecordLabel.Text = _stoppingRecording ? L.T("record.finalizingShort") : running ? L.T("record.stopVideo") : L.T("record.title");
        RecordButton.IsEnabled = !_stoppingRecording && !_busy;
        StartRecordingButton.IsEnabled = !running && !_busy && !_stoppingRecording;
        StopRecordingButton.IsEnabled = running && !_stoppingRecording;
        RecordingAudioBox.IsEnabled = !running && !_busy && !_stoppingRecording;
        RecordingHelpLabel.Text = _lastRecordingFailure ?? (_stoppingRecording
            ? L.T("record.finalizingHelp")
            : running
                ? L.T("record.runningHelp")
                : L.F("record.countdownHelp", Math.Max(3, _store.Settings.CaptureDelay)));
    }

    private void OnRecordingAudioChanged(object sender, RoutedEventArgs e)
    {
        if (!_ready || _recorder?.IsRecording == true || _recordingRequested) return;
        _store.Settings.SystemAudio = RecordingAudioBox.IsChecked == true;
        TrySaveSettings();
    }

    private void OnShowRecordings(object sender, RoutedEventArgs e)
    {
        _filter = "video";
        SearchBox.Clear();
        UpdateFilters();
        RefreshLibrary();
        SetStatus(L.T("record.listHint"));
    }
}
