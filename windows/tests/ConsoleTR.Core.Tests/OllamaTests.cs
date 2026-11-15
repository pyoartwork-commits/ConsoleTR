using System.Net;
using System.Text;
using ConsoleTR.Core;

internal sealed class StubHandler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
{
    public readonly List<string> Bodies = [];
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        Bodies.Add(request.Content is null ? "" : await request.Content.ReadAsStringAsync(cancellationToken));
        return respond(request);
    }
}

public class OllamaTests
{
    private static HttpClient Client(StubHandler handler) => new(handler) { BaseAddress = new Uri("http://localhost:11434/") };
    private static HttpResponseMessage Json(string json, HttpStatusCode code = HttpStatusCode.OK) =>
        new(code) { Content = new StringContent(json, Encoding.UTF8, "application/json") };

    [Theory]
    [InlineData("\"Geç kalma, dostum.\"", "Geç kalma, dostum.")]
    [InlineData("“Ateş et!”", "Ateş et!")]
    [InlineData("Polislerden kaç.\n(Note: informal)", "Polislerden kaç.")]
    [InlineData("  Lester'ın evine git.  ", "Lester'ın evine git.")]
    public void CleanStripsQuotesAndNotes(string raw, string expected) => Assert.Equal(expected, OllamaTranslator.Clean(raw));

    [Fact]
    public async Task SpeakerLabelIsKeptAndNotSent()
    {
        var handler = new StubHandler(_ => Json("""{"message":{"role":"assistant","content":"\"Atreus'u takip et.\""}}"""));
        var translator = new OllamaTranslator(names: "Atreus", http: Client(handler));
        Assert.Equal("Kratos: Atreus'u takip et.", await translator.TranslateAsync("Kratos: Follow Atreus.", default));
        Assert.Contains("\"content\":\"Follow Atreus.\"", handler.Bodies.Single());
        Assert.Contains("Kratos", handler.Bodies.Single());
    }

    [Fact]
    public async Task MissingModelExplainsHowToPullIt()
    {
        var translator = new OllamaTranslator("consoletr-missing", http: Client(new StubHandler(_ => Json("{}", HttpStatusCode.NotFound))));
        var error = await Assert.ThrowsAsync<TranslationException>(() => translator.TranslateAsync("Follow me.", default));
        Assert.Contains("ollama pull consoletr-missing", error.Message);
    }

    [Fact]
    public async Task UnreachableServerExplainsHowToStartIt()
    {
        var translator = new OllamaTranslator(http: Client(new StubHandler(_ => throw new HttpRequestException("refused"))));
        var error = await Assert.ThrowsAsync<TranslationException>(() => translator.TranslateAsync("Follow me.", default));
        Assert.Contains("ollama serve", error.Message);
    }

    [Fact]
    public void OllamaHasASingleSlotAndOthersAreUnlimited()
    {
        Assert.Equal(1, ((ITranslationProvider)new OllamaTranslator()).MaxConcurrentRequests);
        Assert.Equal(int.MaxValue, ((ITranslationProvider)new DemoProvider()).MaxConcurrentRequests);
    }

    [Fact]
    public void LibreTranslateRejectsNonHttpAddresses() =>
        Assert.Throws<TranslationException>(() => new LibreTranslateProvider("file:///etc/passwd"));
}
