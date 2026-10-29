using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using SuniCapture.Services;

namespace SuniCapture.Editor;

/// <summary>Functional checks against synthetic pixels; does not read the screen or personal files.</summary>
public static class EditorDiagnostics
{
    public static IReadOnlyList<string> Run(string outputDirectory)
    {
        Directory.CreateDirectory(outputDirectory);
        var passed = new List<string>();
        void Require(bool condition, string label)
        {
            if (!condition) throw new InvalidOperationException("Diagnostic éditeur : " + label);
            passed.Add(label);
        }

        var pixels = new byte[180 * 120 * 4];
        for (var y = 0; y < 120; y++)
        for (var x = 0; x < 180; x++)
        {
            var i = (y * 180 + x) * 4;
            pixels[i] = (byte)(x % 255);
            pixels[i + 1] = (byte)(y % 255);
            pixels[i + 2] = 220;
            pixels[i + 3] = 255;
        }
        var source = BitmapSource.Create(180, 120, 192, 192, PixelFormats.Bgra32, null, pixels, 180 * 4);
        source.Freeze();
        var editor = new AnnotationCanvas { Image = source };
        Require(editor.Width == 180 && editor.Height == 120, "image dimensions use pixels independently of source DPI");
        Require(!editor.IsDirty && !editor.CanUndo && !editor.CanRedo, "opening image starts a clean history");
        editor.AddShape(EditorTool.Arrow, new Point(10, 10), new Point(110, 30));
        var arrow = ReadPixels(editor.Render());
        Require(!arrow.SequenceEqual(pixels), "arrow modifies exported pixels");
        editor.Undo();
        Require(!editor.IsDirty && editor.CanRedo && ReadPixels(editor.Render()).SequenceEqual(pixels),
            "undo restores original pixels and clean state");
        editor.Redo();
        Require(editor.IsDirty && editor.AnnotationCount == 1 && ReadPixels(editor.Render()).SequenceEqual(arrow),
            "redo restores the rendered annotation");
        editor.Reset();
        Require(ReadPixels(editor.Render()).SequenceEqual(pixels), "reset restores initially opened image");
        editor.AddShape(EditorTool.Pixelate, new Point(20, 20), new Point(80, 60));
        var masked = editor.Render();
        var maskedPixels = ReadPixels(masked);
        var sample = (35 * 180 + 40) * 4;
        Require(maskedPixels[sample] == 0x2A && maskedPixels[sample + 1] == 0x17 &&
            maskedPixels[sample + 2] == 0x0F && maskedPixels[sample + 3] == 255,
            "mask export replaces source with fully opaque pixels");
        editor.Crop(new Rect(10, 10, 100, 80));
        Require(editor.Image?.PixelWidth == 100 && editor.Image.PixelHeight == 80 && editor.AnnotationCount == 0,
            "crop flattens and keeps expected pixel dimensions");
        var croppedPixels = ReadPixels(editor.Render());
        editor.Undo();
        Require(editor.Image?.PixelWidth == 180 && ReadPixels(editor.Render()).SequenceEqual(maskedPixels),
            "undo crop restores all previous pixels and annotation layers");
        editor.Redo();
        Require(ReadPixels(editor.Render()).SequenceEqual(croppedPixels), "redo crop restores exact cropped pixels");
        editor.MarkClean();
        Require(!editor.IsDirty && editor.CanUndo, "saving marks clean while retaining undo");

        foreach (var extension in new[] { ".png", ".jpg", ".bmp", ".pdf" })
        {
            var path = Path.Combine(outputDirectory, "editor-export" + extension);
            ImageExport.Save(editor.Render(), path);
            Require(new FileInfo(path).Length > 50, extension + " export produces a file");
            if (extension == ".pdf") continue;
            var decoded = ImageExport.Load(path);
            Require(decoded.PixelWidth == 100 && decoded.PixelHeight == 80, extension + " export decodes with cropped dimensions");
            using var exclusive = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
            Require(exclusive.CanRead, extension + " imports release source file locks");
        }
        var pdf = File.ReadAllBytes(Path.Combine(outputDirectory, "editor-export.pdf"));
        var pdfText = Encoding.Latin1.GetString(pdf);
        Require(pdfText.StartsWith("%PDF-1.4", StringComparison.Ordinal) &&
            pdfText.Contains("/Width 100 /Height 80", StringComparison.Ordinal) &&
            pdfText.Contains("/Count 1", StringComparison.Ordinal) && pdfText.EndsWith("%%EOF\n", StringComparison.Ordinal),
            "PDF contains one cropped image page and complete trailer");
        Require(!Directory.GetFiles(outputDirectory, ".sunicapture-*.tmp").Any(), "exports leave no partial temporary files");
        return passed;
    }

    private static byte[] ReadPixels(BitmapSource source)
    {
        var converted = new FormatConvertedBitmap(source, PixelFormats.Bgra32, null, 0);
        var pixels = new byte[source.PixelWidth * source.PixelHeight * 4];
        converted.CopyPixels(pixels, source.PixelWidth * 4, 0);
        return pixels;
    }
}
