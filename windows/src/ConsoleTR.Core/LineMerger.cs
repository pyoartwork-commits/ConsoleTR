namespace ConsoleTR.Core;

/// <summary>
/// Turns raw OCR lines into captions and objectives: classification, wrapped-line
/// continuation, duplicate removal and joining of multi-line captions. Mirrors the
/// second half of SubtitleReader.read in macos/Sources/Core.swift.
/// </summary>
public static class LineMerger
{
    public static IReadOnlyList<Detection> Merge(IEnumerable<(ScanZone Zone, IReadOnlyList<OcrLine> Lines)> zones)
    {
        var lines = new List<Detection>();
        foreach (var (zone, observed) in zones)
        {
            var found = new List<Detection>();
            foreach (var line in observed.OrderBy(l => l.Box.MinY))
            {
                if (!line.Text.Any(char.IsLetter)) continue;
                TextRole? role = zone.Role ?? GameTextClassifier.Classify(line.Text, line.Box);
                // Wrapped lines often lack a speaker name, action verb or punctuation.
                if (role is null && line.Text.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length >= 2)
                {
                    var box = line.Box;
                    role = found.LastOrDefault(previous =>
                    {
                        double gap = box.MinY - previous.Box.MaxY;
                        bool aligned = Math.Abs(box.MinX - previous.Box.MinX) < box.Height || Math.Abs(box.MidX - previous.Box.MidX) < box.Height;
                        return aligned && gap >= 0 && gap < box.Height * 0.65 && Math.Abs(box.Height - previous.Box.Height) < box.Height * 0.25;
                    })?.Role;
                }
                if (role is { } r) found.Add(new Detection(r, line.Text, line.Box));
            }
            lines.AddRange(found);
        }
        // An overlapping zone must not draw the same source line twice.
        var unique = new List<Detection>();
        foreach (var line in lines)
        {
            bool duplicate = unique.Any(u => u.Box.Intersection(line.Box) is { } overlap &&
                overlap.Area > 0.65 * Math.Min(u.Box.Area, line.Box.Area));
            if (!duplicate) unique.Add(line);
        }
        // Join adjacent lines of a caption so their overlays cannot cover each other.
        var blocks = new List<Detection>();
        foreach (var line in unique.OrderBy(l => l.Box.MinY))
        {
            int index = blocks.FindLastIndex(b =>
            {
                double gap = line.Box.MinY - b.Box.MaxY;
                return b.Role == line.Role && gap >= -line.Box.Height * 0.25 && gap <= line.Box.Height * 0.75 &&
                       Math.Min(b.Box.MaxX, line.Box.MaxX) > Math.Max(b.Box.MinX, line.Box.MinX);
            });
            if (index >= 0) blocks[index] = blocks[index] with { Text = blocks[index].Text + " " + line.Text, Box = blocks[index].Box.Union(line.Box) };
            else blocks.Add(line);
        }
        return blocks;
    }
}
