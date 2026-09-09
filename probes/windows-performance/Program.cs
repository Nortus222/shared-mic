using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using SharedMic.Agent.Audio;
using SharedMic.Agent.Net;
using SharedMic.Agent.Protocol;

// Synthetic inputs only. Output contains timings and counters, never PCM.
const int batches = 40;
const int iterations = 1000;
var results = new List<object>();
var stereo48 = Signal(1920);
var stereo44 = Signal(1764);
var pcm = new byte[ProtocolConstants.PcmBytesPerFrame];
var frame = FrameCodec.EncodeFrame(FrameType.Audio, AudioPayloadCodec.EncodeAudioPayload(0, 0, pcm));
object? retained = null;

Measure("Normalize 48 kHz stereo / 20 ms", () => retained = PcmNormalizer.NormalizeInterleavedToMono48k(stereo48, 48000, 2, ChannelMode.Mix));
Measure("Resample 44.1 kHz stereo / 20 ms", () => retained = PcmNormalizer.NormalizeInterleavedToMono48k(stereo44, 44100, 2, ChannelMode.Mix));
Measure("Encode audio payload and envelope", () => retained = FrameCodec.EncodeFrame(FrameType.Audio, AudioPayloadCodec.EncodeAudioPayload(0, 0, pcm)));
Measure("Decode envelope and audio payload", () =>
{
    if (!FrameCodec.TryDecodeFrame(frame, out _, out var payload, out _)) throw new InvalidOperationException();
    retained = AudioPayloadCodec.DecodeAudioPayload(payload).Pcm;
});
var queue = new PrioritySendQueue();
Measure("Audio queue enqueue + dequeue / uncontended", () =>
{
    queue.EnqueueAudio(frame);
    if (!queue.TryDequeue(out var item)) throw new InvalidOperationException();
    retained = item;
});

foreach (var (rate, input, framesPerCallback) in new[]
{
    (48000, stereo48, 1), (44100, stereo44, 1), (48000, Signal(1920 * 5), 5),
})
{
    var capture = new SyntheticCapture(rate);
    var sink = new EncodingSink();
    using var service = new MicCaptureService("synthetic", ChannelMode.Mix, sink, new SyntheticFactory(capture));
    if (!service.TryStart(out var failure)) throw new InvalidOperationException(failure);
    Measure($"Capture service + encoding + queue / {rate} Hz / {framesPerCallback * 20} ms input",
        () => capture.Push(input), framesPerCallback);
    if (sink.Frames != (5000L + batches * iterations) * framesPerCallback)
        throw new InvalidOperationException("Unexpected synthetic output frame count.");
    service.Stop();
    long stoppedCount = sink.Frames;
    capture.Push(input);
    if (sink.Frames != stoppedCount) throw new InvalidOperationException("Audio after stop.");
}

var stalled = new PrioritySendQueue();
for (int i = 0; i < 1000; i++) stalled.EnqueueAudio(frame);
if (stalled.AudioDepth != 25 || stalled.AudioFramesEvicted != 975)
    throw new InvalidOperationException("Queue bound changed.");

GC.KeepAlive(retained);
Console.WriteLine(JsonSerializer.Serialize(new
{
    generatedUtc = DateTimeOffset.UtcNow,
    runtime = RuntimeInformation.FrameworkDescription,
    os = RuntimeInformation.OSDescription,
    architecture = RuntimeInformation.ProcessArchitecture.ToString(),
    logicalProcessors = Environment.ProcessorCount,
    stopwatchFrequency = Stopwatch.Frequency,
    batches, iterationsPerBatch = iterations, warmupIterations = 5000,
    percentileMethod = "Nearest rank of 40 batch means; not per-frame tail latency",
    results,
    queueCheck = new { offered = 1000, depth = stalled.AudioDepth, evicted = stalled.AudioFramesEvicted },
    stream = new { framesPerSecond = 50, bytesPerFrame = frame.Length, bytesPerSecond = frame.Length * 50 },
}, new JsonSerializerOptions { WriteIndented = true }));

void Measure(string name, Action operation, int framesPerOperation = 1)
{
    for (int i = 0; i < 5000; i++) operation();
    GC.Collect();
    GC.WaitForPendingFinalizers();
    GC.Collect();
    var elapsed = new double[batches];
    long allocated = 0;
    int gen0 = GC.CollectionCount(0);
    int gen1 = GC.CollectionCount(1);
    int gen2 = GC.CollectionCount(2);
    for (int batch = 0; batch < batches; batch++)
    {
        long beforeBytes = GC.GetAllocatedBytesForCurrentThread();
        long start = Stopwatch.GetTimestamp();
        for (int i = 0; i < iterations; i++) operation();
        long end = Stopwatch.GetTimestamp();
        allocated += GC.GetAllocatedBytesForCurrentThread() - beforeBytes;
        elapsed[batch] = (end - start) * 1_000_000.0 / Stopwatch.Frequency / iterations;
    }
    double[] sorted = elapsed.Order().ToArray();
    results.Add(new
    {
        name, framesPerOperation,
        medianUs = sorted[(int)Math.Ceiling(batches * 0.5) - 1],
        p95BatchMeanUs = sorted[(int)Math.Ceiling(batches * 0.95) - 1],
        minBatchMeanUs = sorted[0], maxBatchMeanUs = sorted[^1],
        allocatedBytesPerOperation = allocated / (double)(batches * iterations),
        gen0Collections = GC.CollectionCount(0) - gen0,
        gen1Collections = GC.CollectionCount(1) - gen1,
        gen2Collections = GC.CollectionCount(2) - gen2,
        batchMeanUs = elapsed,
    });
}

static float[] Signal(int length) => Enumerable.Range(0, length)
    .Select(i => (float)(0.4 * Math.Sin(i * 0.13))).ToArray();

sealed class SyntheticCapture(int rate) : IAudioCapture
{
    public int SampleRate => rate;
    public int Channels => 2;
    public event Action<float[]>? DataAvailable;
    public event Action? CaptureLost { add { } remove { } }
    public void Start() { }
    public void Stop() { }
    public void Dispose() { }
    public void Push(float[] samples) => DataAvailable?.Invoke(samples);
}

sealed class SyntheticFactory(SyntheticCapture capture) : IAudioCaptureFactory
{
    public IAudioCapture Open(string endpointId) => capture;
}

// Mirrors ControlConnection.OnCaptureFrame and drains immediately; excludes TLS and contention.
sealed class EncodingSink : ICaptureSink
{
    private readonly PrioritySendQueue queue = new();
    public long Frames { get; private set; }
    public void OnCaptureFrame(byte[] pcm, uint sequence, ulong timestampUs)
    {
        queue.EnqueueAudio(FrameCodec.EncodeFrame(FrameType.Audio,
            AudioPayloadCodec.EncodeAudioPayload(sequence, timestampUs, pcm)));
        if (!queue.TryDequeue(out var encoded) || encoded.Length != ProtocolConstants.AudioEnvelopeSize)
            throw new InvalidOperationException("Invalid encoded frame.");
        Frames++;
    }
}
