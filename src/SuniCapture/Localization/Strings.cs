using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Text.Json;
using System.Windows.Data;
using System.Windows.Markup;

namespace SuniCapture.Localization;

/// <summary>Shared, live FR/EN strings. Changing language never reloads the library or editor.</summary>
public sealed class Strings : INotifyPropertyChanged
{
    public sealed record Translation(string Fr, string En);
    private static readonly Dictionary<string, Translation> Catalog = LoadCatalog();
    public static Strings Current { get; } = new();
    public static string Language { get; private set; } = "fr";
    public static CultureInfo Culture => CultureInfo.GetCultureInfo(Language == "en" ? "en-GB" : "fr-CH");
    public static IReadOnlyDictionary<string, Translation> Entries => Catalog;
    public string this[string key] => T(key);
    public event PropertyChangedEventHandler? PropertyChanged;

    public static string Normalize(string? language) => language?.Equals("en", StringComparison.OrdinalIgnoreCase) == true ? "en" : "fr";
    public static string T(string key) => Catalog.TryGetValue(key, out var entry)
        ? Language == "en" ? entry.En : entry.Fr
        : throw new KeyNotFoundException("Missing translation: " + key);
    public static string F(string key, params object[] values) => string.Format(Culture, T(key), values);

    public static string TranslateSource(string source)
    {
        foreach (var key in new[] { "source.region", "source.desktop", "capture.window", "source.imported", "source.clipboard", "record.primary", "capture.name" })
        {
            var entry = Catalog[key];
            if (source == entry.Fr || source == entry.En) return T(key);
        }
        return source;
    }

    public static void SetLanguage(string? language)
    {
        Language = Normalize(language);
        CultureInfo.DefaultThreadCurrentCulture = Culture;
        CultureInfo.DefaultThreadCurrentUICulture = Culture;
        CultureInfo.CurrentCulture = Culture;
        CultureInfo.CurrentUICulture = Culture;
        Current.PropertyChanged?.Invoke(Current, new PropertyChangedEventArgs("Item[]"));
    }

    public static string ReadSavedLanguage(string? root)
    {
        var path = Path.Combine(root ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SuniCapture"), "settings.json");
        foreach (var candidate in new[] { path, path + ".bak" })
        {
            try
            {
                if (!File.Exists(candidate)) continue;
                using var json = JsonDocument.Parse(File.ReadAllText(candidate));
                return json.RootElement.TryGetProperty("Language", out var value) && value.ValueKind == JsonValueKind.String
                    ? Normalize(value.GetString()) : "fr";
            }
            catch (Exception error) when (error is JsonException or IOException or UnauthorizedAccessException) { }
        }
        return "fr";
    }

    private static Dictionary<string, Translation> LoadCatalog()
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("SuniCapture.Localization.strings.json")
            ?? throw new InvalidOperationException("Translation catalog unavailable.");
        return JsonSerializer.Deserialize<Dictionary<string, Translation>>(stream, new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
            ?? throw new InvalidOperationException("Translation catalog is empty.");
    }
}

/// <summary>Bindings also update hidden views, tooltips, menus and accessibility names.</summary>
[MarkupExtensionReturnType(typeof(string))]
public sealed class TrExtension : MarkupExtension
{
    public string Key { get; set; }
    public TrExtension(string key) => Key = key;
    public override object ProvideValue(IServiceProvider serviceProvider) =>
        new Binding("[" + Key + "]") { Source = Strings.Current, Mode = BindingMode.OneWay }.ProvideValue(serviceProvider);
}
