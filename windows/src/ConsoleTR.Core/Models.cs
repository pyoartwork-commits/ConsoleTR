namespace ConsoleTR.Core;

public enum TextRole { Subtitle, Objective }

public static class TextRoleExtensions
{
    public static string DisplayName(this TextRole role) => role == TextRole.Subtitle ? "Altyazı" : "Görev";
}

/// <summary>A caption or objective line found in a frame.</summary>
public sealed record Detection(TextRole Role, string Text, NormRect Box);

/// <summary>One line as returned by OCR, before classification.</summary>
public sealed record OcrLine(string Text, NormRect Box);

/// <summary>A scanned part of the frame. A null role means automatic classification.</summary>
public sealed record ScanZone(TextRole? Role, NormRect Rect)
{
    public static ScanZone Whole { get; } = new(null, new NormRect(0, 0, 1, 1));
}

public sealed record RecentTranslation(string Key, string Original, string Translation);
