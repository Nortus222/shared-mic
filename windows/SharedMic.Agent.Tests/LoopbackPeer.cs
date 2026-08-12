using System.Net;
using System.Net.Sockets;
using SharedMic.Agent.Net;
using SharedMic.Agent.Protocol;
using SharedMic.Agent.Security;

namespace SharedMic.Agent.Tests;

/// <summary>
/// A connected pair of NetworkStreams over 127.0.0.1 plus client-side protocol
/// helpers, so ControlConnection can be driven exactly as the Mac would drive
/// it without TLS in the way.
/// </summary>
public sealed class LoopbackPeer : IAsyncDisposable
{
    private readonly TcpListener _listener;
    private readonly TcpClient _clientSide;
    private readonly TcpClient _serverSide;
    private readonly FrameReader _reader;

    private LoopbackPeer(TcpListener listener, TcpClient clientSide, TcpClient serverSide)
    {
        _listener = listener;
        _clientSide = clientSide;
        _serverSide = serverSide;
        ClientStream = clientSide.GetStream();
        ServerStream = serverSide.GetStream();
        _reader = new FrameReader(ClientStream);
    }

    public NetworkStream ClientStream { get; }

    public NetworkStream ServerStream { get; }

    public static async Task<LoopbackPeer> CreateAsync()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var connecting = new TcpClient();
        var accepting = listener.AcceptTcpClientAsync();
        await connecting.ConnectAsync(IPAddress.Loopback, ((IPEndPoint)listener.LocalEndpoint).Port);
        var accepted = await accepting;
        connecting.NoDelay = true;
        accepted.NoDelay = true;
        return new LoopbackPeer(listener, connecting, accepted);
    }

    public async Task SendControlAsync(IReadOnlyDictionary<string, object?> message, CancellationToken cancellationToken)
    {
        var frame = FrameCodec.EncodeFrame(FrameType.Control, ControlCodec.Encode(message));
        await ClientStream.WriteAsync(frame, cancellationToken);
        await ClientStream.FlushAsync(cancellationToken);
    }

    public async Task SendRawAsync(byte[] bytes, CancellationToken cancellationToken)
    {
        await ClientStream.WriteAsync(bytes, cancellationToken);
        await ClientStream.FlushAsync(cancellationToken);
    }

    /// <summary>Read the next frame the agent sent, or null if it closed the connection.</summary>
    public async Task<ReceivedFrame?> ReadFrameAsync(CancellationToken cancellationToken)
    {
        try
        {
            return await _reader.ReadFrameAsync(cancellationToken);
        }
        catch (Exception exception) when (exception is IOException or ObjectDisposedException or ProtocolException)
        {
            return null;
        }
    }

    /// <summary>Read the next control message the agent sent, or null if it closed the connection.</summary>
    public async Task<Dictionary<string, object?>?> ReadControlAsync(CancellationToken cancellationToken)
    {
        var frame = await ReadFrameAsync(cancellationToken);
        if (frame is null)
        {
            return null;
        }

        if (frame.Value.Type != FrameType.Control)
        {
            throw new InvalidOperationException($"expected a CONTROL frame, got {frame.Value.Type}");
        }

        return ControlCodec.Decode(frame.Value.Payload);
    }

    /// <summary>Complete GREETING then HELLO, returning the GREETING that was received.</summary>
    public async Task<Dictionary<string, object?>> AuthenticateAsync(byte[] token, CancellationToken cancellationToken)
    {
        var greeting = await ReadControlAsync(cancellationToken)
                       ?? throw new InvalidOperationException("the agent closed before sending GREETING");
        var nonce = Convert.FromHexString((string)greeting["nonce"]!);
        await SendControlAsync(
            ControlMessages.Hello("mock-mac", AuthProof.Compute(token, nonce)),
            cancellationToken);
        return greeting;
    }

    /// <summary>True when the agent closed the connection within the timeout.</summary>
    public async Task<bool> WaitForCloseAsync(TimeSpan timeout)
    {
        using var cancellation = new CancellationTokenSource(timeout);
        try
        {
            while (true)
            {
                var frame = await ReadFrameAsync(cancellation.Token);
                if (frame is null)
                {
                    return true;
                }
            }
        }
        catch (OperationCanceledException)
        {
            return false;
        }
    }

    public async ValueTask DisposeAsync()
    {
        await ClientStream.DisposeAsync();
        await ServerStream.DisposeAsync();
        _clientSide.Dispose();
        _serverSide.Dispose();
        _listener.Stop();
    }
}
