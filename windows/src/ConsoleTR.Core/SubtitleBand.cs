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

    // Captions sit low and centred. Off-centre lines, such as a phone card in a corner, keep their
    // own overlay next to them.
    public static bool Holds(Track track) =>
        track.Line.Role == TextRole.Subtitle && track.Line.Box.MidY >= 0.6 && Math.Abs(track.Line.Box.MidX - 0.5) < 0.25;

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

    /// <summary>
    /// The newest translated caption. While the next caption is still being translated, the
    /// previous one stays instead of an older line flashing in between.
    /// </summary>
    public static Track? Pick(IEnumerable<Track> all) => all.Where(t => Holds(t) && t.Value is not null).MaxBy(t => t.Since);
}
