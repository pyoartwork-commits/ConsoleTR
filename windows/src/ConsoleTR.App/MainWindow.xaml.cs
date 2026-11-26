using System.Windows;
using System.Windows.Interop;
using ConsoleTR.Core;

namespace ConsoleTR.App;

public partial class MainWindow : Window
{
    private const int HotkeyId = 1;
    private LiveSession? session;
    private HwndSource? source;

    public MainWindow()
    {
        InitializeComponent();
        ModelBox.Text = OllamaTranslator.DefaultModel;
        UpdateProviderFields();
        RefreshWindows();
        SourceInitialized += (_, _) => InstallHotkey();
        Closed += (_, _) =>
        {
            session?.Stop();
            if (source is not null) Native.UnregisterHotKey(source.Handle, HotkeyId);
        };
    }

    private void RefreshWindows()
    {
        var items = TargetWindows.List();
        WindowCombo.ItemsSource = items;
        WindowCombo.SelectedIndex = items.Count > 0 ? 0 : -1;
        StatusText.Text = items.Count == 0 ? "Açık pencere bulunamadı." : "Pencereler hazır.";
    }

    private void InstallHotkey()
    {
        source = HwndSource.FromHwnd(new WindowInteropHelper(this).Handle);
        source.AddHook((IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled) =>
        {
            if (message == Native.WM_HOTKEY && wParam.ToInt32() == HotkeyId)
            {
                ShowCheck.IsChecked = ShowCheck.IsChecked != true;
                ApplyEnabled();
                handled = true;
            }
            return IntPtr.Zero;
        });
        if (!Native.RegisterHotKey(source.Handle, HotkeyId, Native.MOD_CONTROL | Native.MOD_ALT | Native.MOD_NOREPEAT, Native.VK_T))
            StatusText.Text = "Ctrl + Alt + T kaydedilemedi. Çeviriyi bu pencereden açıp kapatabilirsiniz.";
    }

    private void RefreshButton_Click(object sender, RoutedEventArgs e) => RefreshWindows();

    private void ScanMode_Changed(object sender, RoutedEventArgs e)
    {
        // Also raised while the window is still being built; later controls may not exist yet.
        if (ManualPanel is null || ManualRadio is null) return;
        ManualPanel.Visibility = ManualRadio.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ProviderCombo_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e) => UpdateProviderFields();

    private void UpdateProviderFields()
    {
        if (ModelPanel is null || AddressPanel is null || NamesPanel is null || ProviderNote is null || ModelBox is null) return;
        int choice = ProviderCombo.SelectedIndex;
        ModelPanel.Visibility = choice == 0 ? Visibility.Visible : Visibility.Collapsed;
        AddressPanel.Visibility = choice == 1 ? Visibility.Visible : Visibility.Collapsed;
        NamesPanel.Visibility = choice == 0 ? Visibility.Visible : Visibility.Collapsed;
        ProviderNote.Text = choice switch
        {
            0 => "Çeviri bu bilgisayarda Ollama ile yapılır, metin dışarı gönderilmez. Ollama açık olmalı; model yoksa komut isteminde “ollama pull " + ModelBox.Text + "” ile indirin.",
            1 => "Algılanan metin seçtiğiniz sunucuya gönderilir.",
            _ => "Demo, algılanan metnin başına “TR:” ekler. Algılamayı çeviri gecikmesinden ayrı denemek içindir.",
        };
    }

    private OverlayStyle CurrentStyle() => new(FontSlider.Value, 4, OpacitySlider.Value, SubtitleBand: BandCheck.IsChecked == true);

    private void BandCheck_Click(object sender, RoutedEventArgs e)
    {
        if (session is not null) session.Style = CurrentStyle();
    }

    private void Style_Changed(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (session is not null) session.Style = CurrentStyle();
    }

    private void ShowCheck_Click(object sender, RoutedEventArgs e) => ApplyEnabled();

    private void ApplyEnabled()
    {
        if (session is not null) session.Enabled = ShowCheck.IsChecked == true;
    }

    private void StartButton_Click(object sender, RoutedEventArgs e)
    {
        if (session is { Running: true })
        {
            session.Stop();
            Finish("Durduruldu.");
            return;
        }
        if (WindowCombo.SelectedItem is not WindowItem target) { StatusText.Text = "Önce bir pencere seçin."; return; }
        try
        {
            var zones = BuildZones();
            ITranslationProvider provider = ProviderCombo.SelectedIndex switch
            {
                0 => new OllamaTranslator(string.IsNullOrWhiteSpace(ModelBox.Text) ? throw new TranslationException("Ollama model adını girin.") : ModelBox.Text.Trim(), NamesBox.Text),
                1 => new LibreTranslateProvider(AddressBox.Text.Trim()),
                _ => new DemoProvider(),
            };
            session = new LiveSession(target.Handle, zones, provider, WindowsOcr.Create()) { Style = CurrentStyle(), Enabled = ShowCheck.IsChecked == true };
        }
        catch (Exception error) when (error is TranslationException or InvalidOperationException or FormatException)
        {
            StatusText.Text = error.Message;
            return;
        }
        session.StatusChanged += text => StatusText.Text = text;
        session.Stopped += () => Finish(null);
        session.Updated += ShowProgress;
        SetupPanel.IsEnabled = false;
        StartButton.Content = "Durdur";
        session.Start();
    }

    private IReadOnlyList<ScanZone> BuildZones()
    {
        if (AutoRadio.IsChecked == true) return [ScanZone.Whole];
        int Read(System.Windows.Controls.TextBox box) =>
            int.TryParse(box.Text, out int value) ? value : throw new FormatException("Alan değerleri tam sayı olmalı.");
        int left = Read(LeftBox), top = Read(TopBox), width = Read(WidthBox), height = Read(HeightBox);
        if (left < 0 || top < 0 || width <= 0 || height <= 0 || left + width > 100 || top + height > 100)
            throw new FormatException("Seçilen alan pencerenin sınırları içinde kalmalı.");
        var objective = ObjectiveCombo.SelectedIndex == 1 ? new NormRect(0, 0.04, 0.50, 0.45) : new NormRect(0.55, 0.10, 0.45, 0.40);
        return [new ScanZone(TextRole.Subtitle, new NormRect(left / 100.0, top / 100.0, width / 100.0, height / 100.0)), new ScanZone(TextRole.Objective, objective)];
    }

    private void ShowProgress()
    {
        if (session is null) return;
        MetricsText.Text = $"Son işlem · OCR {session.OcrMs:0} ms · Çeviri {session.Manager.LastTranslationMs:0} ms";
        // Recent pairs stay in memory only; they are not written to disk.
        if (!ReferenceEquals(RecentList.ItemsSource, null) && RecentList.Items.Count == session.Manager.Recent.Count &&
            (session.Manager.Recent.Count == 0 || Equals(RecentList.Items[0], session.Manager.Recent[0]))) return;
        RecentList.ItemsSource = session.Manager.Recent.ToList();
    }

    private void Finish(string? message)
    {
        SetupPanel.IsEnabled = true;
        StartButton.Content = "Başlat";
        if (message is not null) StatusText.Text = message;
    }
}
