namespace ConsoleTR.Core;

/// <summary>
/// Every caption has its own box, so translations placed next to each line, or a band that
/// followed the captions, moved around the screen. Caption translations share one band fixed at
/// the bottom of the frame; only its text changes. Mirrors the band in macos/Sources/Controller.swift.
/// </summary>
public static class SubtitleBand
{
    /// <summary>Wherever a caption was read, its translation goes to the band. Objectives keep their own overlay.</summary>
    public static bool Holds(Track track) => track.Line.Role == TextRole.Subtitle;

    /// <summary>
    /// The newest translated caption. While the next caption is still being translated, the
    /// previous one stays instead of an older line flashing in between.
    /// </summary>
    public static Track? Pick(IEnumerable<Track> all) => all.Where(t => Holds(t) && t.Value is not null).MaxBy(t => t.Since);
}
