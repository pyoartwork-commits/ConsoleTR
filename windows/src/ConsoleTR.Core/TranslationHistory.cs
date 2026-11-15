namespace ConsoleTR.Core;

/// <summary>Recent translations by key, oldest dropped first. In memory only.</summary>
public sealed class TranslationHistory(int capacity = 256)
{
    private readonly Dictionary<string, string> cache = new(StringComparer.Ordinal);
    private readonly Queue<string> order = new();

    public string? Cached(string key) => cache.GetValueOrDefault(key);

    public void Save(string key, string value)
    {
        if (!cache.ContainsKey(key))
        {
            if (order.Count >= capacity) cache.Remove(order.Dequeue());
            order.Enqueue(key);
        }
        cache[key] = value;
    }
}
