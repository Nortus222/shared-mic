using System.Windows.Forms;
using SharedMic.Agent.Audio;
using SharedMic.Agent.Security;
using SharedMic.Agent.Ui;
using Xunit;

namespace SharedMic.Agent.Tests;

public class TrayAudioTests
{
    private static AgentIdentity TestIdentity() => new(
        "TEST-HOST",
        PairingToken.Generate(),
        null!,
        new string('a', 64));

    private static void RunOnStaThread(Action action)
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try
            {
                action();
            }
            catch (Exception exception)
            {
                failure = exception;
            }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join(TimeSpan.FromSeconds(30));
        if (failure is not null)
        {
            throw failure;
        }
    }

    private static ToolStripMenuItem FindItem(ContextMenuStrip menu, string text)
    {
        foreach (ToolStripItem item in menu.Items)
        {
            if (item.Text == text && item is ToolStripMenuItem found)
            {
                return found;
            }
        }

        throw new InvalidOperationException($"menu item '{text}' was not found");
    }

    [Fact]
    public void ChannelMenuSelectsTheModeOnTheLiveService()
    {
        RunOnStaThread(() =>
        {
            using var audio = new AudioContext(new DeviceManager(new PresentProvider()), new SilentFactory());
            using var tray = new TrayApp(TestIdentity(), new AgentOptions(), () => Task.CompletedTask, audio);

            Assert.Equal(ChannelMode.Mix, audio.Capture!.Mode);

            var channelMenu = FindItem(tray.Menu, "Channel mode");
            var left = channelMenu.DropDownItems.OfType<ToolStripMenuItem>().Single(i => i.Text == "Left");
            left.PerformClick();

            Assert.Equal(ChannelMode.Left, audio.Capture.Mode);
        });
    }

    [Fact]
    public void MeterShowsIdleDashWhenCaptureIsNotRunning()
    {
        RunOnStaThread(() =>
        {
            using var audio = new AudioContext(new DeviceManager(new PresentProvider()), new SilentFactory());
            using var tray = new TrayApp(TestIdentity(), new AgentOptions(), () => Task.CompletedTask, audio);

            tray.RefreshMeter();

            var meter = FindItem(tray.Menu, "Input level: -");
            Assert.NotNull(meter);
        });
    }

    [Fact]
    public void NoAudioMenuAppearsWithoutAnAudioContext()
    {
        RunOnStaThread(() =>
        {
            using var tray = new TrayApp(TestIdentity(), new AgentOptions(), () => Task.CompletedTask);

            Assert.DoesNotContain(
                tray.Menu.Items.OfType<ToolStripItem>().Select(i => i.Text),
                text => text == "Channel mode");
        });
    }

    private sealed class PresentProvider : IAudioEndpointProvider
    {
        public event Action? DevicesChanged;

        public bool IsPresent(string endpointId) => true;

        public string GetFriendlyName(string endpointId) => "Test Microphone";

        public void Dispose()
        {
        }
    }

    private sealed class SilentFactory : IAudioCaptureFactory
    {
        public IAudioCapture Open(string endpointId) => new SilentCapture();

        private sealed class SilentCapture : IAudioCapture
        {
            public int SampleRate => 48000;

            public int Channels => 1;

            public event Action<float[]>? DataAvailable;

            public event Action? CaptureLost;

            public void Start()
            {
            }

            public void Stop()
            {
            }

            public void Dispose()
            {
            }
        }
    }
}
