using SharedMic.Agent.Protocol;
using Xunit;

namespace SharedMic.Agent.Tests;

public class AudioPayloadCodecTests
{
    private static byte[] Pcm(short fill)
    {
        var pcm = new byte[ProtocolConstants.PcmBytesPerFrame];
        for (var i = 0; i < ProtocolConstants.SamplesPerFrame; i++)
        {
            AudioPayloadCodec.WritePcmSample(pcm, i, fill);
        }

        return pcm;
    }

    [Fact]
    public void HeaderIsTwelveBytesAndBigEndian()
    {
        var payload = AudioPayloadCodec.EncodeAudioPayload(0x01020304u, 0x05060708090A0B0Cul, Pcm(0));

        Assert.Equal(ProtocolConstants.AudioPayloadSize, payload.Length);
        Assert.Equal(
            "0102030405060708090a0b0c",
            Convert.ToHexString(payload.AsSpan(0, ProtocolConstants.AudioHeaderSize)).ToLowerInvariant());
    }

    [Fact]
    public void PcmSamplesAreLittleEndianEvenThoughTheHeaderIsBigEndian()
    {
        var pcm = new byte[ProtocolConstants.PcmBytesPerFrame];
        AudioPayloadCodec.WritePcmSample(pcm, 0, unchecked((short)0xBEEF));

        Assert.Equal(0xEF, pcm[0]);
        Assert.Equal(0xBE, pcm[1]);
        Assert.Equal(unchecked((short)0xBEEF), AudioPayloadCodec.ReadPcmSample(pcm, 0));
    }

    [Fact]
    public void RoundTripsAFullFrame()
    {
        var pcm = Pcm(-1234);

        var decoded = AudioPayloadCodec.DecodeAudioPayload(
            AudioPayloadCodec.EncodeAudioPayload(49u, 980000ul, pcm));

        Assert.Equal(49u, decoded.Sequence);
        Assert.Equal(980000ul, decoded.CaptureTimestampUs);
        Assert.Equal(pcm, decoded.Pcm);
        Assert.Equal(-1234, AudioPayloadCodec.ReadPcmSample(decoded.Pcm, 500));
    }

    [Fact]
    public void EncodeRefusesAShortPcmBuffer()
    {
        var error = Assert.Throws<ProtocolException>(() =>
            AudioPayloadCodec.EncodeAudioPayload(0u, 0ul, new byte[ProtocolConstants.PcmBytesPerFrame - 2]));

        Assert.Contains("1920", error.Message);
    }

    [Fact]
    public void EncodeRefusesAnOverlongPcmBuffer()
    {
        Assert.Throws<ProtocolException>(() =>
            AudioPayloadCodec.EncodeAudioPayload(0u, 0ul, new byte[ProtocolConstants.PcmBytesPerFrame + 2]));
    }

    [Fact]
    public void DecodeRefusesAnythingOtherThanExactly1932Bytes()
    {
        Assert.Throws<ProtocolException>(() =>
            AudioPayloadCodec.DecodeAudioPayload(new byte[ProtocolConstants.AudioPayloadSize - 1]));
        Assert.Throws<ProtocolException>(() =>
            AudioPayloadCodec.DecodeAudioPayload(new byte[ProtocolConstants.AudioPayloadSize + 1]));
        Assert.Throws<ProtocolException>(() =>
            AudioPayloadCodec.DecodeAudioPayload(new byte[ProtocolConstants.AudioHeaderSize]));
    }

    [Fact]
    public void FullAudioEnvelopeIs1937Bytes()
    {
        var frame = FrameCodec.EncodeFrame(
            FrameType.Audio,
            AudioPayloadCodec.EncodeAudioPayload(0u, 0ul, Pcm(0)));

        Assert.Equal(ProtocolConstants.AudioEnvelopeSize, frame.Length);
        Assert.Equal(1937, frame.Length);
    }
}
