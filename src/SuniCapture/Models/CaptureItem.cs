using System;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json.Serialization;
using System.Windows.Media.Imaging;

namespace SuniCapture.Models;

public sealed class CaptureItem : INotifyPropertyChanged
{
    private string _name = "Capture";
    private bool _favorite;
    private bool _isTrashed;
    private BitmapSource? _thumbnail;

    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public string Name { get => _name; set { _name = value; Notify(); } }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.Now;
    public string Kind { get; set; } = "image";
    public string OriginalFile { get; set; } = "";
    public string? EditedFile { get; set; }
    public int Width { get; set; }
    public int Height { get; set; }
    public double DurationSeconds { get; set; }
    public string Source { get; set; } = "Capture";
    public bool Favorite { get => _favorite; set { _favorite = value; Notify(); Notify(nameof(FavoriteMark)); } }
    public bool IsTrashed { get => _isTrashed; set { _isTrashed = value; Notify(); } }
    public DateTimeOffset? TrashedAt { get; set; }

    [JsonIgnore] public string Subtitle => Kind == "video" ? L.F("library.videoSubtitle", DurationSeconds) : CreatedAt.LocalDateTime.ToString("dd MMM · HH:mm", L.Culture) + $"   {Width} × {Height}";
    [JsonIgnore] public string FavoriteMark => Favorite ? "★" : "";
    [JsonIgnore] public bool IsVideo => Kind == "video";
    [JsonIgnore] public BitmapSource? Thumbnail { get => _thumbnail; set { _thumbnail = value; Notify(); } }
    public event PropertyChangedEventHandler? PropertyChanged;
    public void RefreshLanguage() => Notify(nameof(Subtitle));
    private void Notify([CallerMemberName] string? property = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(property));
}

public sealed class AppSettings
{
    public string Language { get; set; } = "fr";
    public bool DarkMode { get; set; }
    public int CaptureDelay { get; set; }
    public bool CopyAfterCapture { get; set; } = true;
    public bool SystemAudio { get; set; }
    public bool MinimizeToTray { get; set; } = true;
    public double WindowWidth { get; set; } = 1440;
    public double WindowHeight { get; set; } = 940;
}
