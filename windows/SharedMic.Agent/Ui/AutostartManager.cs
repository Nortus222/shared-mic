using Microsoft.Win32;

namespace SharedMic.Agent.Ui;

/// <summary>
/// Registry seam for launch-at-login, so the toggle logic is unit-testable
/// without touching HKCU.
/// </summary>
public interface IAutostartStore
{
    string? GetValue(string name);
    void SetValue(string name, string command);
    void DeleteValue(string name);
}

/// <summary>
/// Live store over HKCU\Software\Microsoft\Windows\CurrentVersion\Run.
/// Per-user only: no elevation, no machine-wide writes.
/// </summary>
public sealed class RegistryAutostartStore : IAutostartStore
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public string? GetValue(string name)
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: false);
        return key?.GetValue(name) as string;
    }

    public void SetValue(string name, string command)
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true)
            ?? throw new InvalidOperationException("cannot open the per-user Run key for writing");
        key.SetValue(name, command, RegistryValueKind.String);
    }

    public void DeleteValue(string name)
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true);
        if (key?.GetValue(name) is null)
        {
            return;
        }

        key.DeleteValue(name, throwOnMissingValue: false);
    }
}

/// <summary>
/// Launch-at-login toggle (spec section 2.1, Phase 4 Task 7). The agent
/// starts at login unpaired-but-ready; the stored pairing resumes silently
/// through the normal startup path. Any present value counts as enabled, so
/// a value written by an older format still reads enabled rather than
/// fighting the user.
/// </summary>
public sealed class AutostartManager
{
    public const string ValueName = "SharedMicAgent";

    private readonly IAutostartStore _store;
    private readonly string _executablePath;

    public AutostartManager(IAutostartStore store, string executablePath)
    {
        _store = store;
        _executablePath = executablePath;
    }

    public bool IsEnabled => _store.GetValue(ValueName) is not null;

    public string Command => $"\"{_executablePath}\"";

    public void Enable() => _store.SetValue(ValueName, Command);

    public void Disable() => _store.DeleteValue(ValueName);
}
