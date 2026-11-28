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
    public void ClippedReadingsDoNotMoveTheOverlay()
    {
        var manager = new TrackManager(new DemoProvider(), () => now);
        const string full = "Lamar: Man, what you doin' here, dog? Get in the car.";
        var box = new NormRect(0.28, 0.85, 0.44, 0.04);
        manager.Receive([new Detection(TextRole.Subtitle, full, box)]);
        // A colored speaker name or a bright background drops part of the line on some frames.
        var clipped = new[]
        {
            new Detection(TextRole.Subtitle, "Man, what you doin' here, dog? Get in the car.", new NormRect(0.335, 0.85, 0.385, 0.04)),
            new Detection(TextRole.Subtitle, "Lamar: Man, what you doin' here, dog?", new NormRect(0.28, 0.85, 0.31, 0.04)),
        };
        foreach (var reading in clipped.Concat(clipped).Concat(clipped)) manager.Receive([reading]);
        var track = Assert.Single(manager.Tracks);
        Assert.Equal(box, track.Line.Box);
        Assert.Equal(full, track.Line.Text);
        Assert.Equal("TR: " + full, track.Value);
    }

    [Fact]
    public void SmallJitterIsIgnoredButARealMoveIsFollowed()
    {
        var manager = new TrackManager(new DemoProvider(), () => now);
        var box = new NormRect(0.70, 0.20, 0.15, 0.03);
        manager.Receive([new Detection(TextRole.Objective, "Find the key", box)]);
        // 2 px of OCR jitter on a 1600 x 900 capture.
        manager.Receive([new Detection(TextRole.Objective, "Find the key", box with { X = box.X + 2.0 / 1600, Width = box.Width - 1.0 / 1600 })]);
        Assert.Equal(box, manager.Tracks.Single().Line.Box);
        // The objective really moves 48 px to the right.
        var moved = box with { X = box.X + 48.0 / 1600 };
        manager.Receive([new Detection(TextRole.Objective, "Find the key", moved)]);
        Assert.Equal(moved, manager.Tracks.Single().Line.Box);
        // A moved line read slightly differently is followed at once, before any vote.
        var again = moved with { X = moved.X + 48.0 / 1600 };
        manager.Receive([new Detection(TextRole.Objective, "Find the keya", again)]);
        Assert.Equal(again, manager.Tracks.Single().Line.Box);
        Assert.Equal("Find the key", manager.Tracks.Single().Line.Text);
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
