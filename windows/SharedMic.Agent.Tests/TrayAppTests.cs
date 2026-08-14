using System.Windows.Forms;
using SharedMic.Agent;
using SharedMic.Agent.Security;
using SharedMic.Agent.Ui;
using Xunit;

namespace SharedMic.Agent.Tests;

public class TrayAppTests
{
    /// <summary>
    /// A token whose base32 encoding is the 58-character pairing string the
    /// tray exists to display. The certificate is never touched by TrayApp, so
    /// the identity carries none: constructing a real one would persist a CNG
    /// key container as a side effect of a UI test.
    /// </summary>
    private static AgentIdentity TestIdentity() => new(
        "TEST-HOST",
        PairingToken.Generate(),
        null!,
        new string('a', 64));

    [Fact]
    public void FormatsTheThreeStatusesPhase1CanReach()
    {
        Assert.Equal("Status: Disconnected", TrayApp.FormatStatus(AgentStatus.Disconnected, null));
        Assert.Equal("Status: Idle", TrayApp.FormatStatus(AgentStatus.Idle, null));
        Assert.Equal("Status: Error", TrayApp.FormatStatus(AgentStatus.Error, null));
    }

    [Fact]
    public void IncludesADetailWhenOneIsGiven()
    {
        // The real bind-failure message is 66 characters once wrapped, so it is
        // clamped: the 63-character NotifyIcon.Text limit wins over showing it
        // whole. (The brief asserted the untruncated string here and the clamp
        // in NotifyIconTextStaysWithinTheWindowsLimit; both cannot hold, and the
        // clamp is the one the Windows API enforces.)
        Assert.Equal(
            "Status: Error (no private interface accepted a bind on port ...",
            TrayApp.FormatStatus(AgentStatus.Error, "no private interface accepted a bind on port 47800"));

        Assert.Equal(
            "Status: Idle (192.168.1.9)",
            TrayApp.FormatStatus(AgentStatus.Idle, "192.168.1.9"));
    }

    [Fact]
    public void TreatsAnEmptyDetailAsNoDetail()
    {
        Assert.Equal("Status: Idle", TrayApp.FormatStatus(AgentStatus.Idle, ""));
        Assert.Equal("Status: Idle", TrayApp.FormatStatus(AgentStatus.Idle, "   "));
    }

    [Fact]
    public void NotifyIconTextStaysWithinTheWindowsLimit()
    {
        // NotifyIcon.Text throws above 63 characters, and a long device label
        // or bind error is exactly how that happens in the field.
        var text = TrayApp.FormatStatus(AgentStatus.Error, new string('x', 200));

        Assert.True(text.Length <= 63, $"tray text was {text.Length} characters");
        Assert.StartsWith("Status: Error (", text);
    }

    [Fact]
    public void MenuListsTheStatusThePairingStringTheFingerprintAndQuit()
    {
        RunOnStaThread(() =>
        {
            var identity = TestIdentity();
            using var tray = new TrayApp(identity, new AgentOptions(), () => Task.CompletedTask);

            var labels = tray.Menu.Items
                .OfType<ToolStripItem>()
                .Where(item => item is not ToolStripSeparator)
                .Select(item => item.Text)
                .ToArray();

            Assert.Equal(
                new[]
                {
                    "Status: Disconnected",
                    "Pairing string (click to copy)",
                    identity.PairingString,
                    "Certificate fingerprint (click to copy)",
                    identity.Fingerprint,
                    "Quit",
                },
                labels);

            // The status line is informational, never actionable.
            Assert.False(tray.Menu.Items[0].Enabled);
        });
    }

    [Fact]
    public void ShowsThePairingStringAtItsFullFiftyEightCharacters()
    {
        RunOnStaThread(() =>
        {
            var identity = TestIdentity();
            using var tray = new TrayApp(identity, new AgentOptions(), () => Task.CompletedTask);

            var shown = tray.Menu.Items[3].Text;

            Assert.Equal(58, identity.PairingString.Length);
            Assert.Equal(identity.PairingString, shown);

            // The raw token must never reach the screen or the clipboard.
            Assert.DoesNotContain(Convert.ToHexString(identity.Token), shown, StringComparison.OrdinalIgnoreCase);
        });
    }

    [Fact]
    public void AStatusFromAnotherThreadNeverBlocksTheCallerAndAppliesWhenTheLoopPumps()
    {
        // This is the TlsListener contract in test form. The listener publishes
        // status while holding its own lock, so SetStatus must post and return.
        // The UI thread below is deliberately BLOCKED on the background task
        // while that happens: if SetStatus used Control.Invoke instead of
        // BeginInvoke, this test would deadlock and fail on the timeout.
        RunOnStaThread(() =>
        {
            using var tray = new TrayApp(TestIdentity(), new AgentOptions(), () => Task.CompletedTask);

            var posted = Task.Run(() => tray.SetStatus(AgentStatus.Idle, "192.168.1.9"));

            Assert.True(posted.Wait(TimeSpan.FromSeconds(5)), "SetStatus blocked its caller");

            // Nothing has pumped yet, so the post is still queued.
            Assert.Equal("Status: Disconnected", tray.StatusText);

            Application.DoEvents();

            Assert.Equal("Status: Idle (192.168.1.9)", tray.StatusText);
            Assert.Equal("Status: Idle (192.168.1.9)", tray.IconText);
        });
    }

    [Fact]
    public void AStatusArrivingAfterDisposalIsDroppedRatherThanThrown()
    {
        RunOnStaThread(() =>
        {
            var tray = new TrayApp(TestIdentity(), new AgentOptions(), () => Task.CompletedTask);
            tray.Dispose();

            // The listener can publish a final Disconnected from a drain task
            // after teardown has torn the window down.
            tray.SetStatus(AgentStatus.Disconnected, null);
            Task.Run(() => tray.SetStatus(AgentStatus.Error, "late")).Wait(TimeSpan.FromSeconds(5));
        });
    }

    [Fact]
    public void ClickingThePairingItemCopiesThePairingStringToTheClipboard()
    {
        RunOnStaThread(() =>
        {
            var identity = TestIdentity();
            using var tray = new TrayApp(identity, new AgentOptions(), () => Task.CompletedTask);

            var original = Clipboard.ContainsText() ? Clipboard.GetText() : null;
            try
            {
                ((ToolStripMenuItem)tray.Menu.Items[3]).PerformClick();

                var copied = Clipboard.GetText();
                Assert.Equal(identity.PairingString, copied);
                Assert.Equal(58, copied.Length);
            }
            finally
            {
                if (original is not null)
                {
                    Clipboard.SetText(original);
                }
                else
                {
                    Clipboard.Clear();
                }
            }
        });
    }

    /// <summary>
    /// WinForms and the clipboard both require a single-threaded apartment, and
    /// xunit runs tests on MTA pool threads. This gives each UI test its own STA
    /// thread and rethrows whatever failed on it.
    /// </summary>
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
        Assert.True(thread.Join(TimeSpan.FromSeconds(30)), "the UI test thread did not finish");

        if (failure is not null)
        {
            throw failure;
        }
    }
}
