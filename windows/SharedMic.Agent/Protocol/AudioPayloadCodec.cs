using System.Buffers.Binary;

namespace SharedMic.Agent.Protocol;

/// <summary>One decoded AUDIO frame. Never logged, only counted.</summary>
public readonly record struct AudioFrame(uint Sequence, ulong CaptureTimestampUs, byte[] Pcm);

/// <summary>
/// The AUDIO payload of protocol-v1.md section 4: a 12-byte big-endian header
/// followed by exactly 1,920 bytes of PCM.
///
/// The single most likely implementation mistake in this protocol is applying
/// the header's byte order to the PCM. The header fields are BIG-endian; the
/// 960 16-bit samples that follow are each LITTLE-endian (s16le). Use
/// ReadPcmSample and WritePcmSample rather than hand-rolling the shift, so the
/// byte order lives in exactly one place.
///
/// Phase 1 never calls the encoder on a live connection: there is no capture
/// path yet, and an idle connection must carry zero audio bytes.
/// </summary>
public static class AudioPayloadCodec
{
    public static byte[] EncodeAudioPayload(uint sequence, ulong captureTimestampUs, ReadOnlySpan<byte> pcm)
    {
        if (pcm.Length != ProtocolConstants.PcmBytesPerFrame)
        {
            throw new ProtocolException(
                $"an audio frame must carry exactly {ProtocolConstants.PcmBytesPerFrame} PCM bytes, got {pcm.Length}; " +
                "there is no partial frame in this protocol");
        }

        var payload = new byte[ProtocolConstants.AudioPayloadSize];
        BinaryPrimitives.WriteUInt32BigEndian(payload.AsSpan(0, 4), sequence);
        BinaryPrimitives.WriteUInt64BigEndian(payload.AsSpan(4, 8), captureTimestampUs);
        pcm.CopyTo(payload.AsSpan(ProtocolConstants.AudioHeaderSize));
        return payload;
    }

    public static AudioFrame DecodeAudioPayload(ReadOnlySpan<byte> payload)
    {
        if (payload.Length != ProtocolConstants.AudioPayloadSize)
        {
            throw new ProtocolException(
                $"an AUDIO payload must be exactly {ProtocolConstants.AudioPayloadSize} bytes, got {payload.Length}");
        }

        var sequence = BinaryPrimitives.ReadUInt32BigEndian(payload.Slice(0, 4));
        var timestamp = BinaryPrimitives.ReadUInt64BigEndian(payload.Slice(4, 8));
        return new AudioFrame(sequence, timestamp, payload.Slice(ProtocolConstants.AudioHeaderSize).ToArray());
    }

    public static short ReadPcmSample(ReadOnlySpan<byte> pcm, int index) =>
        BinaryPrimitives.ReadInt16LittleEndian(pcm.Slice(index * 2, 2));

    public static void WritePcmSample(Span<byte> pcm, int index, short sample) =>
        BinaryPrimitives.WriteInt16LittleEndian(pcm.Slice(index * 2, 2), sample);
}
