using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text.Json;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using SuniCapture.Editor;
using SuniCapture.Services;

namespace SuniCapture.Diagnostics;

public static class SmokeChecks
{
    public static bool Run(string outputRoot)
    {
        Directory.CreateDirectory(outputRoot);
        var runDirectory = Path.Combine(outputRoot, "run-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N")[..6]);
        Directory.CreateDirectory(runDirectory);
        var passed = new List<string>();
        string? failure = null;
        void Require(bool condition, string label) { if (!condition) throw new InvalidOperationException(label); passed.Add(label); }
        try
        {
            passed.AddRange(EditorDiagnostics.Run(Path.Combine(runDirectory, "exports")));
            var libraryPath = Path.Combine(runDirectory, "library");
            var store = new LibraryStore(libraryPath);
            var fixture = CreateFixture();
            var item = store.AddImage(fixture, "Test synthétique", "Capture été à Genève");
            var originalPath = store.Resolve(item.OriginalFile);
            var originalHash = SHA256.HashData(File.ReadAllBytes(originalPath));
            var editor = new AnnotationCanvas { Image = fixture, InkColor = Colors.Red };
            editor.AddShape(EditorTool.Arrow, new Point(120, 200), new Point(450, 330));
            store.SaveEdited(item, editor.Render());
            Require(originalHash.SequenceEqual(SHA256.HashData(File.ReadAllBytes(originalPath))), "Editing preserves original file bytes");
            Require(item.EditedFile != null && File.Exists(store.CurrentFile(item)), "Edited image stored separately from original");
            item.Favorite = true; item.Name = "Étude : révision façade"; store.Save();
            var reopened = new LibraryStore(libraryPath);
            Require(reopened.Items.Count == 1 && reopened.Items[0].Favorite && reopened.Items[0].Name == item.Name, "Library persists unicode names and favorites");
            item.IsTrashed = true; item.TrashedAt = DateTimeOffset.Now; store.Save();
            var trashed = new LibraryStore(libraryPath);
            Require(trashed.Items[0].IsTrashed && File.Exists(originalPath), "Trash preserves original and metadata");
            item.IsTrashed = false; item.TrashedAt = null; store.Save();
            Require(!new LibraryStore(libraryPath).Items[0].IsTrashed, "Trashed captures can be restored");
            var pendingVideo = Path.Combine(store.VideoDirectory, "pending-test.mp4");
            File.WriteAllBytes(pendingVideo, new byte[128]);
            using (var lockedIndex = new FileStream(Path.Combine(libraryPath, "library.json"), FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                bool indexFailed = false;
                try { store.AddVideo(pendingVideo, 2); }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { indexFailed = true; }
                Require(indexFailed && File.Exists(pendingVideo) && store.Items.Count == 1, "Failed video indexing rolls file back without losing original path");
            }
            store.Settings.DarkMode = true; store.Settings.CaptureDelay = 5; store.SaveSettings();
            var prefs = new LibraryStore(libraryPath).Settings;
            Require(prefs.DarkMode && prefs.CaptureDelay == 5, "Theme and delay persist across restart");
            bool traversalBlocked = false;
            try { store.Resolve("..\\outside.png"); } catch (InvalidDataException) { traversalBlocked = true; }
            Require(traversalBlocked, "Library rejects traversal paths");
            File.WriteAllText(Path.Combine(libraryPath, "library.json"), "{ broken index");
            var recovered = new LibraryStore(libraryPath);
            Require(recovered.LoadWarning != null && recovered.Items.Count == 1, "Corrupt index recovers from last valid backup");
            Require(Directory.GetFiles(libraryPath, "library.json.unreadable-*").Length == 1, "Corrupt index preserved for recovery");
            Require(File.Exists(originalPath), "Recovery leaves original captures untouched");
            var largeLibraryPath = Path.Combine(runDirectory, "large-library");
            Directory.CreateDirectory(largeLibraryPath);
            var manyItems = Enumerable.Range(0, 20001).Select(index => new Models.CaptureItem { Name = "Index " + index, OriginalFile = "originals/fixture.png" }).ToList();
            File.WriteAllText(Path.Combine(largeLibraryPath, "library.json"), JsonSerializer.Serialize(manyItems));
            var largeLibrary = new LibraryStore(largeLibraryPath);
            Require(largeLibrary.Items.Count == 20001, "Library reload retains every item above 20000 entries");
            largeLibrary.Save();
            Require(new LibraryStore(largeLibraryPath).Items.Count == 20001, "Saving large library preserves all capture references");
        }
        catch (Exception error) { failure = error.ToString(); }
        var report = new { success = failure == null, checkedAt = DateTimeOffset.Now, count = passed.Count, passed, failure, runDirectory };
        var json = JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(Path.Combine(runDirectory, "report.json"), json);
        File.WriteAllText(Path.Combine(outputRoot, "latest-report.json"), json);
        return failure == null;
    }

    public static BitmapSource CreateFixture()
    {
        const int width = 1120, height = 720;
        var visual = new DrawingVisual();
        using (var drawing = visual.RenderOpen())
        {
            Brush B(string hex) => new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
            void Text(string content, double x, double y, double size, string color, bool bold = false)
            {
                var format = new FormattedText(content, CultureInfo.GetCultureInfo("fr-CH"), FlowDirection.LeftToRight, new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, bold ? FontWeights.SemiBold : FontWeights.Normal, FontStretches.Normal), size, B(color), 1);
                drawing.DrawText(format, new Point(x, y));
            }
            drawing.DrawRectangle(B("#F4F7FB"), null, new Rect(0, 0, width, height));
            drawing.DrawRectangle(B("#FFFFFF"), null, new Rect(0, 0, width, 74));
            drawing.DrawEllipse(B("#2563EB"), null, new Point(43, 37), 14, 14);
            Text("Atelier Atlas", 70, 21, 22, "#0F172A", true);
            Text("Projet fictif · Image de vérification", 758, 28, 13, "#64748B");
            drawing.DrawRectangle(B("#FFFFFF"), null, new Rect(0, 75, 214, 645));
            Text("Espace de travail", 28, 110, 12, "#64748B");
            drawing.DrawRoundedRectangle(B("#E9EFFD"), null, new Rect(18, 151, 178, 44), 7, 7);
            Text("Vue d’ensemble", 34, 162, 15, "#2563EB", true);
            Text("Tâches", 34, 220, 15, "#64748B");
            Text("Documents", 34, 270, 15, "#64748B");
            Text("Équipe", 34, 320, 15, "#64748B");
            Text("Préparer la mise en ligne", 254, 115, 29, "#0F172A", true);
            Text("Un espace fictif pour tester vos annotations.", 256, 160, 15, "#64748B");
            drawing.DrawRoundedRectangle(B("#2563EB"), null, new Rect(255, 212, 820, 124), 12, 12);
            Text("Chaque détail compte.", 282, 234, 26, "#FFFFFF", true);
            Text("Validez les dernières étapes avant de partager votre projet.", 284, 280, 16, "#DBEAFE");
            Text("Liste de vérification", 256, 376, 19, "#0F172A", true);
            for (var row = 0; row < 3; row++)
            {
                var y = 421 + row * 74;
                drawing.DrawRoundedRectangle(B("#FFFFFF"), new Pen(B("#E2E8F0"), 1), new Rect(255, y, 820, 62), 8, 8);
                drawing.DrawRoundedRectangle(B(row < 2 ? "#DCFCE7" : "#E9EFFD"), null, new Rect(273, y + 17, 27, 27), 6, 6);
                Text(row < 2 ? "✓" : "3", 280, y + 18, 17, row < 2 ? "#15803D" : "#2563EB", true);
                Text(new[] { "Valider la navigation", "Relire les contenus", "Vérifier les images" }[row], 318, y + 18, 16, "#0F172A");
                Text(row < 2 ? "Terminé" : "À vérifier", 950, y + 22, 12, row < 2 ? "#15803D" : "#2563EB");
            }
            Text("Données synthétiques. Aucun client, compte ou projet réel.", 256, 674, 12, "#64748B");
        }
        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual); bitmap.Freeze(); return bitmap;
    }
}
