namespace ConsoleTR.Core;

/// <summary>Normalized rectangle in source coordinates (0...1), measured from the top left.</summary>
public readonly record struct NormRect(double X, double Y, double Width, double Height)
{
    public double MinX => X;
    public double MinY => Y;
    public double MaxX => X + Width;
    public double MaxY => Y + Height;
    public double MidX => X + Width / 2;
    public double MidY => Y + Height / 2;
    public double Area => Width * Height;

    // Touching edges do not count, matching CGRect.intersects on macOS.
    public bool Intersects(NormRect other) =>
        MinX < other.MaxX && other.MinX < MaxX && MinY < other.MaxY && other.MinY < MaxY;

    public NormRect? Intersection(NormRect other)
    {
        double x = Math.Max(MinX, other.MinX), y = Math.Max(MinY, other.MinY);
        double right = Math.Min(MaxX, other.MaxX), bottom = Math.Min(MaxY, other.MaxY);
        return right > x && bottom > y ? new NormRect(x, y, right - x, bottom - y) : null;
    }

    public NormRect Union(NormRect other)
    {
        double x = Math.Min(MinX, other.MinX), y = Math.Min(MinY, other.MinY);
        return new NormRect(x, y, Math.Max(MaxX, other.MaxX) - x, Math.Max(MaxY, other.MaxY) - y);
    }

    public NormRect Inflate(double dx, double dy) => new(X - dx, Y - dy, Width + 2 * dx, Height + 2 * dy);

    public bool Contains(NormRect other) =>
        other.MinX >= MinX && other.MaxX <= MaxX && other.MinY >= MinY && other.MaxY <= MaxY;
}
