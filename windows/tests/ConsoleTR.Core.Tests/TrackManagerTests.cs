using ConsoleTR.Core;

/// <summary>Engine whose answers the test releases by hand.</summary>
internal sealed class ManualEngine(int slots) : ITranslationProvider
{
    public readonly List<(string Text, TaskCompletionSource<string> Answer, CancellationToken Token)> Calls = [];
    public int MaxConcurrentRequests => slots;
    public Task<string> TranslateAsync(string text, CancellationToken cancellationToken)
    {
        var answer = new TaskCompletionSource<string>();
        cancellationToken.Register(() => answer.TrySetCanceled(cancellationToken));
        Calls.Add((text, answer, cancellationToken));
        return answer.Task;
    }
    public void Answer(string text) => Calls.Last(c => c.Text == text && !c.Answer.Task.IsCompleted).Answer.SetResult("TR: " + text);
    public IEnumerable<string> Open => Calls.Where(c => !c.Answer.Task.IsCompleted).Select(c => c.Text);
}

public class TrackManagerTests
{
    private double now = 100;
    private static readonly NormRect Caption = new(0.3, 0.85, 0.4, 0.04);
    private static Detection Sub(string text) => new(TextRole.Subtitle, text, Caption);
    private static Detection Goal(string text, double y = 0.2) => new(TextRole.Objective, text, new NormRect(0.75, y, 0.2, 0.03));

    [Fact]
    public void SingleSlotEngineGivesTheNewCaptionPriority()
    {
        var engine = new ManualEngine(1);
        var manager = new TrackManager(engine, () => now);
        var goals = new[] { Goal("Find the key", 0.20), Goal("Reach the garage", 0.25), Goal("Retrieve the package", 0.30) };
        manager.Receive(goals);
        Assert.Single(engine.Open);
        manager.Receive([.. goals, Sub("Kratos: Open the door.")]);
        // The objective request is cancelled and the slot goes to the caption.
        Assert.Equal(["Kratos: Open the door."], engine.Open);
        engine.Answer("Kratos: Open the door.");
        Assert.Equal("TR: Kratos: Open the door.", manager.Tracks.Single(t => t.Line.Role == TextRole.Subtitle).Value);
        // Objectives follow one at a time.
        Assert.Single(engine.Open);
        Assert.Equal(1, manager.PendingCount);
    }

    [Fact]
    public void UnlimitedEngineRequestsEverythingAtOnce()
    {
        var engine = new ManualEngine(int.MaxValue);
        var manager = new TrackManager(engine, () => now);
        manager.Receive([Goal("Find the key", 0.2), Goal("Reach the garage", 0.3), Sub("Follow me.")]);
        Assert.Equal(3, engine.Open.Count());
    }

    [Fact]
    public void TranslationStaysReadableAfterItsLineIsGone()
    {
        var engine = new ManualEngine(1);
        var manager = new TrackManager(engine, () => now);
        manager.Receive([Sub("Kratos: Open the door.")]);
        engine.Answer("Kratos: Open the door.");
        now += 0.4;
        manager.Receive([]);
        now += 1.2;
        manager.Tick();
        Assert.Contains(manager.Tracks, t => t.Value == "TR: Kratos: Open the door.");
        Assert.Empty(manager.OnScreen);
        now += Track.ReadingTime("TR: Kratos: Open the door.");
        manager.Tick();
        Assert.Empty(manager.Tracks);
    }

    [Fact]
    public void NewCaptionReplacesTheOldOneWithoutAGap()
    {
        var engine = new ManualEngine(1);
        var manager = new TrackManager(engine, () => now);
        manager.Receive([Sub("Wait for me.")]);
        engine.Answer("Wait for me.");
        now += 0.3;
        manager.Receive([Sub("Follow me.")]);
        // The old translation stays while the new one is being translated.
        Assert.Contains(manager.Tracks, t => t.Value == "TR: Wait for me.");
        engine.Answer("Follow me.");
        Assert.Equal(["TR: Follow me."], manager.Tracks.Select(t => t.Value).OfType<string>());
        Assert.Equal(["Follow me.", "Wait for me."], manager.Recent.Select(r => r.Original));
    }

    [Fact]
    public void UntranslatedLineIsReplacedAtOnce()
    {
        var engine = new ManualEngine(1);
        var manager = new TrackManager(engine, () => now);
        manager.Receive([Sub("Wait for me.")]);
        manager.Receive([Sub("Follow me.")]);
        Assert.Equal(["Follow me."], manager.Tracks.Select(t => t.Line.Text));
        Assert.Equal(["Follow me."], engine.Open);
    }

    [Fact]
    public void OcrVariantKeepsTheTrackAndItsTranslation()
    {
        var engine = new ManualEngine(1);
        var manager = new TrackManager(engine, () => now);
        manager.Receive([Sub("Oh, Geralt. I didn't expect to see you here")]);
        var id = manager.Tracks.Single().Id;
        engine.Answer("Oh, Geralt. I didn't expect to see you here");
        manager.Receive([Sub("h.IGeralt. I didn't expect to see you here")]);
        Assert.Equal(id, manager.Tracks.Single().Id);
        Assert.NotNull(manager.Tracks.Single().Value);
        Assert.Empty(engine.Open);
    }

    [Fact]
    public void RecentListKeepsTheLatestEight()
    {
        // Distinct lines; near-identical ones would count as OCR variants of one line.
        string[] lines = ["Follow me.", "Open the door.", "Wind's howling.", "Lose the cops.", "Take the shot!", "Don't push your luck.",
                          "Damn it, Roach, not now!", "Go to Lester's house.", "We need to talk about Ciri.", "You better not be late.",
                          "Kill the drowners near the mill.", "Get in the car."];
        var manager = new TrackManager(new DemoProvider(), () => now);
        foreach (var line in lines) manager.Receive([Sub(line)]);
        Assert.Equal(8, manager.Recent.Count);
        Assert.Equal("Get in the car.", manager.Recent[0].Original);
    }

    [Fact]
    public void EngineFailureIsReported()
    {
        var engine = new ManualEngine(1);
        var manager = new TrackManager(engine, () => now);
        Exception? failure = null;
        manager.Failed += e => failure = e;
        manager.Receive([Sub("Follow me.")]);
        engine.Calls[0].Answer.SetException(new TranslationException("Ollama’ya ulaşılamadı."));
        Assert.IsType<TranslationException>(failure);
    }
}
