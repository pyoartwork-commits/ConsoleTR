using ConsoleTR.Core;

public class MergerTests
{
    private static IReadOnlyList<Detection> Merge(params OcrLine[] lines) => LineMerger.Merge([(ScanZone.Whole, lines)]);

    [Fact]
    public void TwoLineCaptionBecomesOneBlock()
    {
        var result = Merge(new OcrLine("Oh, Geralt. I didn't expect", new NormRect(0.40, 0.815, 0.20, 0.03)),
                           new OcrLine("to see you here", new NormRect(0.44, 0.86, 0.12, 0.03)));
        var block = Assert.Single(result);
        Assert.Equal(TextRole.Subtitle, block.Role);
        Assert.Equal("Oh, Geralt. I didn't expect to see you here", block.Text);
    }

    [Fact]
    public void ManualZoneForcesRole()
    {
        var zone = new ScanZone(TextRole.Objective, new NormRect(0.55, 0.1, 0.45, 0.4));
        var result = LineMerger.Merge([(zone, new[] { new OcrLine("The White Orchard", new NormRect(0.6, 0.2, 0.2, 0.03)) })]);
        Assert.Equal(TextRole.Objective, Assert.Single(result).Role);
    }

    [Fact]
    public void LinesWithoutLettersAreSkipped() =>
        Assert.Empty(Merge(new OcrLine("1200 / 1500", new NormRect(0.45, 0.85, 0.1, 0.03))));
}
