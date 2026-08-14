using SharedMic.Agent.Protocol;

namespace SharedMic.Agent.Net;

public readonly record struct ReceivedFrame(FrameType Type, byte[] Payload);

/// <summary>
/// Reads whole envelopes off a byte stream, buffering partial data rather than
/// guessing (protocol-v1.md section 3). Returns null on a clean end of stream,
/// and throws <see cref="ProtocolException"/> on a violation, which the caller
/// must answer by closing the connection.
///
/// One reader belongs to one connection and one reading thread; it is not
/// thread-safe.
/// </summary>
public sealed class FrameReader
{
    private const int InitialBufferSize = 8192;
    private static readonly int MaxBufferSize = ProtocolConstants.EnvelopeSize + ProtocolConstants.MaxPayloadBytes;

    private readonly Stream _stream;
    private byte[] _buffer = new byte[InitialBufferSize];
    private int _length;

    public FrameReader(Stream stream) => _stream = stream;

    public async Task<ReceivedFrame?> ReadFrameAsync(CancellationToken cancellationToken)
    {
        while (true)
        {
            if (FrameCodec.TryDecodeFrame(_buffer.AsSpan(0, _length), out var type, out var payload, out var consumed))
            {
                Buffer.BlockCopy(_buffer, consumed, _buffer, 0, _length - consumed);
                _length -= consumed;
                return new ReceivedFrame(type, payload);
            }

            if (_length == _buffer.Length)
            {
                if (_buffer.Length >= MaxBufferSize)
                {
                    throw new ProtocolException(
                        $"buffered {_length} bytes without completing a frame, which exceeds the maximum envelope size");
                }

                Array.Resize(ref _buffer, Math.Min(_buffer.Length * 2, MaxBufferSize));
            }

            var read = await _stream.ReadAsync(_buffer.AsMemory(_length), cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                if (_length == 0)
                {
                    return null;
                }

                throw new ProtocolException($"connection closed mid-frame with {_length} buffered bytes");
            }

            _length += read;
        }
    }
}
