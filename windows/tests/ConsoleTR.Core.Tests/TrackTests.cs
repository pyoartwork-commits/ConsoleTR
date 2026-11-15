using ConsoleTR.Core;

public class TrackTests
{
    [Fact]
    public void KeyIgnoresCaseCommasAndPeriods() => Assert.Equal("oh geralt", Track.Key("Oh, Geralt."));

    [Theory]
    [InlineData("the baron's men passed through the village yesterday", "terday", 1.0)]
    [InlineData("oh geralt i didn't expect to see you here", "h.igeralt i didn't expect to see you here", 0.85)]
    [InlineData("you better not be late", "go to the garage", 0.0)]
    public void Similarity(string a, string b, double atLeast)
    {
        double score = Track.Similarity(a, b);
        if (atLeast == 0) Assert.True(score < 0.6, $"{score}");
        else Assert.True(score >= atLeast, $"{score}");
    }

    [Fact]
    public void ReadingTimeGrowsWithLengthAndIsCapped()
    {
        Assert.Equal(1.5 + 0.06 * 10, Track.ReadingTime("0123456789"), 6);
        Assert.Equal(6, Track.ReadingTime(new string('a', 500)));
    }
}
