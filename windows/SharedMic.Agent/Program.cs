using SharedMic.Agent.Diagnostics;
using SharedMic.Agent.Net;
using SharedMic.Agent.Security;

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

        var listener = new TlsListener(
            identity,
            options,
            rateLimiter,
            metrics,
            (status, detail) => AgentLog.Info($"status: {status}{(detail is null ? string.Empty : $" ({detail})")}"));

        try
        {
            listener.Start();
        }
        catch (InvalidOperationException exception)
        {
            AgentLog.Error(exception.Message);
            return 1;
        }

        using var quit = new ManualResetEventSlim(false);
        Console.CancelKeyPress += (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            quit.Set();
        };

        AgentLog.Info("running. Press Ctrl+C to quit.");
        quit.Wait();

        AgentLog.Info($"final counters: {metrics.Snapshot()}");
        listener.DisposeAsync().AsTask().GetAwaiter().GetResult();
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
