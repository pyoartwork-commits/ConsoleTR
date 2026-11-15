using System.Text.RegularExpressions;

namespace ConsoleTR.Core;

/// <summary>
/// Decides whether an OCR line is a caption, an objective or neither. Mirrors
/// GameTextClassifier in macos/Sources/Core.swift; keep the two in step.
/// All casing uses the invariant culture: on Turkish Windows "I".ToLower() is "ı",
/// which would break every English keyword below.
/// </summary>
public static partial class GameTextClassifier
{
    private static readonly HashSet<string> Actions = new(StringComparer.Ordinal)
    {
        "find", "reach", "meet", "locate", "collect", "return", "deliver", "retrieve", "defeat", "kill", "escort",
        "protect", "escape", "investigate", "search", "enter", "leave", "drive", "steal", "take", "use", "get",
        "follow", "talk", "go", "destroy", "rescue", "complete", "visit", "travel", "recover", "eliminate", "look", "wait",
    };
    private static readonly string[] Headings =
        ["objective", "quest", "mission", "new objective", "new quest", "quest updated", "mission passed", "mission failed", "optional objective"];
    private static readonly string[] Controls = ["press ", "hold ", "click ", "fps ", "consoletr", "tr:"];
    private static readonly HashSet<string> Pronouns = new(StringComparer.Ordinal) { "i", "we", "you", "me", "our", "my", "your", "they" };
    // macOS uses NLLanguageRecognizer; .NET has no built-in language identification,
    // so long lines must contain at least one common English function word.
    private static readonly HashSet<string> EnglishMarkers = new(StringComparer.Ordinal)
    {
        "the", "a", "an", "to", "of", "and", "is", "are", "was", "it", "in", "on", "for", "with", "that", "this",
        "be", "not", "do", "have", "what", "i", "you", "we", "me", "my", "your", "he", "she", "they", "at", "or",
    };

    [GeneratedRegex(@"^[A-Z][A-Za-z '’-]{0,28}:\s*\S")]
    private static partial Regex SpeakerLabel();

    public static TextRole? Classify(string text, NormRect box)
    {
        string lower = text.Trim().ToLowerInvariant();
        var words = Words(lower);
        if (words.Count == 0 || Controls.Any(c => lower.StartsWith(c, StringComparison.Ordinal))) return null;
        if (words.Count >= 5 && !words.Any(EnglishMarkers.Contains)) return null;
        if (Headings.Any(h => lower == h || lower.StartsWith(h + ":", StringComparison.Ordinal) || lower.StartsWith(h + " ", StringComparison.Ordinal)))
            return TextRole.Objective;
        if (SpeakerLabel().IsMatch(text)) return TextRole.Subtitle;
        bool punctuated = lower.Length > 0 && ".!?…".Contains(lower[^1]);
        bool conversational = words.Any(Pronouns.Contains);
        if (conversational && (punctuated || words.Count >= 3)) return TextRole.Subtitle;
        if (words.Count >= 2 && Actions.Contains(words[0]))
        {
            if (box.MidY >= 0.65 && punctuated && Math.Abs(box.MidX - 0.5) < 0.30) return TextRole.Subtitle;
            return TextRole.Objective;
        }
        if (punctuated && (box.MidY >= 0.40 || words.Count >= 3)) return TextRole.Subtitle;
        // Unpunctuated captions in the bottom centre. Runs where every word is capitalised
        // ("The Witcher Wild Hunt") are menu titles; the first word is skipped because OCR
        // often clips it. A comma followed by a space marks short lines such as "Oh, Geralt".
        if (box.MidY >= 0.63 && Math.Abs(box.MidX - 0.5) < 0.28 && text != text.ToUpperInvariant())
        {
            bool titleCased = !text.Split(' ', StringSplitOptions.RemoveEmptyEntries).Skip(1).Any(w => char.IsLower(w[0]));
            if (words.Count >= 3 && !titleCased) return TextRole.Subtitle;
            if (words.Count >= 2 && text.Contains(", ", StringComparison.Ordinal)) return TextRole.Subtitle;
        }
        return null;
    }

    // Letter runs, as Swift's split { !$0.isLetter } produces them.
    internal static List<string> Words(string lower)
    {
        var words = new List<string>();
        int start = -1;
        for (int i = 0; i <= lower.Length; i++)
        {
            bool letter = i < lower.Length && char.IsLetter(lower[i]);
            if (letter && start < 0) start = i;
            else if (!letter && start >= 0) { words.Add(lower[start..i]); start = -1; }
        }
        return words;
    }
}
