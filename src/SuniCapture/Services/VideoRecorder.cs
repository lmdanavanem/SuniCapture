using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.CompilerServices;
using System.Windows.Threading;
using ScreenRecorderLib;

namespace SuniCapture.Services;

/// <summary>
/// Records only the primary display. Create and call this object on the UI dispatcher.
/// IsRecording stays true during finalization; await Completed or Failed after Stop.
/// </summary>
public sealed class VideoRecorder : IDisposable
{
    private readonly Dispatcher _dispatcher = Dispatcher.CurrentDispatcher;
    private NativeSession? _session;
    private bool _disposed;

    public bool IsRecording => _session is not null;
    public event Action<string>? Completed;
    public event Action<string>? Failed;

    public void Start(string path, bool systemAudio)
    {
        _dispatcher.VerifyAccess();
        if (_session is not null)
        {
            Failed?.Invoke(L.T("engine.running"));
            return;
        }

        NativeSession? created = null;
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (string.IsNullOrWhiteSpace(path))
                throw new ArgumentException(L.T("engine.destination"));

            var destination = Path.GetFullPath(path);
            if (!string.Equals(Path.GetExtension(destination), ".mp4", StringComparison.OrdinalIgnoreCase))
                throw new ArgumentException(L.T("engine.extension"));
            if (File.Exists(destination))
                throw new IOException(L.T("engine.exists"));

            var directory = Path.GetDirectoryName(destination)!;
            Directory.CreateDirectory(directory);
            var partial = Path.Combine(directory,
                $".{Path.GetFileNameWithoutExtension(destination)}.{Guid.NewGuid():N}.partial.mp4");

            created = CreateNativeSession(destination, partial, systemAudio);
            _session = created;
            BeginRecording(created);
        }
        catch (Exception error)
        {
            _session = null;
            DisposeSafely(created);
            Failed?.Invoke(DescribeError(error));
        }
    }

    public void Stop()
    {
        _dispatcher.VerifyAccess();
        var session = _session;
        if (session is null || session.IsStopping)
            return;

        session.IsStopping = true;
        try
        {
            session.FinalizationTimeout = new DispatcherTimer(DispatcherPriority.Normal, _dispatcher)
            {
                Interval = TimeSpan.FromSeconds(45)
            };
            session.FinalizationTimeout.Tick += (_, _) => Finish(session,
                L.T("engine.timeout"));
            session.FinalizationTimeout.Start();
            // Stop requests asynchronous MP4 finalization; only the completion callback
            // can promote the temporary file to the destination requested by the user.
            StopNative(session);
        }
        catch (Exception error)
        {
            Finish(session, DescribeError(error));
        }
    }

    // Keep native-library loading inside a catchable call boundary. In particular,
    // a missing VC++ runtime must report Failed rather than crash the UI at JIT time.
    [MethodImpl(MethodImplOptions.NoInlining)]
    private NativeSession CreateNativeSession(string destination, string partial, bool systemAudio)
    {
        var primary = DisplayRecordingSource.MainMonitor;
        if (primary is null)
            throw new InvalidOperationException(L.T("engine.noDisplay"));

        var display = new DisplayRecordingSource(primary) { IsCursorCaptureEnabled = true };
        var audio = new AudioOptions
        {
            IsAudioEnabled = systemAudio,
            AudioSources = new List<AudioSourceBase>(),
            Bitrate = AudioBitrate.bitrate_128kbps,
            Channels = AudioChannels.Stereo
        };
        if (systemAudio)
            audio.AudioSources.Add(LoopbackAudioSource.Default);

        var options = new RecorderOptions
        {
            SourceOptions = new SourceOptions
            {
                RecordingSources = new List<RecordingSourceBase> { display }
            },
            OutputOptions = new OutputOptions { RecorderMode = RecorderMode.Video },
            AudioOptions = audio,
            MouseOptions = new MouseOptions
            {
                IsMousePointerEnabled = true,
                IsMouseClicksDetected = false
            },
            VideoEncoderOptions = new VideoEncoderOptions
            {
                Encoder = new H264VideoEncoder(),
                Framerate = 30,
                Bitrate = 6_000_000,
                IsFixedFramerate = true,
                IsHardwareEncodingEnabled = true,
                IsThrottlingDisabled = false,
                IsFragmentedMp4Enabled = false,
                IsMp4FastStartEnabled = true
            },
            SnapshotOptions = new SnapshotOptions { SnapshotsWithVideo = false },
            LogOptions = new LogOptions { IsLogEnabled = false }
        };

        var recorder = Recorder.CreateRecorder(options);
        var session = new NativeSession(recorder, destination, partial);
        session.CompletedHandler = (_, _) => Post(() => Finish(session, null));
        session.FailedHandler = (_, args) =>
        {
            var message = args.Error;
            Post(() => Finish(session, L.T("engine.failed") + message));
        };
        recorder.OnRecordingComplete += session.CompletedHandler;
        recorder.OnRecordingFailed += session.FailedHandler;
        return session;
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static void BeginRecording(NativeSession session) => session.Recorder.Record(session.PartialPath);

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static void StopNative(NativeSession session) => session.Recorder.Stop();

    private void Post(Action callback)
    {
        // Always queue: disposing a recorder inside its own native callback can deadlock.
        if (_dispatcher.HasShutdownStarted || _dispatcher.HasShutdownFinished)
            return;
        try { _dispatcher.BeginInvoke(DispatcherPriority.Normal, callback); }
        catch (InvalidOperationException) when (_dispatcher.HasShutdownStarted) { }
    }

    private void Finish(NativeSession session, string? error)
    {
        if (_disposed || !ReferenceEquals(_session, session))
            return;
        _session = null;

        try
        {
            session.Dispose();
            if (error is null)
            {
                ValidateMp4(session.PartialPath);
                // Never overwrite another file, including one created during recording.
                File.Move(session.PartialPath, session.DestinationPath, overwrite: false);
            }
        }
        catch (Exception exception)
        {
            error ??= DescribeError(exception);
        }

        if (error is null)
            Completed?.Invoke(session.DestinationPath);
        else
            Failed?.Invoke(error + (File.Exists(session.PartialPath)
                ? L.F("engine.partialFile", session.PartialPath)
                : string.Empty));
    }

    private static void ValidateMp4(string path)
    {
        // A nonempty file alone is insufficient: an interrupted recording can contain
        // frames without the moov metadata needed to play the MP4.
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        Span<byte> header = stackalloc byte[16];
        bool fileType = false, movie = false, media = false;
        while (stream.Position < stream.Length)
        {
            var start = stream.Position;
            if (stream.Length - start < 8)
                throw new InvalidDataException(L.T("engine.invalidEnd"));
            stream.ReadExactly(header[..8]);
            ulong size = BinaryPrimitives.ReadUInt32BigEndian(header[..4]);
            var headerSize = 8;
            if (size == 1)
            {
                stream.ReadExactly(header[8..16]);
                size = BinaryPrimitives.ReadUInt64BigEndian(header[8..16]);
                headerSize = 16;
            }
            else if (size == 0)
                size = (ulong)(stream.Length - start);

            if (size < (ulong)headerSize || size > (ulong)(stream.Length - start))
                throw new InvalidDataException(L.T("engine.truncated"));
            var type = BinaryPrimitives.ReadUInt32BigEndian(header[4..8]);
            if (size > (ulong)headerSize)
            {
                fileType |= type == 0x66747970; // ftyp
                movie |= type == 0x6D6F6F76;    // moov
                media |= type == 0x6D646174;    // mdat
            }
            stream.Position = checked(start + (long)size);
        }
        if (!fileType || !movie || !media)
            throw new InvalidDataException(L.T("engine.incomplete"));
    }

    private static string DescribeError(Exception error)
    {
        var detail = error;
        while (detail.InnerException is not null)
            detail = detail.InnerException;

        if (detail is BadImageFormatException)
            return L.T("engine.x64");
        if (detail is DllNotFoundException or FileNotFoundException or FileLoadException)
            return L.T("engine.dependencies") + detail.Message;
        if (detail is UnauthorizedAccessException)
            return L.T("engine.noWrite");
        if (detail is ArgumentException or IOException or InvalidOperationException)
            return detail.Message;
        return L.T("engine.startFailed") + detail.Message;
    }

    public void Dispose()
    {
        _dispatcher.VerifyAccess();
        if (_disposed)
            return;
        _disposed = true;
        var session = _session;
        _session = null;
        if (session is not null)
        {
            try { StopNative(session); }
            catch (Exception error) { Debug.WriteLine(error); }
            DisposeSafely(session);
        }
        GC.SuppressFinalize(this);
    }

    private static void DisposeSafely(NativeSession? session)
    {
        try { session?.Dispose(); }
        catch (Exception error) { Debug.WriteLine(error); }
    }

    private sealed class NativeSession : IDisposable
    {
        internal readonly Recorder Recorder;
        internal readonly string DestinationPath;
        internal readonly string PartialPath;
        internal EventHandler<RecordingCompleteEventArgs>? CompletedHandler;
        internal EventHandler<RecordingFailedEventArgs>? FailedHandler;
        internal DispatcherTimer? FinalizationTimeout;
        internal bool IsStopping;
        private bool _isDisposed;

        internal NativeSession(Recorder recorder, string destination, string partial)
        {
            Recorder = recorder;
            DestinationPath = destination;
            PartialPath = partial;
        }

        public void Dispose()
        {
            if (_isDisposed)
                return;
            _isDisposed = true;
            FinalizationTimeout?.Stop();
            Recorder.OnRecordingComplete -= CompletedHandler;
            Recorder.OnRecordingFailed -= FailedHandler;
            Recorder.Dispose();
        }
    }
}
