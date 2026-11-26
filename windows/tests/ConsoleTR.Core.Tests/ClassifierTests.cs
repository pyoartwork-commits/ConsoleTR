using System.Globalization;
using ConsoleTR.Core;

public class ClassifierTests
{
    private static readonly NormRect BottomCentre = new(0.46, 0.845, 0.08, 0.03);
    private static readonly NormRect TopRight = new(0.78, 0.20, 0.16, 0.03);

    [Theory]
    [InlineData("Oh, Geralt", TextRole.Subtitle)]
    [InlineData("Oh, Geralt.", TextRole.Subtitle)]
    [InlineData("come back to Kaer Morhen", TextRole.Subtitle)]
    [InlineData("Kratos: Open the door.", TextRole.Subtitle)]
    [InlineData("The Witcher Wild Hunt", null)]
    [InlineData("itcher Wild Hunt", null)]
    [InlineData("e Witcher Wild Hunt", null)]
    [InlineData("The Witche,Wild", null)]
    [InlineData("Press X to continue", null)]
    [InlineData("CPU: 5.0%", null)]
    public void BottomCentreLines(string text, TextRole? expected) =>
        Assert.Equal(expected, GameTextClassifier.Classify(text, BottomCentre));

    [Theory]
    [InlineData("Find the key", TextRole.Objective)]
    [InlineData("Quest Updated", TextRole.Objective)]
    [InlineData("Wandering in the Dark", null)]
    public void TrackerLines(string text, TextRole? expected) =>
        Assert.Equal(expected, GameTextClassifier.Classify(text, TopRight));

    [Fact]
    public void TurkishCultureDoesNotBreakEnglishKeywords()
    {
        // On tr-TR, culture-aware lowering turns "I" into "ı" and "Investigate" would no longer
        // match the action verb list.
        var saved = CultureInfo.CurrentCulture;
        try
        {
            CultureInfo.CurrentCulture = new CultureInfo("tr-TR");
            Assert.Equal(TextRole.Objective, GameTextClassifier.Classify("Investigate the cave", TopRight));
            Assert.Equal(TextRole.Objective, GameTextClassifier.Classify("QUEST UPDATED", TopRight));
            Assert.Equal(Track.Key("I SAID WAIT"), "i said wait");
        }
        finally { CultureInfo.CurrentCulture = saved; }
    }

    [Fact]
    public void LongNonEnglishLinesAreIgnored() =>
        Assert.Null(GameTextClassifier.Classify("Bunu yapmamız gerekiyor şimdi hemen", BottomCentre));
}
