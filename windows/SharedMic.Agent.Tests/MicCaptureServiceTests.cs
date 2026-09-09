using SharedMic.Agent.Audio;
using SharedMic.Agent.Protocol;
using Xunit;

namespace SharedMic.Agent.Tests;

public class MicCaptureServiceTests
{
    [Fact]
    public void PartialBufferEmitsNothingUntilAFullFrameArrives()
    {
        var factory = new FakeCaptureFactory();
        var sink = new FakeSink();
        using var service = new MicCaptureService("endpoint", ChannelMode.Mix, sink, factory);

        Assert.True(service.TryStart(out string? failure));
        Assert.Null(failure);

        factory.Capture.Push(new float[100 * 2]);
        Assert.Empty(sink.Frames);

        factory.Capture.Push(new float[860 * 2]);
        Assert.Single(sink.Frames);
        Assert.Equal(ProtocolConstants.PcmBytesPerFrame, sink.Frames[0].Pcm.Length);
    }

    [Fact]
    public void SequenceStartsAtZeroAndTimestampsAdvanceByFrameDuration()
    {
        var factory = new FakeCaptureFactory();
        var sink = new FakeSink();
        using var service = new MicCaptureService("endpoint", ChannelMode.Mix, sink, factory);

        Assert.True(service.TryStart(out _));
        factory.Capture.Push(new float[960 * 2 * 3]);

        Assert.Equal(3, sink.Frames.Count);
        Assert.Equal(0u, sink.Frames[0].Sequence);
        Assert.Equal(1u, sink.Frames[1].Sequence);
        Assert.Equal(2u, sink.Frames[2].Sequence);
        Assert.Equal(0ul, sink.Frames[0].TimestampUs);
        Assert.Equal(20000ul, sink.Frames[1].TimestampUs);
        Assert.Equal(40000ul, sink.Frames[2].TimestampUs);
    }

    [Fact]
    public void SequenceResetsToZeroOnANewSession()
    {
        var factory = new FakeCaptureFactory();
        var sink = new FakeSink();
        using var service = new MicCaptureService("endpoint", ChannelMode.Mix, sink, factory);

        Assert.True(service.TryStart(out _));
        factory.Capture.Push(new float[960 * 2 * 2]);
        service.Stop();

        Assert.True(service.TryStart(out _));
        factory.Capture.Push(new float[960 * 2]);

        Assert.Equal(3, sink.Frames.Count);
        Assert.Equal(0u, sink.Frames[2].Sequence);
        Assert.Equal(0ul, sink.Frames[2].TimestampUs);
    }

    [Fact]
    public void StopDropsThePartialTailWithoutAShortFrame()
    {
        var factory = new FakeCaptureFactory();
        var sink = new FakeSink();
        using var service = new MicCaptureService("endpoint", ChannelMode.Mix, sink, factory);

        Assert.True(service.TryStart(out _));
        factory.Capture.Push(new float[960 * 2]);
        factory.Capture.Push(new float[500 * 2]);
        service.Stop();

        Assert.Single(sink.Frames);

        Assert.True(service.TryStart(out _));
        factory.Capture.Push(new float[460 * 2]);
        Assert.Single(sink.Frames);
    }

    [Fact]
    public void SessionPeaksTrackPreMixChannelLevels()
    {
        var factory = new FakeCaptureFactory();
        var sink = new FakeSink();
        using var service = new MicCaptureService("endpoint", ChannelMode.Mix, sink, factory);

        Assert.True(service.TryStart(out _));
        var signal = new float[960 * 2];
        for (int index = 0; index < 960; index++)
        {
            signal[index * 2] = 0.5f;
            signal[index * 2 + 1] = 0.0f;
        }

        factory.Capture.Push(signal);

        Assert.Equal(0.5f, service.SessionPeakLeft);
        Assert.Equal(0.0f, service.SessionPeakRight);
    }

    [Fact]
    public void FailedOpenReportsMicUnavailable()
    {
        var factory = new FakeCaptureFactory { ThrowOnOpen = true };
        var sink = new FakeSink();
        using var service = new MicCaptureService("endpoint", ChannelMode.Mix, sink, factory);

        Assert.False(service.TryStart(out string? failure));
        Assert.Equal("MIC_UNAVAILABLE", failure);
        Assert.False(service.IsRunning);
    }

    [Fact]
    public void CaptureLossStopsTheServiceAndRaisesTheEvent()
    {
        var factory = new FakeCaptureFactory();
        var sink = new FakeSink();
        using var service = new MicCaptureService("endpoint", ChannelMode.Mix, sink, factory);

        bool lost = false;
        service.CaptureLost += () => lost = true;

        Assert.True(service.TryStart(out _));
        factory.Capture.RaiseCaptureLost();

        Assert.True(lost);
        Assert.False(service.IsRunning);
    }

    [Fact]
    public void LevelMeterTracksSignalPresence()
    {
        var factory = new FakeCaptureFactory();
        var sink = new FakeSink();
        using var service = new MicCaptureService("endpoint", ChannelMode.Mix, sink, factory);

        Assert.True(service.TryStart(out _));
        Assert.Equal(0f, service.LastPeak);

        var loud = new float[960 * 2];
        Array.Fill(loud, 0.5f);
        factory.Capture.Push(loud);

        Assert.InRange(service.LastPeak, 0.49f, 0.51f);
    }

    private sealed record Frame(byte[] Pcm, uint Sequence, ulong TimestampUs);

    private sealed class FakeSink : ICaptureSink
    {
        public List<Frame> Frames { get; } = new();

        public void OnCaptureFrame(byte[] pcm, uint sequence, ulong timestampUs) =>
            Frames.Add(new Frame(pcm, sequence, timestampUs));
    }

    private sealed class FakeCaptureFactory : IAudioCaptureFactory
    {
        public bool ThrowOnOpen { get; set; }

        public FakeCapture Capture { get; } = new();

        public IAudioCapture Open(string endpointId)
        {
            if (ThrowOnOpen)
            {
                throw new IOException("no device");
            }

            return Capture;
        }
    }

    private sealed class FakeCapture : IAudioCapture
    {
        public int SampleRate => 48000;

        public int Channels => 2;

        public event Action<float[]>? DataAvailable;

        public event Action? CaptureLost;

        public void Push(float[] interleaved) => DataAvailable?.Invoke(interleaved);

        public void RaiseCaptureLost() => CaptureLost?.Invoke();

        public void Start()
        {
        }

        public void Stop()
        {
        }

        public void Dispose()
        {
        }
    }
}

