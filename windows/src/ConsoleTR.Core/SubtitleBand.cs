namespace ConsoleTR.Core;

/// <summary>
/// Every caption has its own box, so translations placed next to each line moved with every
/// new line. Lower-half captions share one band just above them; only its text changes.
/// Mirrors the band in macos/Sources/Controller.swift.
/// </summary>
public sealed class SubtitleBand
{
    private readonly List<(double Time, double Top)> samples = [];

    /// <summary>Top of the band's source area, normalized; the band sits above it.</summary>
    public double? Top { get; private set; }

    public static bool Holds(Track track) => track.Line.Role == TextRole.Subtitle && track.Line.Box.MidY >= 0.5;

    /// <summary>Follows the tallest caption of the last 10 s, ignoring less than 8 px of OCR jitter.</summary>
    /// <returns>Whether the band moved.</returns>
    public bool Update(IEnumerable<Track> onScreen, double now, double frameHeight)
    {
        foreach (var track in onScreen.Where(Holds)) samples.Add((now, track.Line.Box.MinY));
        samples.RemoveAll(s => now - s.Time > 10);
        if (samples.Count == 0) return false;
        double top = samples.Min(s => s.Top);
        if (Top is { } current && Math.Abs(top - current) * frameHeight < 8) return false;
        Top = top;
        return true;
    }

    /// <summary>The newest caption on screen with a translation, else the newest one still being read.</summary>
    public static Track? Pick(IEnumerable<Track> all, IEnumerable<Track> onScreen)
    {
        var visible = onScreen.ToHashSet();
        var band = all.Where(t => Holds(t) && t.Value is not null).ToList();
        return band.Where(visible.Contains).MaxBy(t => t.Since) ?? band.MaxBy(t => t.Since);
    }
}
