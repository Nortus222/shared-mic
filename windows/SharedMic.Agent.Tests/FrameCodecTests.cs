using SharedMic.Agent.Protocol;
using Xunit;

namespace SharedMic.Agent.Tests;

public class FrameCodecTests
{
    [Fact]
    public void EncodesTheFiveByteBigEndianEnvelope()
    {
        var payload = "{\"type\":\"PING\"}"u8.ToArray();

        var frame = FrameCodec.EncodeFrame(FrameType.Control, payload);

        Assert.Equal(
            "010000000f7b2274797065223a2250494e47227d",
            Convert.ToHexString(frame).ToLowerInvariant());
    }

    [Fact]
    public void LengthIsBigEndianForMultiByteLengths()
    {
        var payload = new byte[300];

        var frame = FrameCodec.EncodeFrame(FrameType.Audio, payload);

        Assert.Equal(2, frame[0]);
        Assert.Equal(0x00, frame[1]);
        Assert.Equal(0x00, frame[2]);
        Assert.Equal(0x01, frame[3]);
        Assert.Equal(0x2c, frame[4]);
        Assert.Equal(305, frame.Length);
    }

    [Fact]
    public void RoundTripsAControlFrame()
    {
        var payload = new byte[] { 1, 2, 3, 4, 5 };
        var frame = FrameCodec.EncodeFrame(FrameType.Control, payload);

        Assert.True(FrameCodec.TryDecodeFrame(frame, out var type, out var decoded, out var consumed));
        Assert.Equal(FrameType.Control, type);
        Assert.Equal(payload, decoded);
        Assert.Equal(frame.Length, consumed);
    }

    [Fact]
    public void ReturnsFalseWhenHeaderIsIncomplete()
    {
        Assert.False(FrameCodec.TryDecodeFrame(new byte[] { 1, 0, 0 }, out _, out _, out var consumed));
        Assert.Equal(0, consumed);
    }

    [Fact]
    public void ReturnsFalseWhenPayloadIsIncomplete()
    {
        var frame = FrameCodec.EncodeFrame(FrameType.Control, new byte[] { 9, 9, 9, 9 });

        Assert.False(FrameCodec.TryDecodeFrame(frame.AsSpan(0, frame.Length - 1), out _, out _, out var consumed));
        Assert.Equal(0, consumed);
    }

    [Fact]
    public void ReportsConsumedSoAStreamCanHoldTwoFrames()
    {
        var first = FrameCodec.EncodeFrame(FrameType.Control, new byte[] { 1 });
        var second = FrameCodec.EncodeFrame(FrameType.Control, new byte[] { 2, 2 });
        var buffer = first.Concat(second).ToArray();

        Assert.True(FrameCodec.TryDecodeFrame(buffer, out _, out var firstPayload, out var firstConsumed));
        Assert.Equal(new byte[] { 1 }, firstPayload);
        Assert.Equal(6, firstConsumed);

        Assert.True(FrameCodec.TryDecodeFrame(buffer.AsSpan(firstConsumed), out _, out var secondPayload, out var secondConsumed));
        Assert.Equal(new byte[] { 2, 2 }, secondPayload);
        Assert.Equal(7, secondConsumed);
    }

    [Fact]
    public void DecodeRejectsUnknownFrameType()
    {
        var buffer = new byte[] { 3, 0, 0, 0, 0 };

        var error = Assert.Throws<ProtocolException>(() =>
            FrameCodec.TryDecodeFrame(buffer, out _, out _, out _));
        Assert.Contains("unknown frame type", error.Message);
    }

    [Fact]
    public void DecodeRejectsOversizedPayloadBeforeAllocatingForIt()
    {
        var buffer = new byte[] { 1, 0x00, 0x10, 0x00, 0x01 };

        var error = Assert.Throws<ProtocolException>(() =>
            FrameCodec.TryDecodeFrame(buffer, out _, out _, out _));
        Assert.Contains("payload too large", error.Message);
    }

    [Fact]
    public void EncodeRejectsAnOversizedPayload()
    {
        var payload = new byte[ProtocolConstants.MaxPayloadBytes + 1];

        Assert.Throws<ProtocolException>(() => FrameCodec.EncodeFrame(FrameType.Control, payload));
    }

    [Fact]
    public void EncodeRejectsAnUnknownFrameType()
    {
        Assert.Throws<ProtocolException>(() => FrameCodec.EncodeFrame((FrameType)7, new byte[] { 0 }));
    }

    [Fact]
    public void EncodesTheMaximumLegalPayload()
    {
        var payload = new byte[ProtocolConstants.MaxPayloadBytes];

        var frame = FrameCodec.EncodeFrame(FrameType.Audio, payload);

        Assert.Equal(ProtocolConstants.EnvelopeSize + ProtocolConstants.MaxPayloadBytes, frame.Length);
        Assert.True(FrameCodec.TryDecodeFrame(frame, out _, out var decoded, out _));
        Assert.Equal(ProtocolConstants.MaxPayloadBytes, decoded.Length);
    }
}
