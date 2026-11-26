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
        Assert.Null(SubtitleBand.Pick([choice, goal]));
    }

    [Fact]
    public void BandShowsTheNewestCaptionOnScreenThenTheNewestStillBeingRead()
    {
        var old = Line("Wait for me.", new NormRect(0.4, 0.86, 0.2, 0.03), 1);
        var current = Line("Follow me.", new NormRect(0.4, 0.86, 0.2, 0.03), 2);
        var untranslated = Line("Get in the car.", new NormRect(0.4, 0.86, 0.2, 0.03), 3, value: null);
        Assert.Same(current, SubtitleBand.Pick([old, current, untranslated]));
    }

    [Fact]
    public void PreviousCaptionStaysWhileTheNextIsTranslated()
    {
        // A line that stays on screen must not flash in between two captions.
        var standing = Line("Hold the line.", new NormRect(0.4, 0.93, 0.2, 0.03), 0);
        var previous = Line("Hey, man, I spoke to Brian.", new NormRect(0.35, 0.86, 0.3, 0.03), 5);
        var next = Line("He says he wants to talk to you personally", new NormRect(0.3, 0.86, 0.4, 0.03), 6, value: null);
        Assert.Same(previous, SubtitleBand.Pick([standing, previous, next]));
    }

    [Fact]
    public void OffCentreAndMidScreenLinesStayOutOfTheBand()
    {
        var phone = Line("Incoming Call...", new NormRect(0.82, 0.90, 0.08, 0.02), 0);
        var middle = Line("We need to talk.", new NormRect(0.45, 0.54, 0.1, 0.03), 0);
        Assert.False(SubtitleBand.Holds(phone));
        Assert.False(SubtitleBand.Holds(middle));
        Assert.Null(SubtitleBand.Pick([phone, middle]));
    }
}
