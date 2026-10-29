using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace SuniCapture.Services;

/// <summary>Exports flattened pixels only. No original image, edit layers or source metadata is attached.</summary>
public static class ImageExport
{
    public static BitmapSource Load(string path)
    {
        var info = new FileInfo(path);
        if (!info.Exists) throw new FileNotFoundException(L.T("image.missing"), path);
        if (info.Length > 512L * 1024 * 1024)
            throw new InvalidOperationException(L.T("image.limit"));
        // OnLoad decodes before the stream closes, so imports never hold source files locked.
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        var decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
        if (decoder.Frames.Count == 0) throw new InvalidDataException(L.T("image.empty"));
        var frame = decoder.Frames[0];
        ValidateSize(frame);
        frame.Freeze();
        return frame;
    }

    public static void Save(BitmapSource image, string path)
    {
        ArgumentNullException.ThrowIfNull(image);
        ValidateSize(image);
        var fullPath = Path.GetFullPath(path);
        var extension = Path.GetExtension(fullPath).ToLowerInvariant();
        if (extension is not (".png" or ".jpg" or ".jpeg" or ".bmp" or ".pdf"))
            throw new NotSupportedException(L.T("image.exportType"));
        var directory = Path.GetDirectoryName(fullPath)!;
        Directory.CreateDirectory(directory);
        var temporaryPath = Path.Combine(directory, ".sunicapture-" + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            using (var stream = new FileStream(temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                if (extension == ".pdf") WritePdf(image, stream);
                else
                {
                    BitmapEncoder encoder = extension switch
                    {
                        ".jpg" or ".jpeg" => new JpegBitmapEncoder { QualityLevel = 94 },
                        ".bmp" => new BmpBitmapEncoder(),
                        _ => new PngBitmapEncoder()
                    };
                    // BitmapFrame.Create(bitmap) deliberately omits source metadata and thumbnails.
                    encoder.Frames.Add(BitmapFrame.Create(extension is ".jpg" or ".jpeg" ? Opaque(image) : CleanPixels(image)));
                    encoder.Save(stream);
                }
                stream.Flush(true);
            }
            File.Move(temporaryPath, fullPath, true);
        }
        finally
        {
            if (File.Exists(temporaryPath)) File.Delete(temporaryPath);
        }
    }

    private static void ValidateSize(BitmapSource image)
    {
        if (image.PixelWidth < 1 || image.PixelHeight < 1 || (long)image.PixelWidth * image.PixelHeight > 100_000_000)
            throw new InvalidOperationException(L.T("image.pixelLimit"));
    }

    private static BitmapSource CleanPixels(BitmapSource image)
    {
        // Recreate from the final pixels rather than wrapping a decoded frame with embedded metadata.
        var converted = new FormatConvertedBitmap(image, PixelFormats.Bgra32, null, 0);
        var stride = checked(image.PixelWidth * 4);
        var pixels = new byte[checked(stride * image.PixelHeight)];
        converted.CopyPixels(pixels, stride, 0);
        var clean = BitmapSource.Create(image.PixelWidth, image.PixelHeight, 96, 96, PixelFormats.Bgra32, null, pixels, stride);
        clean.Freeze();
        return clean;
    }

    private static BitmapSource Opaque(BitmapSource image)
    {
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            var rect = new Rect(0, 0, image.PixelWidth, image.PixelHeight);
            dc.DrawRectangle(Brushes.White, null, rect);
            dc.DrawImage(image, rect);
        }
        var result = new RenderTargetBitmap(image.PixelWidth, image.PixelHeight, 96, 96, PixelFormats.Pbgra32);
        result.Render(visual);
        result.Freeze();
        return result;
    }

    private static void WritePdf(BitmapSource image, Stream output)
    {
        var encoder = new JpegBitmapEncoder { QualityLevel = 94 };
        encoder.Frames.Add(BitmapFrame.Create(Opaque(image)));
        using var jpegStream = new MemoryStream();
        encoder.Save(jpegStream);
        var jpeg = jpegStream.ToArray();
        // A custom-sized page preserves the screenshot aspect ratio without clipping.
        var scale = Math.Min(0.75, 14400.0 / Math.Max(image.PixelWidth, image.PixelHeight));
        var pageWidth = (image.PixelWidth * scale).ToString("0.###", CultureInfo.InvariantCulture);
        var pageHeight = (image.PixelHeight * scale).ToString("0.###", CultureInfo.InvariantCulture);
        var commands = Encoding.ASCII.GetBytes($"q\n{pageWidth} 0 0 {pageHeight} 0 0 cm\n/Im0 Do\nQ\n");
        var offsets = new List<long> { 0 };

        void Write(string value)
        {
            var bytes = Encoding.Latin1.GetBytes(value);
            output.Write(bytes, 0, bytes.Length);
        }
        void Begin(int id)
        {
            offsets.Add(output.Position);
            Write($"{id} 0 obj\n");
        }
        Write("%PDF-1.4\n%\u00e2\u00e3\u00cf\u00d3\n");
        Begin(1); Write("<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");
        Begin(2); Write("<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");
        Begin(3); Write($"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {pageWidth} {pageHeight}] /Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>\nendobj\n");
        Begin(4); Write($"<< /Type /XObject /Subtype /Image /Width {image.PixelWidth} /Height {image.PixelHeight} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length {jpeg.Length} >>\nstream\n");
        output.Write(jpeg, 0, jpeg.Length);
        Write("\nendstream\nendobj\n");
        Begin(5); Write($"<< /Length {commands.Length} >>\nstream\n");
        output.Write(commands, 0, commands.Length);
        Write("endstream\nendobj\n");
        var xref = output.Position;
        Write("xref\n0 6\n0000000000 65535 f \n");
        for (var i = 1; i < offsets.Count; i++)
            Write(offsets[i].ToString("0000000000", CultureInfo.InvariantCulture) + " 00000 n \n");
        Write($"trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n");
    }
}
