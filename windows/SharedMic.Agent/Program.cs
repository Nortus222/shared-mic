using System.Diagnostics.CodeAnalysis;
using System.Security.Cryptography;
using System.Windows.Forms;
using SharedMic.Agent.Audio;
using SharedMic.Agent.Diagnostics;
using SharedMic.Agent.Net;
using SharedMic.Agent.Security;
using SharedMic.Agent.Ui;

namespace SharedMic.Agent;

public static class Program
{
    public static AgentOptions ParseArguments(string[] args)
    {
        var port = Protocol.ProtocolConstants.DefaultPort;
        var micPresent = true;
        var deviceLabel = "(no device selected)";
        var dataDirectory = IdentityStore.DefaultDirectory;
        var headless = false;
        var loopbackOnly = false;
        var channelMode = Audio.ChannelMode.Mix;

        for (var i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--port":
                    port = ParsePort(Next(args, ref i, "--port"));
                    break;
                case "--no-mic":
                    micPresent = false;
                    break;
                case "--device-label":
                    deviceLabel = Next(args, ref i, "--device-label");
                    break;
                case "--data-dir":
                    dataDirectory = Next(args, ref i, "--data-dir");
                    break;
                case "--headless":
                    headless = true;
                    break;
                case "--loopback-only":
                    loopbackOnly = true;
                    break;
                case "--channel-mode":
                    channelMode = ParseChannelMode(Next(args, ref i, "--channel-mode"));
                    break;
                default:
                    throw new ArgumentException($"unknown argument '{args[i]}'");
            }
        }

        return new AgentOptions
        {
            Port = port,
            MicPresent = micPresent,
            DeviceLabel = deviceLabel,
            DataDirectory = dataDirectory,
            Headless = headless,
            LoopbackOnly = loopbackOnly,
            ChannelMode = channelMode,
        };
    }

    [STAThread]
    public static int Main(string[] args)
    {
        AgentOptions options;
        try
        {
            options = ParseArguments(args);
        }
        catch (ArgumentException exception)
        {
            Console.Error.WriteLine(exception.Message);
            Console.Error.WriteLine(
                "usage: SharedMic.Agent [--port N] [--no-mic] [--device-label TEXT] " +
                "[--data-dir PATH] [--headless] [--loopback-only] [--channel-mode mix|left|right]");
            return 2;
        }

        // The store is kept in scope, not discarded on the construction line:
        // the failure path below has to name its file, and WasNewlyCreated has
        // to survive to the banner.
        var store = new IdentityStore(options.DataDirectory);
        if (!TryLoadIdentity(store, out var identity, out var identityExitCode))
        {
            return identityExitCode;
        }

        var metrics = new AgentMetrics();
        var rateLimiter = new AuthRateLimiter();
        var ledger = new SessionLedger();

        PrintBanner(Console.Out, identity, options, store.WasNewlyCreated);

        AudioContext? audio = null;
        try
        {
            var devices = new DeviceManager(new NAudioEndpointProvider());
            audio = new AudioContext(devices, new WasapiAudioCaptureFactory(), options.ChannelMode);
            AgentLog.Info(
                $"microphone: {(devices.IsMicPresent ? devices.DeviceLabel : DeviceManager.AbsentLabel)} [{devices.EndpointId}]");
        }
        catch (Exception exception)
        {
            AgentLog.Warn(
                $"audio capture is unavailable ({exception.GetType().Name}); sessions will stream no audio");
        }

        TrayApp? tray = null;
        var listener = new TlsListener(
            identity,
            options,
            rateLimiter,
            metrics,
            // CONTRACT FOR THIS CALLBACK - read before changing a line of it.
            //
            // TlsListener invokes this WHILE HOLDING ITS INTERNAL LOCK (_gate),
            // including from Adopt, which runs on the newly authenticated
            // connection's read loop. Therefore this callback:
            //
            //   * must be NON-BLOCKING. It may not wait on a task, a lock, an
            //     event, or a UI message being processed.
            //   * must NOT re-enter the listener. No Start, no DisposeAsync, no
            //     waiting on anything the listener owns - that is a self-deadlock
            //     on _gate.
            //   * must be safe on ARBITRARY threads. It is called from accept
            //     loops, connection read loops, and Start's caller.
            //   * must marshal to the WinForms UI thread with a POST
            //     (Control.BeginInvoke), NEVER a SEND (Control.Invoke). A
            //     synchronous Invoke onto a UI thread that is itself waiting on
            //     the listener deadlocks outright - the classic WinForms
            //     deadlock. TrayApp.SetStatus posts.
            //   * must tolerate a status arriving AFTER DisposeAsync has
            //     returned, and after the tray's window handle is gone.
            //     TrayApp.SetStatus checks IsDisposed / IsHandleCreated and
            //     drops the update instead of throwing.
            //
            // Both calls below satisfy that. AgentLog.Info takes only a short,
            // leaf-level lock of its own (AgentLog.Gate, around one
            // Console.WriteLine) and never re-enters the listener, so it cannot
            // close a lock cycle; tray?.SetStatus is a post. Note the
            // pre-existing hazard the logging call carries into this critical
            // section though: a console write that BLOCKS - conhost QuickEdit
            // text selection pausing output is the everyday case - stalls this
            // thread while it still holds the listener's _gate.
            (status, detail) =>
            {
                AgentLog.Info($"status: {status}{(string.IsNullOrWhiteSpace(detail) ? string.Empty : $" ({detail})")}");

                // The listener publishes Disconnected with no detail. The port
                // is the one thing a user staring at a disconnected tray wants,
                // so it is filled in here rather than latching whatever the
                // startup status happened to say.
                var shown = string.IsNullOrWhiteSpace(detail) && status == AgentStatus.Disconnected
                    ? $"port {options.Port}"
                    : detail;

                tray?.SetStatus(status, shown);
            },
            audio,
            ledger);

        // Constructed BEFORE Start(). The other order loses a status: a Mac that
        // reconnects the instant the listener binds publishes Idle into a null
        // tray, and the tray then reads Disconnected for the whole live session
        // because nothing re-publishes. Assigning before Start also means the
        // callback's cross-thread read of this variable is ordered by the
        // thread starts inside Start, not by luck.
        var autostart = new AutostartManager(
            new RegistryAutostartStore(),
            Environment.ProcessPath ?? Application.ExecutablePath);
        MdnsAdvertiser? advertiser = null;

        if (!options.Headless)
        {
            ApplicationConfiguration.Initialize();

            tray = new TrayApp(identity, options, async () =>
            {
                // Dispose FIRST, snapshot second - see the headless path below
                // for why the order is load-bearing.
                advertiser?.Dispose();
                await listener.DisposeAsync();
                AgentLog.Info($"final counters: {metrics.Snapshot()}");
            }, audio, autostart,
            () => WindowsDiagnosticsSnapshot.From(metrics.Snapshot(), ledger.Snapshot()).ToMenuLines());
            tray.SetStatus(AgentStatus.Disconnected, $"port {options.Port}");
        }

        try
        {
            listener.Start();
        }
        catch (InvalidOperationException exception)
        {
            AgentLog.Error(exception.Message);

            // The bind failed, so the tray must not linger as a dead icon.
            tray?.Dispose();
            audio?.Dispose();
            return 1;
        }

        // Best-effort: discovery only fills the Mac pairing form, so a
        // failure here warns and serving continues without it.
        try
        {
            advertiser = new MdnsAdvertiser(new DnsApiMdnsBackend(), Environment.MachineName);
            advertiser.Start((ushort)options.Port, identity.Fingerprint);
        }
        catch (Exception exception)
        {
            AgentLog.Warn($"mDNS advertising is unavailable ({exception.GetType().Name}); pair by address instead");
            advertiser = null;
        }

        if (tray is not null)
        {
            AgentLog.Info("running with a tray icon. Use the tray menu to quit.");
            Application.Run(tray);
            advertiser?.Dispose();
            audio?.Dispose();
            return 0;
        }

        using var quit = new ManualResetEventSlim(false);
        Console.CancelKeyPress += (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            quit.Set();
        };

        AgentLog.Info("running headless. Press Ctrl+C to quit.");
        quit.Wait();

        // Dispose FIRST, snapshot second. Teardown itself counts: closing the
        // current connection discards queued audio and can still move counters,
        // and this line is the run's evidence artefact — printing it before the
        // listener has drained makes it "counters as of shortly before the end",
        // which is exactly the misreading it is there to prevent.
        listener.DisposeAsync().AsTask().GetAwaiter().GetResult();
        advertiser?.Dispose();
        audio?.Dispose();
        AgentLog.Info($"final counters: {metrics.Snapshot()}");
        return 0;
    }

    /// <summary>
    /// Load the identity, or explain - in words a user can act on - why it
    /// cannot be loaded.
    ///
    /// A DPAPI blob protected under the current user stops being decryptable
    /// when an administrator resets that user's Windows password without the
    /// old one, or when the profile is migrated to another machine. Without
    /// this, every launch afterwards died with an unhandled
    /// CryptographicException and a .NET stack trace - in a tray app where the
    /// user may never see a console at all.
    ///
    /// Deliberately does NOT delete the file and silently re-mint. A silent
    /// re-mint changes the certificate fingerprint, and the Mac treats a pinned
    /// fingerprint mismatch as a hard stop with no auto-retry and no silent
    /// re-pair. Turning a readable failure here into an unexplained hard stop
    /// there is strictly worse. Re-pairing stays an explicit act by the user.
    ///
    /// The two failures are reported separately and exit differently, because
    /// they are different user problems with opposite remedies. "I cannot use
    /// this directory" (exit 4) means the --data-dir argument is wrong -
    /// typically a shell mangled it, e.g. PowerShell's $env:TEMP typed into bash
    /// collapsing to the literal ":TEMPfoo". "I cannot decrypt your identity"
    /// (exit 3) means the file must be deleted and the Mac re-paired. Conflating
    /// them would send a user to delete an identity file that is perfectly fine.
    /// </summary>
    /// <param name="exitCode">The process exit code for the failure; 0 on success.</param>
    internal static bool TryLoadIdentity(
        IdentityStore store, [NotNullWhen(true)] out AgentIdentity? identity, out int exitCode)
    {
        try
        {
            identity = store.LoadOrCreate();
            exitCode = 0;
            return true;
        }
        catch (Exception exception) when (exception is CryptographicException or InvalidDataException)
        {
            identity = null;
            exitCode = 3;

            AgentLog.Error(
                $"the stored identity at {store.IdentityFilePath} could not be read " +
                $"({exception.GetType().Name}: {exception.Message})");
            AgentLog.Error(
                "this usually means the file was created under a different Windows user profile, or the " +
                "account's password was reset by an administrator without the old password, or the file is " +
                "damaged. It cannot be recovered.");
            AgentLog.Error(
                $"to re-pair: quit the agent, delete {store.IdentityFilePath}, then start the agent again. " +
                "It will mint a NEW identity and print a NEW pairing string, and the Mac must be paired " +
                "again because its pinned certificate fingerprint will no longer match.");

            return false;
        }
        catch (Exception exception) when (
            exception is IOException            // includes DirectoryNotFound / PathTooLong
                or ArgumentException            // malformed path, empty path, illegal characters
                or NotSupportedException        // e.g. a colon where a drive letter cannot be
                or UnauthorizedAccessException
                or System.Security.SecurityException)
        {
            identity = null;
            exitCode = 4;

            AgentLog.Error(
                $"the data directory '{store.DirectoryPath}' cannot be used " +
                $"({exception.GetType().Name}: {exception.Message})");
            AgentLog.Error(
                "the stored identity was NOT read and NOT changed. This is a bad --data-dir value, not a " +
                "damaged identity - do not delete anything.");
            AgentLog.Error(
                "check the path exists, is writable, and was not mangled by the shell. --data-dir " +
                @"$env:TEMP\sharedmic is PowerShell syntax; in bash $env does not expand and it collapses " +
                "to the literal ':TEMPsharedmic'. In bash use a literal path or \"$LOCALAPPDATA/Temp/sharedmic\". " +
                "Omit --data-dir to use the default.");

            return false;
        }
    }

    /// <summary>
    /// The startup banner. Writes to the supplied writer so the pairing-string
    /// rule below is testable.
    ///
    /// The pairing string is printed ONLY on the run that minted the identity.
    /// It is a live authentication credential with no expiry: under the
    /// documented <c>--headless &gt; agent.log</c> invocation, printing it every
    /// start writes it into an unprotected plaintext file on every launch for
    /// the life of the deployment, and anyone who can read that log can
    /// authenticate as the Mac. The tray menu still shows it on demand, which is
    /// the intended way to see it again.
    /// </summary>
    internal static void PrintBanner(
        TextWriter writer, AgentIdentity identity, AgentOptions options, bool identityWasNewlyMinted)
    {
        // Never print the token itself. The pairing string is meant for the
        // user's eyes and the fingerprint is public by construction.
        writer.WriteLine("shared-mic Windows agent, Phase 2 (transport, security, and microphone audio)");
        writer.WriteLine($"  serverId:       {identity.ServerId}");
        writer.WriteLine($"  port:           {options.Port}");
        writer.WriteLine($"  micPresent:     {options.MicPresent}");
        writer.WriteLine($"  deviceLabel:    {options.DeviceLabel}");
        writer.WriteLine($"  data directory: {options.DataDirectory}");
        writer.WriteLine($"  fingerprint:    {identity.Fingerprint}");

        if (identityWasNewlyMinted)
        {
            writer.WriteLine($"  pairing string: {identity.PairingString}");
        }
        else
        {
            writer.WriteLine(
                "  pairing string: (not printed again for security - open the tray menu to view it)");
        }

        writer.WriteLine();
    }

    /// <summary>
    /// Range-checks the port at parse time so a usage error is reported as one.
    /// Without the range check, a number outside 1-65535 reaches
    /// <c>new TcpListener(address, port)</c>, which throws
    /// ArgumentOutOfRangeException from a code path that only catches
    /// SocketException and InvalidOperationException - i.e. an unhandled stack
    /// trace at startup. An in-range port that is already taken still fails
    /// later, as a handled bind error, which is the correct place for it.
    /// </summary>
    private static Audio.ChannelMode ParseChannelMode(string value) =>
        value.ToLowerInvariant() switch
        {
            "mix" => Audio.ChannelMode.Mix,
            "left" => Audio.ChannelMode.Left,
            "right" => Audio.ChannelMode.Right,
            _ => throw new ArgumentException($"--channel-mode must be mix, left, or right (got '{value}')"),
        };

    private static int ParsePort(string value)
    {
        if (!int.TryParse(value, out var port))
        {
            throw new ArgumentException("--port expects an integer");
        }

        if (port is < 1 or > 65535)
        {
            throw new ArgumentException($"--port must be between 1 and 65535 (got {port})");
        }

        return port;
    }

    private static string Next(string[] args, ref int index, string flag)
    {
        if (index + 1 >= args.Length)
        {
            throw new ArgumentException($"{flag} expects a value");
        }

        return args[++index];
    }
}
