namespace ConsoleTR.Core;

/// <summary>A line followed across frames. Mirrors Track in macos/Sources/Controller.swift.</summary>
public sealed class Track
{
    private readonly List<(string Text, NormRect Box)> reads;

    internal Track(Detection line, string? value, double now)
    {
        Line = line;
        Since = now;
        reads = [(line.Text, line.Box)];
        if (value is not null) SetValue(value, Key(line.Text), now);
    }

    public Guid Id { get; } = Guid.NewGuid();
    public Detection Line { get; internal set; }
    public string? Value { get; private set; }
    /// <summary>The key <see cref="Value"/> was translated from; may lag behind while a better reading is translated.</summary>
    public string? ValueKey { get; private set; }
    /// <summary>When the translation first appeared, in seconds.</summary>
    public double? ShownAt { get; private set; }
    /// <summary>The key of the latest translation request made for this track.</summary>
    public string? RequestedKey { get; internal set; }
    public double Since { get; }
    public string TranslationKey => Key(Line.Text);
    public bool NeedsTranslation => ValueKey != TranslationKey;

    internal void SetValue(string value, string key, double now)
    {
        Value = value;
        ValueKey = key;
        ShownAt ??= now;
    }

    /// <summary>
    /// OCR on a moving scene misreads or clips parts of a line on some frames, so the shown text
    /// is the majority of the last five readings. Ties keep the current text. Mirrors
    /// Track.observe in macos/Sources/Controller.swift.
    /// </summary>
    /// <param name="tolerance">Box jitter, in normalized units, that must not move the overlay.</param>
    internal void Observe(string text, NormRect box, (double X, double Y) tolerance)
    {
        reads.Add((text, box));
        if (reads.Count > 5) reads.RemoveAt(0);
        // A clipped reading ("Man, what…" for "Lamar: Man, what…") counts for the current text.
        string current = TranslationKey;
        var counts = reads.GroupBy(r => { string key = Key(r.Text); return current.Contains(key, StringComparison.Ordinal) ? current : key; })
            .ToDictionary(g => g.Key, g => g.Count());
        var best = counts.MaxBy(pair => pair.Value);
        string winner = best.Value > counts.GetValueOrDefault(current) ? best.Key : current;
        NormRect Loose(NormRect rect) => rect.Inflate(tolerance.X, tolerance.Y);
        int index = reads.FindLastIndex(r => Key(r.Text) == winner);
        if (winner != current && index >= 0)
        {
            Line = Line with { Text = reads[index].Text, Box = reads[index].Box };
        }
        else if (Key(text) == current)
        {
            // A reading of the shown text places the overlay unless it only jitters.
            bool jitter = Loose(Line.Box).Contains(box) && Loose(box).Contains(Line.Box);
            Line = jitter ? Line with { Text = text } : Line with { Text = text, Box = box };
        }
        else if (!Loose(Line.Box).Contains(box))
        {
            // Another reading inside the box is clipped (a colored speaker name or a word lost on
            // a bright patch) and used to shift the overlay sideways, so it changes nothing. One
            // reaching outside the box means the line moved or was read more fully.
            Line = Line with { Box = box };
        }
    }

    public static string Key(string text) =>
        string.Join(' ', text.ToLowerInvariant().Split([' ', '\t', '\n', '\r', ',', '.'], StringSplitOptions.RemoveEmptyEntries));

    /// <summary>Edit-distance similarity of two keys, or 1 when one contains the other.</summary>
    public static double Similarity(string a, string b)
    {
        if (a.Length == 0 || b.Length == 0) return 0;
        if (Math.Min(a.Length, b.Length) >= 4 && (a.Contains(b, StringComparison.Ordinal) || b.Contains(a, StringComparison.Ordinal))) return 1;
        var row = new int[b.Length + 1];
        for (int j = 0; j <= b.Length; j++) row[j] = j;
        for (int i = 1; i <= a.Length; i++)
        {
            int previous = row[0];
            row[0] = i;
            for (int j = 1; j <= b.Length; j++)
            {
                int saved = row[j];
                row[j] = Math.Min(Math.Min(row[j] + 1, row[j - 1] + 1), previous + (a[i - 1] == b[j - 1] ? 0 : 1));
                previous = saved;
            }
        }
        return 1 - (double)row[b.Length] / Math.Max(a.Length, b.Length);
    }

    /// <summary>A translation that arrives late must stay long enough to be read once its line is gone.</summary>
    public static double ReadingTime(string text) => Math.Min(6, 1.5 + 0.06 * text.Length);
}
