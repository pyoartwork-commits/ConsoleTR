using System.Diagnostics;
using System.Windows.Threading;
using ConsoleTR.Core;

namespace ConsoleTR.App;

/// <summary>Capture → OCR → tracking → overlays, four times per second, on the UI thread.</summary>
internal sealed class LiveSession
{
    private readonly IntPtr target;
    private readonly IReadOnlyList<ScanZone> zones;
    private readonly ITranslationProvider provider;
    private readonly WindowsOcr ocr;
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(250) };
    private readonly Dictionary<Guid, OverlayWindow> overlays = [];
    // One shared overlay, fixed at the bottom, for every caption translation; see SubtitleBand.
    private static readonly Guid BandKey = Guid.NewGuid();
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private PixelRect? frame;
    private bool busy, enabled = true;

    internal LiveSession(IntPtr target, IReadOnlyList<ScanZone> zones, ITranslationProvider provider, WindowsOcr ocr)
    {
        this.target = target;
        this.zones = zones;
        this.provider = provider;
        this.ocr = ocr;
        Manager = new TrackManager(provider, () => clock.Elapsed.TotalSeconds);
        Manager.Changed += () => SyncOverlays(frame);
        Manager.Failed += error => Fail(error is TranslationException ? error.Message : "Çeviri sağlayıcısına ulaşılamadı. Ayarları kontrol edin.");
        timer.Tick += async (_, _) => await Step();
    }

    internal TrackManager Manager { get; }
    internal OverlayStyle Style { get; set; } = new();
    internal bool Running => timer.IsEnabled;
    internal double OcrMs { get; private set; }
    internal event Action<string>? StatusChanged;
    internal event Action? Updated;
    internal event Action? Stopped;

    internal bool Enabled
    {
        get => enabled;
        set
        {
            enabled = value;
            if (!value) Manager.Clear();
        }
    }

    internal void Start()
    {
        (provider as OllamaTranslator)?.Prewarm();
        timer.Start();
        StatusChanged?.Invoke("Metin bekleniyor…");
    }

    internal void Stop()
    {
        timer.Stop();
        Manager.Clear();
        foreach (var overlay in overlays.Values) overlay.Close();
        overlays.Clear();
    }

    private void Fail(string message)
    {
        if (!Running) return;
        Stop();
        StatusChanged?.Invoke(message);
        Stopped?.Invoke();
    }

    private async Task Step()
    {
        if (busy || !Running) return;
        busy = true;
        try
        {
            Manager.Tick();
            if (!Native.IsWindow(target)) { Fail("Seçilen pencere kapandı. Pencereyi yeniden seçin."); return; }
            frame = TargetWindows.Client(target);
            if (frame is null || !enabled) { SyncOverlays(frame); return; }
            var (pixels, width, height) = ScreenGrabber.Capture(frame, 1600, WindowsOcr.MaxDimension);
            var watch = Stopwatch.StartNew();
            var lines = await ocr.ReadAsync(pixels, width, height);
            OcrMs = watch.Elapsed.TotalMilliseconds;
            if (!Running) return;
            // The frame is read once; manual zones keep the lines whose centre falls inside them.
            var detections = LineMerger.Merge(zones.Select(zone => (zone, (IReadOnlyList<OcrLine>)lines.Where(l =>
                l.Box.MidX >= zone.Rect.MinX && l.Box.MidX <= zone.Rect.MaxX && l.Box.MidY >= zone.Rect.MinY && l.Box.MidY <= zone.Rect.MaxY).ToList())));
            Manager.AnchorSize = (frame.Width, frame.Height);
            Manager.Receive(detections);
            StatusChanged?.Invoke(Manager.Tracks.Count == 0 ? "Metin bekleniyor…" : "Metinler izleniyor.");
            Updated?.Invoke();
        }
        catch (Exception error) when (error is InvalidOperationException or TranslationException)
        {
            Fail(error.Message);
        }
        catch (Exception error)
        {
            Fail($"İşlem tamamlanamadı: {error.Message}");
        }
        finally
        {
            busy = false;
        }
    }

    private void SyncOverlays(PixelRect? area)
    {
        bool banded = Style.SubtitleBand;
        var bandTrack = banded ? SubtitleBand.Pick(Manager.Tracks) : null;
        // Lines in the band get no overlay of their own.
        var shown = Manager.Tracks.Where(t => t.Value is not null && !(banded && SubtitleBand.Holds(t))).ToDictionary(t => t.Id);
        foreach (var id in overlays.Keys.Where(id => area is null || (id == BandKey ? bandTrack is null : !shown.ContainsKey(id))).ToList())
        {
            overlays[id].Close();
            overlays.Remove(id);
        }
        if (area is null || !Running) return;
        foreach (var track in shown.Values)
        {
            if (!overlays.TryGetValue(track.Id, out var overlay)) overlays[track.Id] = overlay = new OverlayWindow();
            overlay.Present(track.Value!, track.Line.Box, area, Style);
        }
        if (bandTrack is not null)
        {
            if (!overlays.TryGetValue(BandKey, out var overlay)) overlays[BandKey] = overlay = new OverlayWindow();
            overlay.PresentAtBottom(bandTrack.Value!, area, Style);
        }
        Updated?.Invoke();
    }
}
