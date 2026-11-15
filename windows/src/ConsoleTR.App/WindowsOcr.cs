using System.Runtime.InteropServices.WindowsRuntime;
using ConsoleTR.Core;

namespace ConsoleTR.App;

/// <summary>English text recognition with the OCR engine built into Windows 10 and 11.</summary>
internal sealed class WindowsOcr
{
    private readonly global::Windows.Media.Ocr.OcrEngine engine;

    private WindowsOcr(global::Windows.Media.Ocr.OcrEngine engine) => this.engine = engine;

    internal static uint MaxDimension => global::Windows.Media.Ocr.OcrEngine.MaxImageDimension;

    /// <summary>Fails with a Turkish explanation when the English OCR pack is missing, as on many Turkish installs.</summary>
    internal static WindowsOcr Create()
    {
        var engine = global::Windows.Media.Ocr.OcrEngine.TryCreateFromLanguage(new global::Windows.Globalization.Language("en-US"));
        return engine is not null ? new WindowsOcr(engine) : throw new InvalidOperationException(
            "Windows’un İngilizce metin tanıma paketi yüklü değil. Ayarlar > Saat ve dil > Dil ve bölge bölümünden " +
            "“English (United States)” dilini ekleyin ya da yönetici PowerShell’de şunu çalıştırın: " +
            "Add-WindowsCapability -Online -Name \"Language.OCR~~~en-US~0.0.1.0\"");
    }

    internal async Task<IReadOnlyList<OcrLine>> ReadAsync(byte[] pixels, int width, int height)
    {
        using var bitmap = global::Windows.Graphics.Imaging.SoftwareBitmap.CreateCopyFromBuffer(
            pixels.AsBuffer(), global::Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, width, height,
            global::Windows.Graphics.Imaging.BitmapAlphaMode.Ignore);
        var result = await engine.RecognizeAsync(bitmap);
        var lines = new List<OcrLine>();
        foreach (var line in result.Lines)
        {
            if (line.Words.Count == 0) continue;
            double left = double.MaxValue, top = double.MaxValue, right = 0, bottom = 0;
            foreach (var word in line.Words)
            {
                var r = word.BoundingRect;
                left = Math.Min(left, r.X);
                top = Math.Min(top, r.Y);
                right = Math.Max(right, r.X + r.Width);
                bottom = Math.Max(bottom, r.Y + r.Height);
            }
            lines.Add(new OcrLine(line.Text, new NormRect(left / width, top / height, (right - left) / width, (bottom - top) / height)));
        }
        return lines;
    }
}
