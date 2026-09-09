using SharedMic.Agent.Ui;
using Xunit;

namespace SharedMic.Agent.Tests;

public class AutostartManagerTests
{
    private sealed class FakeAutostartStore : IAutostartStore
    {
        private readonly Dictionary<string, string> _values = new();

        public string? GetValue(string name) =>
            _values.TryGetValue(name, out var value) ? value : null;

        public void SetValue(string name, string command) => _values[name] = command;

        public void DeleteValue(string name) => _values.Remove(name);

        public void SeedRaw(string name, string value) => _values[name] = value;
    }

    [Fact]
    public void MissingValueReadsDisabled()
    {
        var store = new FakeAutostartStore();
        var manager = new AutostartManager(store, @"C:\Apps\SharedMic\SharedMic.Agent.exe");

        Assert.False(manager.IsEnabled);
    }

    [Fact]
    public void EnableWritesTheQuotedExecutablePath()
    {
        var store = new FakeAutostartStore();
        var manager = new AutostartManager(store, @"C:\Apps\SharedMic\SharedMic.Agent.exe");

        manager.Enable();

        Assert.True(manager.IsEnabled);
        Assert.Equal("\"C:\\Apps\\SharedMic\\SharedMic.Agent.exe\"", store.GetValue(AutostartManager.ValueName));
    }

    [Fact]
    public void DisableRemovesTheValueAndIsIdempotent()
    {
        var store = new FakeAutostartStore();
        var manager = new AutostartManager(store, @"C:\Apps\SharedMic\SharedMic.Agent.exe");

        manager.Enable();
        manager.Disable();

        Assert.False(manager.IsEnabled);
        manager.Disable();
        Assert.False(manager.IsEnabled);
    }

    [Fact]
    public void LegacyUnquotedValueStillReadsEnabled()
    {
        var store = new FakeAutostartStore();
        store.SeedRaw(AutostartManager.ValueName, @"C:\Apps\SharedMic\SharedMic.Agent.exe");
        var manager = new AutostartManager(store, @"C:\Apps\SharedMic\SharedMic.Agent.exe");

        Assert.True(manager.IsEnabled);
    }

    [Fact]
    public void ValueNameIsStable()
    {
        Assert.Equal("SharedMicAgent", AutostartManager.ValueName);
    }
}
