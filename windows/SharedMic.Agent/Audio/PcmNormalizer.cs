using SharedMic.Agent.Protocol;

namespace SharedMic.Agent.Audio;

public static class PcmNormalizer
{
    private const float FullScale = 32767f;

    public static short FloatToS16(float sample)
    {
        if (!float.IsFinite(sample))
        {
            return 0;
        }

        float clamped = Math.Clamp(sample, -1f, 1f);
        int rounded = (int)MathF.Round(clamped * FullScale, MidpointRounding.AwayFromZero);
        return (short)Math.Clamp(rounded, short.MinValue, short.MaxValue);
    }

    public static float DownmixFrame(float left, float right, ChannelMode mode) => mode switch
    {
        ChannelMode.Left => left,
        ChannelMode.Right => right,
        _ => (left + right) * 0.5f,
    };

    public static short[] NormalizeMono48k(ReadOnlySpan<float> mono)
    {
        if (mono.Length != ProtocolConstants.SamplesPerFrame)
        {
            throw new ArgumentException(
                $"mono input must hold exactly {ProtocolConstants.SamplesPerFrame} samples, got {mono.Length}");
        }

        var output = new short[ProtocolConstants.SamplesPerFrame];
        for (int index = 0; index < output.Length; index++)
        {
            output[index] = FloatToS16(mono[index]);
        }

        return output;
    }

    public static short[] NormalizeInterleaved48k(ReadOnlySpan<float> interleaved, int channels, ChannelMode mode)
    {
        if (channels is not 1 and not 2)
        {
            throw new ArgumentException($"channels must be 1 or 2, got {channels}");
        }

        if (interleaved.Length != ProtocolConstants.SamplesPerFrame * channels)
        {
            throw new ArgumentException(
                $"interleaved input must hold exactly {ProtocolConstants.SamplesPerFrame * channels} floats, got {interleaved.Length}");
        }

        var output = new short[ProtocolConstants.SamplesPerFrame];
        for (int index = 0; index < output.Length; index++)
        {
            float monoFloat = channels == 1
                ? interleaved[index]
                : DownmixFrame(interleaved[index * 2], interleaved[index * 2 + 1], mode);
            output[index] = FloatToS16(monoFloat);
        }

        return output;
    }

    public static short[] NormalizeInterleavedToMono48k(
        ReadOnlySpan<float> interleaved, int inputSampleRate, int inputChannels, ChannelMode mode)
    {
        if (inputSampleRate <= 0)
        {
            throw new ArgumentException($"inputSampleRate must be positive, got {inputSampleRate}");
        }

        if (inputChannels is not 1 and not 2)
        {
            throw new ArgumentException($"channels must be 1 or 2, got {inputChannels}");
        }

        if (inputSampleRate == ProtocolConstants.SampleRate)
        {
            return NormalizeInterleaved48k(interleaved, inputChannels, mode);
        }

        int inputFrames = checked((int)((long)inputSampleRate * ProtocolConstants.FrameDurationMs / 1000));
        if (interleaved.Length != inputFrames * inputChannels)
        {
            throw new ArgumentException(
                $"interleaved input must hold exactly {inputFrames * inputChannels} floats for {inputSampleRate} Hz, got {interleaved.Length}");
        }

        Span<float> mono = stackalloc float[inputFrames];
        for (int index = 0; index < inputFrames; index++)
        {
            mono[index] = inputChannels == 1
                ? interleaved[index]
                : DownmixFrame(interleaved[index * 2], interleaved[index * 2 + 1], mode);
        }

        return ResampleMonoLinearTo48k(mono, inputSampleRate);
    }

    public static byte[] ToS16LeBytes(ReadOnlySpan<short> samples)
    {
        if (samples.Length != ProtocolConstants.SamplesPerFrame)
        {
            throw new ArgumentException(
                $"samples must hold exactly {ProtocolConstants.SamplesPerFrame} entries, got {samples.Length}");
        }

        var bytes = new byte[ProtocolConstants.PcmBytesPerFrame];
        for (int index = 0; index < samples.Length; index++)
        {
            AudioPayloadCodec.WritePcmSample(bytes, index, samples[index]);
        }

        return bytes;
    }

    private static short[] ResampleMonoLinearTo48k(ReadOnlySpan<float> mono, int inputSampleRate)
    {
        int inputFrames = mono.Length;
        var output = new short[ProtocolConstants.SamplesPerFrame];
        for (int index = 0; index < output.Length; index++)
        {
            double position = (double)index * inputFrames / ProtocolConstants.SamplesPerFrame;
            int lower = (int)position;
            if (lower >= inputFrames - 1)
            {
                output[index] = FloatToS16(mono[inputFrames - 1]);
                continue;
            }

            double fraction = position - lower;
            float interpolated = (float)(mono[lower] * (1.0 - fraction) + mono[lower + 1] * fraction);
            output[index] = FloatToS16(interpolated);
        }

        return output;
    }
}
