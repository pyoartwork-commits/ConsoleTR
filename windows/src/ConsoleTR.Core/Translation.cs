using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace ConsoleTR.Core;

public interface ITranslationProvider
{
    Task<string> TranslateAsync(string text, CancellationToken cancellationToken);
    /// <summary>
    /// How many requests the engine can usefully work on at once. Requests beyond this only
    /// queue inside the engine, where the newest caption would wait behind stale ones.
    /// </summary>
    int MaxConcurrentRequests => int.MaxValue;
}

/// <summary>A failure whose message is ready to show to the user (Turkish).</summary>
public sealed class TranslationException(string message, Exception? inner = null) : Exception(message, inner);

/// <summary>Offline provider that marks text with "TR: ", for testing detection without translation latency.</summary>
public sealed class DemoProvider : ITranslationProvider
{
    public Task<string> TranslateAsync(string text, CancellationToken cancellationToken) => Task.FromResult("TR: " + text);
}

public static partial class SpeakerLabel
{
    [GeneratedRegex(@"^(?:\[[^\]]{1,48}\]\s*|[\p{L}][\p{L} .’'-]{0,38}:\s*)")]
    private static partial Regex Pattern();

    /// <summary>Splits "Kratos: Follow me." into the label (kept verbatim) and the dialogue.</summary>
    public static (string Label, string Dialogue) Split(string text)
    {
        var match = Pattern().Match(text);
        return match.Success ? (match.Value, text[match.Length..]) : ("", text);
    }
}

/// <summary>
/// Local LLM translation through Ollama on this computer. Gemma 4 E4B kept names, slang and
/// Turkish suffixes right in a 14-line Witcher/GTA sample. Text never leaves the machine.
/// </summary>
public sealed class OllamaTranslator : ITranslationProvider
{
    public const string DefaultModel = "gemma4:e4b-it-qat";
    private static readonly Uri DefaultEndpoint = new("http://localhost:11434/");
    private readonly HttpClient http;
    private readonly string[] names;

    public OllamaTranslator(string model = DefaultModel, string names = "", HttpClient? http = null)
    {
        Model = model;
        this.names = names.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        this.http = http ?? new HttpClient { BaseAddress = DefaultEndpoint, Timeout = TimeSpan.FromSeconds(30) };
    }

    public string Model { get; }
    // Ollama serves one request at a time on typical home hardware, and Gemma 4's
    // sliding-window attention rules out prompt caching, so every request costs 0.4–0.9 s.
    public int MaxConcurrentRequests => 1;

    /// <summary>Loads the model into memory so the first caption does not wait for it.</summary>
    public void Prewarm() => _ = http.PostAsJsonAsync("api/generate", new { model = Model, keep_alive = "30m" });

    public async Task<string> TranslateAsync(string text, CancellationToken cancellationToken)
    {
        // Speaker labels stay verbatim, as with the macOS providers.
        var (label, dialogue) = SpeakerLabel.Split(text);
        if (label.Length > 0 && dialogue.Trim().Length == 0) return text;
        string speaker = label.Trim().Trim('[', ']', ':').Trim();
        return label + await TranslateBody(dialogue, speaker, cancellationToken);
    }

    private async Task<string> TranslateBody(string text, string speaker, CancellationToken cancellationToken)
    {
        var kept = new List<string> { "Geralt", "Ciri", "Roach" };
        kept.AddRange(names);
        if (speaker.Length > 0) kept.Add(speaker);
        string instructions =
            "You translate English video game subtitles and quest objectives into natural, idiomatic Turkish (Türkiye). " +
            $"Keep character and place names unchanged ({string.Join(", ", kept)}). Keep \"witcher\" as \"Witcher\". " +
            "Match the speaker's tone, including slang and swearing. Use the imperative for objectives. " +
            "Reply with the Turkish translation only, no quotes, no notes.";
        var body = new
        {
            model = Model, stream = false, think = false, keep_alive = "30m",
            options = new { temperature = 0, num_predict = 256 },
            messages = new[] { new { role = "system", content = instructions }, new { role = "user", content = text } },
        };
        HttpResponseMessage response;
        try { response = await http.PostAsJsonAsync("api/chat", body, cancellationToken); }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException)
        {
            throw new TranslationException("Ollama’ya ulaşılamadı. Ollama uygulamasını açın veya komut isteminde “ollama serve” komutunu çalıştırın.", error);
        }
        using (response)
        {
            if (response.StatusCode == HttpStatusCode.NotFound)
                throw new TranslationException($"“{Model}” modeli Ollama’da yok. Komut isteminde “ollama pull {Model}” komutuyla indirin.");
            string? content = null;
            if (response.IsSuccessStatusCode)
            {
                try
                {
                    var json = JsonNode.Parse(await response.Content.ReadAsStringAsync(cancellationToken));
                    content = json?["message"]?["content"]?.GetValue<string>();
                }
                catch (JsonException) { }
            }
            if (content is null)
                throw new TranslationException($"Ollama geçerli bir çeviri döndürmedi (HTTP {(int)response.StatusCode}). Model adını kontrol edin.");
            string value = Clean(content);
            return value.Length > 0 ? value : throw new TranslationException("Ollama boş bir çeviri döndürdü. Başka bir model deneyin.");
        }
    }

    /// <summary>Models sometimes wrap the answer in quotes or add a note on a new line.</summary>
    public static string Clean(string output)
    {
        string value = output.Split(['\n', '\r'], StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.Trim() ?? "";
        (char, char)[] quotes = [('"', '"'), ('“', '”'), ('«', '»'), ('\'', '\'')];
        if (value.Length >= 2 && quotes.Any(q => value[0] == q.Item1 && value[^1] == q.Item2)) value = value[1..^1].Trim();
        return value;
    }
}

/// <summary>A LibreTranslate server chosen by the user. Detected text is sent to that server.</summary>
public sealed class LibreTranslateProvider : ITranslationProvider
{
    private readonly HttpClient http;
    private readonly Uri endpoint;

    public LibreTranslateProvider(string address, HttpClient? http = null)
    {
        if (!Uri.TryCreate(address, UriKind.Absolute, out var uri) || (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps))
            throw new TranslationException("Geçerli bir HTTP veya HTTPS hizmet adresi girin.");
        endpoint = uri;
        this.http = http ?? new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
    }

    public async Task<string> TranslateAsync(string text, CancellationToken cancellationToken)
    {
        var (label, dialogue) = SpeakerLabel.Split(text);
        if (label.Length > 0 && dialogue.Trim().Length == 0) return text;
        try
        {
            using var response = await http.PostAsJsonAsync(endpoint, new { q = dialogue, source = "en", target = "tr", format = "text" }, cancellationToken);
            var json = response.IsSuccessStatusCode ? JsonNode.Parse(await response.Content.ReadAsStringAsync(cancellationToken)) : null;
            string? value = json?["translatedText"]?.GetValue<string>();
            return !string.IsNullOrEmpty(value) ? label + value : throw new TranslationException("Çeviri sunucusu geçerli bir yanıt vermedi. Hizmet adresini kontrol edin.");
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException or JsonException)
        {
            throw new TranslationException("Çeviri sunucusuna ulaşılamadı. Hizmet adresini ve sunucuyu kontrol edin.", error);
        }
    }
}
