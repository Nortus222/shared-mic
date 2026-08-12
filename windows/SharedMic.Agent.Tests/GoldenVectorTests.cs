using SharedMic.Agent.Protocol;
using Xunit;

namespace SharedMic.Agent.Tests;

/// <summary>
/// protocol-v1.md section 10: an implementation is conformant only if it
/// produces and accepts the exact bytes in protocol/vectors/. Every case is
/// driven from the committed files, so a vector that is added, changed or
/// dropped changes this suite automatically instead of drifting from it.
/// </summary>
public class GoldenVectorTests
{
    [Fact]
    public void TheVectorFilesHoldTheCaseCountsTheContractPromises()
    {
        Assert.Equal(11, VectorFixtures.ControlVectors().Count);
        Assert.Equal(3, VectorFixtures.AudioVectors().Count);
    }

    [Fact]
    public void EveryControlMessageTypeInTheProtocolHasAVector()
    {
        var covered = VectorFixtures.ControlVectors()
            .Select(vector => ControlCodec.FromJsonElement(vector.Message)["type"] as string)
            .OrderBy(type => type, StringComparer.Ordinal)
            .ToArray();

        Assert.Equal(
            ControlCodec.RequiredFields.Keys.OrderBy(type => type, StringComparer.Ordinal).ToArray(),
            covered);
    }

    [Theory]
    [MemberData(nameof(VectorFixtures.ControlVectorNames), MemberType = typeof(VectorFixtures))]
    public void ControlVectorEncodesToExpectedBytes(string name)
    {
        var vector = VectorFixtures.Control(name);
        var message = ControlCodec.FromJsonElement(vector.Message);

        var frame = FrameCodec.EncodeFrame(FrameType.Control, ControlCodec.Encode(message));

        Assert.Equal(vector.Hex, Convert.ToHexString(frame).ToLowerInvariant());
    }

    [Theory]
    [MemberData(nameof(VectorFixtures.ControlVectorNames), MemberType = typeof(VectorFixtures))]
    public void ControlVectorDecodesToExpectedMessage(string name)
    {
        var vector = VectorFixtures.Control(name);
        var bytes = Convert.FromHexString(vector.Hex);

        Assert.True(FrameCodec.TryDecodeFrame(bytes, out var type, out var payload, out var consumed));
        Assert.Equal(FrameType.Control, type);
        Assert.Equal(bytes.Length, consumed);

        var decoded = ControlCodec.Decode(payload);
        var expected = ControlCodec.FromJsonElement(vector.Message);

        Assert.True(
            ControlCodec.DeepEquals(expected, decoded),
            $"vector '{name}' decoded to a different message than its 'message' field");
    }

    [Theory]
    [MemberData(nameof(VectorFixtures.AudioVectorNames), MemberType = typeof(VectorFixtures))]
    public void AudioVectorEncodesToExpectedBytes(string name)
    {
        var vector = VectorFixtures.Audio(name);
        var pcm = Convert.FromHexString(vector.PcmHex);

        Assert.Equal(ProtocolConstants.PcmBytesPerFrame, pcm.Length);

        var frame = FrameCodec.EncodeFrame(
            FrameType.Audio,
            AudioPayloadCodec.EncodeAudioPayload(vector.Sequence, vector.TimestampUs, pcm));

        Assert.Equal(vector.Hex, Convert.ToHexString(frame).ToLowerInvariant());
        Assert.Equal(ProtocolConstants.AudioEnvelopeSize, frame.Length);
    }

    [Theory]
    [MemberData(nameof(VectorFixtures.AudioVectorNames), MemberType = typeof(VectorFixtures))]
    public void AudioVectorDecodesToExpectedFrame(string name)
    {
        var vector = VectorFixtures.Audio(name);
        var bytes = Convert.FromHexString(vector.Hex);

        Assert.True(FrameCodec.TryDecodeFrame(bytes, out var type, out var payload, out var consumed));
        Assert.Equal(FrameType.Audio, type);
        Assert.Equal(bytes.Length, consumed);
        Assert.Equal(ProtocolConstants.AudioPayloadSize, payload.Length);

        var frame = AudioPayloadCodec.DecodeAudioPayload(payload);

        Assert.Equal(vector.Sequence, frame.Sequence);
        Assert.Equal(vector.TimestampUs, frame.CaptureTimestampUs);
        Assert.Equal(Convert.FromHexString(vector.PcmHex), frame.Pcm);
    }

    [Fact]
    public void AudioVectorTimestampsAdvanceByOneFrameDuration()
    {
        var frame0 = VectorFixtures.Audio("frame-0");
        var frame1 = VectorFixtures.Audio("frame-1");
        var frame49 = VectorFixtures.Audio("frame-49");

        Assert.Equal(0u, frame0.Sequence);
        Assert.Equal(0ul, frame0.TimestampUs);
        Assert.Equal(1u, frame1.Sequence);
        Assert.Equal((ulong)ProtocolConstants.FrameDurationUs, frame1.TimestampUs);
        Assert.Equal(49u, frame49.Sequence);
        Assert.Equal((ulong)(49 * ProtocolConstants.FrameDurationUs), frame49.TimestampUs);
    }

    [Fact]
    public void ConcatenatedVectorsDecodeAsAStreamWouldDeliverThem()
    {
        var ping = Convert.FromHexString(VectorFixtures.Control("PING").Hex);
        var pong = Convert.FromHexString(VectorFixtures.Control("PONG").Hex);
        var stream = ping.Concat(pong).ToArray();

        Assert.True(FrameCodec.TryDecodeFrame(stream, out _, out var firstPayload, out var firstConsumed));
        Assert.Equal("PING", ControlCodec.Decode(firstPayload)["type"]);
        Assert.Equal(ping.Length, firstConsumed);

        Assert.True(FrameCodec.TryDecodeFrame(stream.AsSpan(firstConsumed), out _, out var secondPayload, out var secondConsumed));
        Assert.Equal("PONG", ControlCodec.Decode(secondPayload)["type"]);
        Assert.Equal(pong.Length, secondConsumed);
    }
}
