using ConsoleTR.Core;

public class SubtitleBandTests
{
    private static Track Line(string text, NormRect box, double since, string? value = "TR") =>
        new(new Detection(TextRole.Subtitle, text, box), value is null ? null : value + ": " + text, since);

    [Fact]
    public void BandFollowsTheTallestRecentCaptionAndIgnoresJitter()
    {
        var band = new SubtitleBand();
        var oneLine = Line("Follow me.", new NormRect(0.4, 0.86, 0.2, 0.03), 0);
        Assert.True(band.Update([oneLine], 0, 900));
        Assert.Equal(0.86, band.Top!.Value, 6);
        // 3 px of jitter does not move it.
        Assert.False(band.Update([Line("Follow me.", new NormRect(0.4, 0.86 - 3.0 / 900, 0.2, 0.03), 1)], 1, 900));
        // A two-line caption raises it, and it stays up while that caption is recent.
        Assert.True(band.Update([Line("I've heard rumors of a griffin near White Orchard.", new NormRect(0.3, 0.82, 0.4, 0.07), 2)], 2, 900));
        Assert.False(band.Update([oneLine], 5, 900));
        Assert.Equal(0.82, band.Top!.Value, 6);
        // Ten seconds later it comes back down to the one-line caption.
        Assert.True(band.Update([oneLine], 13, 900));
        Assert.Equal(0.86, band.Top!.Value, 6);
    }

    [Fact]
    public void UpperHalfLinesAndObjectivesStayOutOfTheBand()
    {
        var band = new SubtitleBand();
        var choice = Line("What happened here?", new NormRect(0.6, 0.40, 0.2, 0.03), 0);
        var goal = new Track(new Detection(TextRole.Objective, "Find the key", new NormRect(0.75, 0.9, 0.2, 0.03)), "TR: Find the key", 0);
        Assert.False(band.Update([choice, goal], 0, 900));
        Assert.Null(band.Top);
        Assert.Null(SubtitleBand.Pick([choice, goal], [choice, goal]));
    }

    [Fact]
    public void BandShowsTheNewestCaptionOnScreenThenTheNewestStillBeingRead()
    {
        var old = Line("Wait for me.", new NormRect(0.4, 0.86, 0.2, 0.03), 1);
        var current = Line("Follow me.", new NormRect(0.4, 0.86, 0.2, 0.03), 2);
        var untranslated = Line("Get in the car.", new NormRect(0.4, 0.86, 0.2, 0.03), 3, value: null);
        Assert.Same(current, SubtitleBand.Pick([old, current, untranslated], [current, untranslated]));
        // Once every line has left the screen, the newest one keeps the band until it expires.
        Assert.Same(current, SubtitleBand.Pick([old, current], []));
    }
}
