namespace ConsoleTR.Core;

/// <summary>
/// Follows detected lines across frames, decides what to translate and when a translation
/// leaves the screen. UI-independent port of Controller.receive and requestTranslations in
/// macos/Sources/Controller.swift. Call it from one thread; translation results continue on
/// the caller's synchronization context.
/// </summary>
public sealed class TrackManager(ITranslationProvider engine, Func<double> clock)
{
    private readonly List<Track> tracks = [];
    private readonly Dictionary<Guid, double> expiry = [];
    private readonly Dictionary<string, CancellationTokenSource> pending = new(StringComparer.Ordinal);
    private readonly TranslationHistory history = new();
    private readonly List<RecentTranslation> recent = [];
    private int generation;

    /// <summary>All tracks, including ones whose line is gone but whose translation is still shown.</summary>
    public IReadOnlyList<Track> Tracks => tracks;
    public IEnumerable<Track> OnScreen => tracks.Where(t => !expiry.ContainsKey(t.Id));
    public IReadOnlyList<RecentTranslation> Recent => recent;
    public int Translations { get; private set; }
    public int Hits { get; private set; }
    public double LastTranslationMs { get; private set; }
    /// <summary>Size of the captured area in pixels; small moves below 1.5 px are ignored.</summary>
    public (double Width, double Height) AnchorSize { get; set; } = (1600, 900);
    public int PendingCount => pending.Count;

    /// <summary>Raised after tracks or translations change.</summary>
    public event Action? Changed;
    /// <summary>Raised when the engine fails for a reason other than cancellation.</summary>
    public event Action<Exception>? Failed;

    public void Receive(IReadOnlyList<Detection> lines)
    {
        Expire();
        double now = clock();
        var remaining = new List<Track>(tracks);
        var next = new List<Track>();
        foreach (var line in lines)
        {
            // Match the closest occurrence; identical text can appear in two places.
            string key = Track.Key(line.Text);
            Track? matched = remaining.Where(t => t.Line.Role == line.Role && t.TranslationKey == key)
                .OrderBy(t => Distance(t.Line.Box, line.Box)).FirstOrDefault();
            // An OCR variant of a line at the same place keeps that line's track, overlay and
            // pending translation. Its role can flip with the misread, so ignore role.
            matched ??= remaining
                .Where(t => t.Line.Box.Inflate(t.Line.Box.Height, t.Line.Box.Height * 0.5).Intersects(line.Box))
                .Select(t => (Track: t, Score: Track.Similarity(t.TranslationKey, key)))
                .Where(p => p.Score >= 0.6).OrderByDescending(p => p.Score).Select(p => p.Track).FirstOrDefault();
            if (matched is not null)
            {
                remaining.Remove(matched);
                expiry.Remove(matched.Id);
                var old = matched.Line.Box;
                double shift = Math.Max(Math.Abs(old.MidX - line.Box.MidX) * AnchorSize.Width, Math.Abs(old.MidY - line.Box.MidY) * AnchorSize.Height);
                matched.Observe(line.Text);
                if (shift >= 1.5 || Math.Abs(old.Width - line.Box.Width) > 0.004) matched.Line = matched.Line with { Box = line.Box };
                next.Add(matched);
            }
            else
            {
                string? cached = history.Cached(key);
                if (cached is not null) Hits++;
                next.Add(new Track(line, cached, now));
            }
        }
        foreach (var lost in remaining)
        {
            // Without a translation there is nothing to read, so a replacement wins at once.
            bool replaced = lines.Any(l => l.Role == lost.Line.Role && l.Box.Intersects(lost.Line.Box));
            if (replaced && lost.Value is null)
            {
                expiry.Remove(lost.Id);
                continue;
            }
            next.Add(lost);
            if (expiry.ContainsKey(lost.Id)) continue;
            // A missed OCR sample gets 650 ms. A shown translation stays until it has been on
            // screen for its reading time, or until a newer translation takes its place.
            double delay = lost is { Value: { } value, ShownAt: { } shownAt } ? Math.Max(0.65, Track.ReadingTime(value) - (now - shownAt)) : 0.65;
            expiry[lost.Id] = now + delay;
        }
        tracks.Clear();
        tracks.AddRange(next);
        Render();
        RequestTranslations();
    }

    /// <summary>Applies expiries that fall between frames. Call regularly, e.g. once per frame.</summary>
    public void Tick()
    {
        if (Expire())
        {
            Render();
            RequestTranslations();
        }
    }

    /// <summary>Drops every track and cancels all requests, e.g. when the overlay is turned off.</summary>
    public void Clear()
    {
        generation++;
        foreach (var source in pending.Values) source.Cancel();
        pending.Clear();
        tracks.Clear();
        expiry.Clear();
        Changed?.Invoke();
    }

    private bool Expire()
    {
        double now = clock();
        var due = expiry.Where(e => e.Value <= now).Select(e => e.Key).ToList();
        foreach (var id in due) expiry.Remove(id);
        return tracks.RemoveAll(t => due.Contains(t.Id)) > 0;
    }

    private void Render()
    {
        // A newer translation over the place of a line that is gone replaces it.
        var onScreen = OnScreen.ToList();
        var covered = tracks.Where(old => expiry.ContainsKey(old.Id) &&
            onScreen.Any(t => t.Value is not null && t.Line.Box.Intersects(old.Line.Box))).Select(t => t.Id).ToHashSet();
        foreach (var id in covered) expiry.Remove(id);
        if (covered.Count > 0) tracks.RemoveAll(t => covered.Contains(t.Id));
        // Keep the latest pairs so a translation can be checked after it is gone.
        foreach (var track in onScreen)
        {
            if (track is not { Value: { } value, ValueKey: { } key } || recent.Any(r => r.Key == key)) continue;
            recent.Insert(0, new RecentTranslation(key, track.Line.Text, value));
            if (recent.Count > 8) recent.RemoveAt(recent.Count - 1);
        }
        Changed?.Invoke();
    }

    // Lines on screen first, then untranslated ones, captions before objectives.
    private (int, int, int) Priority(Track track) =>
        (expiry.ContainsKey(track.Id) ? 0 : 1, track.Value is null ? 1 : 0, track.Line.Role == TextRole.Subtitle ? 1 : 0);

    private (int, int, int) KeyPriority(string key) =>
        tracks.Where(t => t.TranslationKey == key || t.RequestedKey == key).Select(Priority).DefaultIfEmpty((-1, -1, -1)).Max();

    private void RequestTranslations()
    {
        // Keep a request while its track exists, even if a newer reading came in since.
        var wanted = tracks.SelectMany(t => new[] { t.TranslationKey, t.RequestedKey }).OfType<string>().ToHashSet(StringComparer.Ordinal);
        foreach (var key in pending.Keys.Where(k => !wanted.Contains(k)).ToList()) Cancel(key);
        bool reused = false;
        foreach (var track in tracks.Where(t => t.NeedsTranslation))
        {
            // A switch to a reading translated earlier needs no new request.
            if (history.Cached(track.TranslationKey) is not { } cached) continue;
            track.SetValue(cached, track.TranslationKey, clock());
            Hits++;
            reused = true;
        }
        if (reused) Render();
        // With a single-slot engine (Ollama) every queued request delays the next caption, so
        // the newest caption on screen goes first and anything less important yields to it.
        var queue = tracks.Where(t => t.NeedsTranslation)
            .OrderByDescending(Priority).ThenByDescending(t => t.Since).ToList();
        foreach (var track in queue)
        {
            if (pending.ContainsKey(track.TranslationKey)) continue;
            if (pending.Count >= engine.MaxConcurrentRequests)
            {
                string weakest = pending.Keys.MinBy(KeyPriority)!;
                if (KeyPriority(weakest).CompareTo(Priority(track)) >= 0) break;
                Cancel(weakest);
            }
            Request(track);
        }
    }

    private void Cancel(string key)
    {
        if (pending.Remove(key, out var source)) source.Cancel();
    }

    private void Request(Track track)
    {
        string text = track.Line.Text, key = track.TranslationKey;
        foreach (var t in tracks.Where(t => t.TranslationKey == key)) t.RequestedKey = key;
        var source = new CancellationTokenSource();
        pending[key] = source;
        _ = Run(text, key, source, generation);
    }

    private async Task Run(string text, string key, CancellationTokenSource source, int token)
    {
        double start = clock();
        try
        {
            string value = await engine.TranslateAsync(text, source.Token);
            if (source.IsCancellationRequested || token != generation) return;
            pending.Remove(key);
            history.Save(key, value);
            Translations++;
            LastTranslationMs = (clock() - start) * 1000;
            // A track whose reading changed while waiting shows this result until the newer
            // reading is translated.
            foreach (var t in tracks.Where(t => t.TranslationKey == key || (t.RequestedKey == key && t.NeedsTranslation)))
                t.SetValue(value, key, clock());
            Render();
            RequestTranslations();
        }
        catch (OperationCanceledException) when (source.IsCancellationRequested || token != generation) { }
        catch (Exception error) when (!source.IsCancellationRequested && token == generation)
        {
            pending.Remove(key);
            Failed?.Invoke(error);
        }
        // The source is not disposed here: cancellation can complete this method inside
        // source.Cancel() itself. It holds no timer, so the GC reclaims it.
    }

    private static double Distance(NormRect a, NormRect b) => Math.Sqrt(Math.Pow(a.MidX - b.MidX, 2) + Math.Pow(a.MidY - b.MidY, 2));
}
