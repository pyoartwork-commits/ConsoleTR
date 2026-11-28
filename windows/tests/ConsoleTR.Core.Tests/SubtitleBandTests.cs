using ConsoleTR.Core;

public class SubtitleBandTests
{
    private static Track Line(string text, NormRect box, double since, string? value = "TR") =>
        new(new Detection(TextRole.Subtitle, text, box), value is null ? null : value + ": " + text, since);

    [Fact]
    public void BandShowsTheNewestTranslatedCaption()
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
        var standing = Line("Stay with me.", new NormRect(0.4, 0.72, 0.2, 0.03), 0);
        var previous = Line("Hey, man, I spoke to Brian.", new NormRect(0.35, 0.86, 0.3, 0.03), 5);
        var next = Line("He says he wants to talk to you personally", new NormRect(0.3, 0.86, 0.4, 0.03), 6, value: null);
        Assert.Same(previous, SubtitleBand.Pick([standing, previous, next]));
    }

    [Fact]
    public void CaptionsReadAnywhereGoToTheBandButObjectivesDoNot()
    {
        // A caption read mid-screen or in a corner must not get an overlay of its own there.
        var middle = Line("We need to talk.", new NormRect(0.45, 0.45, 0.1, 0.03), 1);
        var corner = Line("Incoming Call...", new NormRect(0.82, 0.90, 0.08, 0.02), 2);
        var goal = new Track(new Detection(TextRole.Objective, "Find the key", new NormRect(0.75, 0.2, 0.2, 0.03)), "TR: Find the key", 3);
        Assert.True(SubtitleBand.Holds(middle));
        Assert.True(SubtitleBand.Holds(corner));
        Assert.False(SubtitleBand.Holds(goal));
        Assert.Same(corner, SubtitleBand.Pick([middle, corner, goal]));
    }
}
