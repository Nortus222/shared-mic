using System.Drawing;
using System.Windows.Forms;
using SharedMic.Agent.Audio;
using SharedMic.Agent.Diagnostics;
using SharedMic.Agent.Security;

namespace SharedMic.Agent.Ui;

/// <summary>
/// The minimal Phase 1 tray: current status, the pairing string the user
/// retypes on the Mac, and a way to quit. Design spec section 11's full status
/// list and diagnostics view arrive with the audio path and automatic demand;
/// there is no device picker or level meter here because there is no capture
/// path to feed one.
///
/// Never show or copy the raw token, only the pairing string.
/// </summary>
public sealed class TrayApp : ApplicationContext
{
    private const int MaxNotifyIconTextLength = 63;

    private readonly NotifyIcon _icon;
    private readonly ToolStripMenuItem _statusItem;
    private readonly ContextMenuStrip _menu;
    private readonly Func<Task> _onQuitAsync;

    /// <summary>
    /// A hidden, handle-only window used purely as the marshalling target for
    /// <see cref="SetStatus"/>. A ContextMenuStrip is not usable for this: its
    /// handle is not created until the menu is first shown, and a control with
    /// no handle reports InvokeRequired == false, which would silently run a
    /// cross-thread update on whichever pool thread the listener called from.
    /// This control's handle is forced on the UI thread in the constructor, so
    /// BeginInvoke is always legal and always a post.
    /// </summary>
    private readonly Control _marshal;
    private readonly AudioContext? _audio;
    private readonly System.Windows.Forms.Timer _levelTimer;
    private readonly ToolStripMenuItem _meterItem;
    private readonly Dictionary<ChannelMode, ToolStripMenuItem> _channelItems = new();

    public TrayApp(AgentIdentity identity, AgentOptions options, Func<Task> onQuitAsync, AudioContext? audio = null)
    {
        _onQuitAsync = onQuitAsync;
        _audio = audio;

        _marshal = new Control();
        _ = _marshal.Handle; // Forces handle creation on this (UI) thread.

        _statusItem = new ToolStripMenuItem(FormatStatus(AgentStatus.Disconnected, null)) { Enabled = false };

        var pairingHeader = new ToolStripMenuItem("Pairing string (click to copy)") { Enabled = false };
        var pairingValue = new ToolStripMenuItem(identity.PairingString);
        pairingValue.Click += (_, _) =>
        {
            Clipboard.SetText(identity.PairingString);
            AgentLog.Info("pairing string copied to the clipboard");
        };

        var fingerprintHeader = new ToolStripMenuItem("Certificate fingerprint (click to copy)") { Enabled = false };
        var fingerprintValue = new ToolStripMenuItem(identity.Fingerprint);
        fingerprintValue.Click += (_, _) =>
        {
            Clipboard.SetText(identity.Fingerprint);
            AgentLog.Info("certificate fingerprint copied to the clipboard");
        };

        var quit = new ToolStripMenuItem("Quit");
        quit.Click += async (_, _) => await QuitAsync();

        _menu = new ContextMenuStrip();
        _menu.Items.Add(_statusItem);
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(pairingHeader);
        _menu.Items.Add(pairingValue);
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(fingerprintHeader);
        _menu.Items.Add(fingerprintValue);

        _meterItem = new ToolStripMenuItem("Input level: -") { Enabled = false };
        if (_audio?.Capture is not null)
        {
            var channelMenu = new ToolStripMenuItem("Channel mode");
            foreach (var mode in new[] { ChannelMode.Mix, ChannelMode.Left, ChannelMode.Right })
            {
                var item = new ToolStripMenuItem(mode.ToString()) { Checked = mode == _audio.Capture.Mode };
                var selected = mode;
                item.Click += (_, _) => SelectChannelMode(selected);
                _channelItems[mode] = item;
                channelMenu.DropDownItems.Add(item);
            }

            _menu.Items.Add(new ToolStripSeparator());
            _menu.Items.Add(channelMenu);
            _menu.Items.Add(_meterItem);

            _levelTimer = new System.Windows.Forms.Timer { Interval = 500 };
            _levelTimer.Tick += (_, _) => RefreshMeter();
            _levelTimer.Start();
        }
        else
        {
            _levelTimer = new System.Windows.Forms.Timer { Interval = 500 };
        }

        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(quit);

        _icon = new NotifyIcon
        {
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath) ?? SystemIcons.Application,
            Text = FormatStatus(AgentStatus.Disconnected, null),
            ContextMenuStrip = _menu,
            Visible = true,
            BalloonTipTitle = "shared-mic",
            BalloonTipText = $"Listening on port {options.Port}. Pair the Mac with the string in this menu.",
        };
    }

    /// <summary>The tray menu, exposed so the test suite can assert on its items.</summary>
    internal ContextMenuStrip Menu => _menu;

    /// <summary>The current status line, exposed for the test suite.</summary>
    internal string StatusText => _statusItem.Text ?? string.Empty;

    /// <summary>The current hover text, exposed for the test suite.</summary>
    internal string IconText => _icon.Text ?? string.Empty;

    /// <summary>
    /// Tray label text. Clamped to 63 characters because NotifyIcon.Text throws
    /// above that, and a long bind error is exactly how that happens.
    /// </summary>
    public static string FormatStatus(AgentStatus status, string? detail)
    {
        var text = string.IsNullOrWhiteSpace(detail)
            ? $"Status: {status}"
            : $"Status: {status} ({detail})";

        if (text.Length > MaxNotifyIconTextLength)
        {
            text = text.Substring(0, MaxNotifyIconTextLength - 3) + "...";
        }

        return text;
    }

    /// <summary>
    /// Safe to call from any thread, and NON-BLOCKING on every thread but the UI
    /// one. TlsListener invokes its status callback while holding its internal
    /// lock, so this method must never wait on anything: it posts with
    /// BeginInvoke and returns. See the callback comment in Program.Main.
    ///
    /// A status can also arrive after teardown has begun, so a missing or
    /// destroyed handle is a normal outcome here, not an error: the update is
    /// dropped rather than thrown.
    /// </summary>
    public void SetStatus(AgentStatus status, string? detail)
    {
        var text = FormatStatus(status, detail);

        void Apply()
        {
            _statusItem.Text = text;
            _icon.Text = text;
        }

        if (_marshal.IsDisposed || !_marshal.IsHandleCreated)
        {
            return;
        }

        try
        {
            if (_marshal.InvokeRequired)
            {
                // BeginInvoke, never Invoke. A synchronous Invoke onto a UI
                // thread that is itself inside the listener would deadlock.
                _marshal.BeginInvoke(Apply);
            }
            else
            {
                Apply();
            }
        }
        catch (ObjectDisposedException)
        {
            // The window went away between the check and the post; the agent is
            // shutting down and there is no status left to show.
        }
        catch (InvalidOperationException)
        {
            // Same race, reported as "handle not created" instead.
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _levelTimer.Stop();
            _levelTimer.Dispose();
            _icon.Visible = false;
            _icon.Dispose();
            _marshal.Dispose();
        }

        base.Dispose(disposing);
    }

    internal void SelectChannelMode(ChannelMode mode)
    {
        if (_audio?.Capture is not null)
        {
            _audio.Capture.Mode = mode;
            AgentLog.Info($"channel mode set to {mode}");
        }

        foreach (var entry in _channelItems)
        {
            entry.Value.Checked = entry.Key == mode;
        }
    }

    internal void RefreshMeter()
    {
        if (_audio?.Capture is { } capture && capture.IsRunning)
        {
            int filled = (int)Math.Round(Math.Clamp(capture.LastPeak, 0f, 1f) * 10f);
            _meterItem.Text = $"Input level [{new string('#', filled)}{new string('-', 10 - filled)}]";
        }
        else
        {
            _meterItem.Text = "Input level: -";
        }
    }

    private async Task QuitAsync()
    {
        AgentLog.Info("quit requested from the tray");
        _icon.Visible = false;
        await _onQuitAsync();
        ExitThread();
    }
}
