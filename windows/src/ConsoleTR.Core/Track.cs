namespace ConsoleTR.Core;

/// <summary>A line followed across frames. Mirrors Track in macos/Sources/Controller.swift.</summary>
public sealed class Track
{
    private readonly List<string> reads;

    internal Track(Detection line, string? value, double now)
    {
        Line = line;
        Since = now;
        reads = [line.Text];
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
    /// Fast OCR on a moving scene misreads a few characters per frame, so the shown text is
    /// the majority of the last five readings. Ties keep the current text.
    /// </summary>
    internal void Observe(string text)
    {
        reads.Add(text);
        if (reads.Count > 5) reads.RemoveAt(0);
        var counts = reads.GroupBy(Key).ToDictionary(g => g.Key, g => g.Count());
        int current = counts.GetValueOrDefault(TranslationKey);
        var best = counts.MaxBy(pair => pair.Value);
        string winner = best.Value > current ? best.Key : TranslationKey;
        string? latest = reads.LastOrDefault(r => Key(r) == winner);
        if (latest is not null) Line = Line with { Text = latest };
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
