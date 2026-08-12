using System.Windows.Forms;
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

        for (var i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--port":
                    port = int.TryParse(Next(args, ref i, "--port"), out var parsed)
                        ? parsed
                        : throw new ArgumentException("--port expects an integer");
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
                "[--data-dir PATH] [--headless] [--loopback-only]");
            return 2;
        }

        var identity = new IdentityStore(options.DataDirectory).LoadOrCreate();
        var metrics = new AgentMetrics();
        var rateLimiter = new AuthRateLimiter();

        PrintBanner(identity, options);

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
            // AgentLog.Info is a lock-free console write and tray?.SetStatus is
            // a post; neither blocks.
            (status, detail) =>
            {
                AgentLog.Info($"status: {status}{(string.IsNullOrWhiteSpace(detail) ? string.Empty : $" ({detail})")}");
                tray?.SetStatus(status, detail);
            });

        try
        {
            listener.Start();
        }
        catch (InvalidOperationException exception)
        {
            AgentLog.Error(exception.Message);
            return 1;
        }

        if (!options.Headless)
        {
            ApplicationConfiguration.Initialize();

            tray = new TrayApp(identity, options, async () =>
            {
                // Dispose FIRST, snapshot second - see the headless path below
                // for why the order is load-bearing.
                await listener.DisposeAsync();
                AgentLog.Info($"final counters: {metrics.Snapshot()}");
            });
            tray.SetStatus(AgentStatus.Disconnected, $"port {options.Port}");

            AgentLog.Info("running with a tray icon. Use the tray menu to quit.");
            Application.Run(tray);
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
        AgentLog.Info($"final counters: {metrics.Snapshot()}");
        return 0;
    }

    private static void PrintBanner(AgentIdentity identity, AgentOptions options)
    {
        // Never print the token itself. The pairing string is meant for the
        // user's eyes and the fingerprint is public by construction.
        Console.WriteLine("shared-mic Windows agent, Phase 1 (transport and security only, no audio capture)");
        Console.WriteLine($"  serverId:       {identity.ServerId}");
        Console.WriteLine($"  port:           {options.Port}");
        Console.WriteLine($"  micPresent:     {options.MicPresent}");
        Console.WriteLine($"  deviceLabel:    {options.DeviceLabel}");
        Console.WriteLine($"  data directory: {options.DataDirectory}");
        Console.WriteLine($"  fingerprint:    {identity.Fingerprint}");
        Console.WriteLine($"  pairing string: {identity.PairingString}");
        Console.WriteLine();
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
