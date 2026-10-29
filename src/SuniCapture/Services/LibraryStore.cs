using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Windows.Media.Imaging;
using SuniCapture.Models;

namespace SuniCapture.Services;

public sealed class LibraryStore
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };
    public string Root { get; }
    public string OriginalDirectory => Path.Combine(Root, "originals");
    public string EditedDirectory => Path.Combine(Root, "edited");
    public string VideoDirectory => Path.Combine(Root, "videos");
    public List<CaptureItem> Items { get; } = new();
    public AppSettings Settings { get; private set; } = new();
    public string? LoadWarning { get; private set; }

    public LibraryStore(string? root = null)
    {
        Root = Path.GetFullPath(root ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SuniCapture"));
        Directory.CreateDirectory(OriginalDirectory);
        Directory.CreateDirectory(EditedDirectory);
        Directory.CreateDirectory(VideoDirectory);
        var items = ReadRecoverable<List<CaptureItem>>("library.json");
        if (items != null)
        {
            foreach (var item in items)
            {
                if (Guid.TryParseExact(item.Id, "N", out _) && IsSafeRelative(item.OriginalFile) && (item.EditedFile == null || IsSafeRelative(item.EditedFile)))
                    Items.Add(item);
            }
        }
        Settings = ReadRecoverable<AppSettings>("settings.json") ?? new();
        Settings.Language = L.Normalize(Settings.Language);
        Settings.CaptureDelay = Math.Clamp(Settings.CaptureDelay, 0, 10);
        Settings.WindowWidth = Math.Clamp(Settings.WindowWidth, 1100, 3000);
        Settings.WindowHeight = Math.Clamp(Settings.WindowHeight, 700, 2000);
    }

    private static bool IsSafeRelative(string path) => !string.IsNullOrWhiteSpace(path) && !Path.IsPathRooted(path) && !path.Split('/', '\\').Any(part => part == "..");

    public string Resolve(string relative)
    {
        if (!IsSafeRelative(relative)) throw new InvalidDataException(L.T("store.invalidPath"));
        var full = Path.GetFullPath(Path.Combine(Root, relative));
        if (!full.StartsWith(Root.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException(L.T("store.outside"));
        return full;
    }

    public string CurrentFile(CaptureItem item) => Resolve(item.EditedFile ?? item.OriginalFile);
    public void Save() => WriteAtomic(Path.Combine(Root, "library.json"), JsonSerializer.Serialize(Items, JsonOptions));
    public void SaveSettings() => WriteAtomic(Path.Combine(Root, "settings.json"), JsonSerializer.Serialize(Settings, JsonOptions));

    public CaptureItem AddImage(BitmapSource image, string source, string? name = null)
    {
        var item = new CaptureItem { Name = name ?? L.F("library.captureName", DateTime.Now), Width = image.PixelWidth, Height = image.PixelHeight, Source = source };
        item.OriginalFile = Path.Combine("originals", item.Id + ".png");
        ImageExport.Save(image, Resolve(item.OriginalFile));
        Items.Insert(0, item);
        try { Save(); } catch { Items.Remove(item); throw; }
        item.Thumbnail = MakeThumbnail(image);
        return item;
    }

    public CaptureItem AddVideo(string path, double duration)
    {
        var item = new CaptureItem { Name = L.F("library.recordingName", DateTime.Now), Kind = "video", DurationSeconds = duration, Source = L.T("record.primary") };
        var relative = Path.Combine("videos", item.Id + ".mp4");
        var destination = Resolve(relative);
        var moved = !Path.GetFullPath(path).Equals(destination, StringComparison.OrdinalIgnoreCase);
        if (moved) File.Move(path, destination);
        item.OriginalFile = relative;
        Items.Insert(0, item);
        try { Save(); }
        catch (Exception indexingError)
        {
            Items.Remove(item);
            if (moved)
            {
                try { File.Move(destination, path); }
                catch (IOException rollbackError)
                {
                    throw new IOException(L.F("library.videoRecovery", destination), new AggregateException(indexingError, rollbackError));
                }
            }
            throw;
        }
        return item;
    }

    public void SaveEdited(CaptureItem item, BitmapSource image)
    {
        var relative = Path.Combine("edited", item.Id + ".png");
        var finalPath = Resolve(relative);
        var tempPath = Path.Combine(EditedDirectory, item.Id + ".writing.png");
        ImageExport.Save(image, tempPath);
        File.Move(tempPath, finalPath, true);
        item.EditedFile = relative;
        item.Width = image.PixelWidth;
        item.Height = image.PixelHeight;
        item.Thumbnail = MakeThumbnail(image);
        Save();
    }

    public void LoadThumbnail(CaptureItem item)
    {
        if (item.IsVideo) return;
        try
        {
            using var stream = File.OpenRead(CurrentFile(item));
            var bitmap = new BitmapImage();
            bitmap.BeginInit();
            bitmap.CacheOption = BitmapCacheOption.OnLoad;
            bitmap.DecodePixelWidth = 200;
            bitmap.StreamSource = stream;
            bitmap.EndInit();
            bitmap.Freeze();
            item.Thumbnail = bitmap;
        }
        catch (IOException) { }
        catch (NotSupportedException) { }
        catch (FileFormatException) { }
    }

    private static BitmapSource MakeThumbnail(BitmapSource source)
    {
        var scale = Math.Min(1.0, 200.0 / source.PixelWidth);
        var bitmap = new TransformedBitmap(source, new System.Windows.Media.ScaleTransform(scale, scale));
        bitmap.Freeze();
        return bitmap;
    }

    private T? ReadRecoverable<T>(string name)
    {
        var path = Path.Combine(Root, name);
        if (!File.Exists(path)) return default;
        try { return JsonSerializer.Deserialize<T>(File.ReadAllText(path)); }
        catch (Exception error) when (error is JsonException or IOException or UnauthorizedAccessException)
        {
            LoadWarning = L.F("library.loadWarning", name);
            // Preserve the damaged index before any later save; recover the last good index when available.
            try { File.Copy(path, path + ".unreadable-" + DateTime.Now.ToString("yyyyMMdd-HHmmss"), false); } catch (IOException) { }
            try
            {
                if (File.Exists(path + ".bak")) return JsonSerializer.Deserialize<T>(File.ReadAllText(path + ".bak"));
            }
            catch (Exception backupError) when (backupError is JsonException or IOException or UnauthorizedAccessException) { }
            return default;
        }
    }

    private static void WriteAtomic(string path, string content)
    {
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, content);
        if (File.Exists(path)) File.Copy(path, path + ".bak", true);
        File.Move(temporary, path, true);
    }
}
