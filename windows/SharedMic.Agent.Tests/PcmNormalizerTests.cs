using SharedMic.Agent.Audio;
using SharedMic.Agent.Protocol;
using Xunit;

namespace SharedMic.Agent.Tests;

public class PcmNormalizerTests
{
    [Fact]
    public void FloatToS16ClipsAtFullScale()
    {
        Assert.Equal(32767, PcmNormalizer.FloatToS16(1.0f));
        Assert.Equal(-32767, PcmNormalizer.FloatToS16(-1.0f));
        Assert.Equal(32767, PcmNormalizer.FloatToS16(1.5f));
        Assert.Equal(-32767, PcmNormalizer.FloatToS16(-1.5f));
        Assert.Equal(0, PcmNormalizer.FloatToS16(0.0f));
    }

    [Fact]
    public void FloatToS16MapsNonFiniteToSilence()
    {
        Assert.Equal(0, PcmNormalizer.FloatToS16(float.NaN));
        Assert.Equal(0, PcmNormalizer.FloatToS16(float.PositiveInfinity));
        Assert.Equal(0, PcmNormalizer.FloatToS16(float.NegativeInfinity));
    }

    [Fact]
    public void FloatToS16RoundsHalfUp()
    {
        Assert.Equal(16384, PcmNormalizer.FloatToS16(0.5f));
        Assert.Equal(-16384, PcmNormalizer.FloatToS16(-0.5f));
    }

    [Fact]
    public void MixHalvesSingleChannelSignalWhileLeftKeepsIt()
    {
        var interleaved = new float[ProtocolConstants.SamplesPerFrame * 2];
        for (int index = 0; index < ProtocolConstants.SamplesPerFrame; index++)
        {
            interleaved[index * 2] = 0.5f;
            interleaved[index * 2 + 1] = 0.0f;
        }

        short[] mixed = PcmNormalizer.NormalizeInterleaved48k(interleaved, 2, ChannelMode.Mix);
        short[] left = PcmNormalizer.NormalizeInterleaved48k(interleaved, 2, ChannelMode.Left);
        short[] right = PcmNormalizer.NormalizeInterleaved48k(interleaved, 2, ChannelMode.Right);

        Assert.Equal(8192, mixed[0]);
        Assert.Equal(16384, left[0]);
        Assert.Equal(0, right[0]);
    }

    [Fact]
    public void DualMonoSignalIsIdenticalUnderEveryMode()
    {
        var interleaved = new float[ProtocolConstants.SamplesPerFrame * 2];
        for (int index = 0; index < ProtocolConstants.SamplesPerFrame; index++)
        {
            interleaved[index * 2] = 0.25f;
            interleaved[index * 2 + 1] = 0.25f;
        }

        short[] mixed = PcmNormalizer.NormalizeInterleaved48k(interleaved, 2, ChannelMode.Mix);
        short[] left = PcmNormalizer.NormalizeInterleaved48k(interleaved, 2, ChannelMode.Left);
        short[] right = PcmNormalizer.NormalizeInterleaved48k(interleaved, 2, ChannelMode.Right);

        Assert.Equal(mixed, left);
        Assert.Equal(mixed, right);
    }

    [Fact]
    public void SilenceNormalizesToZeroBytes()
    {
        var interleaved = new float[ProtocolConstants.SamplesPerFrame * 2];
        short[] samples = PcmNormalizer.NormalizeInterleaved48k(interleaved, 2, ChannelMode.Mix);

        Assert.Equal(new short[ProtocolConstants.SamplesPerFrame], samples);
        Assert.Equal(new byte[ProtocolConstants.PcmBytesPerFrame], PcmNormalizer.ToS16LeBytes(samples));
    }

    [Fact]
    public void SineFrameHoldsPeakAndZeroCrossing()
    {
        var interleaved = new float[ProtocolConstants.SamplesPerFrame * 2];
        for (int index = 0; index < ProtocolConstants.SamplesPerFrame; index++)
        {
            float value = 0.5f * MathF.Sin(2.0f * MathF.PI * 440.0f * index / ProtocolConstants.SampleRate);
            interleaved[index * 2] = value;
            interleaved[index * 2 + 1] = value;
        }

        short[] samples = PcmNormalizer.NormalizeInterleaved48k(interleaved, 2, ChannelMode.Mix);

        Assert.Equal(0, samples[0]);
        short peak = samples.Max(s => Math.Abs(s));
        Assert.InRange(peak, 16000, 16600);
    }

    [Fact]
    public void Resample44k1StereoTo48kMonoHoldsLengthAndLevel()
    {
        const int inputRate = 44100;
        int inputFrames = inputRate * ProtocolConstants.FrameDurationMs / 1000;
        var interleaved = new float[inputFrames * 2];
        for (int index = 0; index < inputFrames; index++)
        {
            float value = 0.5f * MathF.Sin(2.0f * MathF.PI * 440.0f * index / inputRate);
            interleaved[index * 2] = value;
            interleaved[index * 2 + 1] = value;
        }

        short[] samples = PcmNormalizer.NormalizeInterleavedToMono48k(
            interleaved, inputRate, 2, ChannelMode.Mix);

        Assert.Equal(ProtocolConstants.SamplesPerFrame, samples.Length);
        short peak = samples.Max(s => Math.Abs(s));
        Assert.InRange(peak, 15500, 16800);
    }

    [Fact]
    public void ToS16LeBytesIsLittleEndian()
    {
        var samples = new short[ProtocolConstants.SamplesPerFrame];
        samples[0] = 0x0102;

        byte[] bytes = PcmNormalizer.ToS16LeBytes(samples);

        Assert.Equal(ProtocolConstants.PcmBytesPerFrame, bytes.Length);
        Assert.Equal(0x02, bytes[0]);
        Assert.Equal(0x01, bytes[1]);
    }

    [Fact]
    public void RejectsWrongLengthInput()
    {
        Assert.Throws<ArgumentException>(() =>
            PcmNormalizer.NormalizeMono48k(new float[100]));
        Assert.Throws<ArgumentException>(() =>
            PcmNormalizer.NormalizeInterleaved48k(new float[100], 2, ChannelMode.Mix));
        Assert.Throws<ArgumentException>(() =>
            PcmNormalizer.NormalizeInterleaved48k(
                new float[ProtocolConstants.SamplesPerFrame * 2], 3, ChannelMode.Mix));
        Assert.Throws<ArgumentException>(() =>
            PcmNormalizer.ToS16LeBytes(new short[100]));
    }
}
