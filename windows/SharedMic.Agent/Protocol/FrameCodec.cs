using System.Buffers.Binary;

namespace SharedMic.Agent.Protocol;

/// <summary>
/// The 5-byte envelope of protocol-v1.md section 3: one type byte and a
/// big-endian uint32 payload length. Pure: no sockets, no logging, no I/O.
/// Byte-matched against protocol/vectors by GoldenVectorTests.
/// </summary>
public static class FrameCodec
{
    public static byte[] EncodeFrame(FrameType type, ReadOnlySpan<byte> payload)
    {
        if (type != FrameType.Control && type != FrameType.Audio)
        {
            throw new ProtocolException($"unknown frame type {(byte)type}");
        }

        if (payload.Length > ProtocolConstants.MaxPayloadBytes)
        {
            throw new ProtocolException($"payload too large: {payload.Length} bytes");
        }

        var frame = new byte[ProtocolConstants.EnvelopeSize + payload.Length];
        frame[0] = (byte)type;
        BinaryPrimitives.WriteUInt32BigEndian(frame.AsSpan(1, 4), (uint)payload.Length);
        payload.CopyTo(frame.AsSpan(ProtocolConstants.EnvelopeSize));
        return frame;
    }

    /// <summary>
    /// Decode one envelope from the front of <paramref name="buffer"/>.
    /// Returns false when the buffer does not yet hold a complete envelope,
    /// which is "wait for more data", never a wrong answer. Throws
    /// <see cref="ProtocolException"/> on a violation; the caller must close
    /// the connection rather than resynchronize.
    /// </summary>
    public static bool TryDecodeFrame(
        ReadOnlySpan<byte> buffer,
        out FrameType type,
        out byte[] payload,
        out int consumed)
    {
        type = default;
        payload = Array.Empty<byte>();
        consumed = 0;

        if (buffer.Length < ProtocolConstants.EnvelopeSize)
        {
            return false;
        }

        var rawType = buffer[0];
        if (rawType != (byte)FrameType.Control && rawType != (byte)FrameType.Audio)
        {
            throw new ProtocolException($"unknown frame type {rawType}");
        }

        var length = BinaryPrimitives.ReadUInt32BigEndian(buffer.Slice(1, 4));
        if (length > (uint)ProtocolConstants.MaxPayloadBytes)
        {
            throw new ProtocolException($"payload too large: {length} bytes");
        }

        var total = ProtocolConstants.EnvelopeSize + (int)length;
        if (buffer.Length < total)
        {
            return false;
        }

        type = (FrameType)rawType;
        payload = buffer.Slice(ProtocolConstants.EnvelopeSize, (int)length).ToArray();
        consumed = total;
        return true;
    }
}
