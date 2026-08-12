using SharedMic.Agent.Net;
using SharedMic.Agent.Protocol;
using Xunit;

namespace SharedMic.Agent.Tests;

public class FrameReaderTests
{
    private static CancellationToken ShortDeadline() => new CancellationTokenSource(TimeSpan.FromSeconds(5)).Token;

    [Fact]
    public async Task ReadsTwoConcatenatedFramesFromOneBuffer()
    {
        var first = FrameCodec.EncodeFrame(FrameType.Control, new byte[] { 1 });
        var second = FrameCodec.EncodeFrame(FrameType.Control, new byte[] { 2, 2 });
        using var stream = new MemoryStream(first.Concat(second).ToArray());
        var reader = new FrameReader(stream);

        var a = await reader.ReadFrameAsync(ShortDeadline());
        var b = await reader.ReadFrameAsync(ShortDeadline());
        var end = await reader.ReadFrameAsync(ShortDeadline());

        Assert.Equal(new byte[] { 1 }, a!.Value.Payload);
        Assert.Equal(new byte[] { 2, 2 }, b!.Value.Payload);
        Assert.Null(end);
    }

    [Fact]
    public async Task ReassemblesAFrameSplitAcrossReads()
    {
        var payload = new byte[600];
        Random.Shared.NextBytes(payload);
        var frame = FrameCodec.EncodeFrame(FrameType.Control, payload);
        using var stream = new ChunkedStream(frame, chunkSize: 7);
        var reader = new FrameReader(stream);

        var received = await reader.ReadFrameAsync(ShortDeadline());

        Assert.Equal(FrameType.Control, received!.Value.Type);
        Assert.Equal(payload, received.Value.Payload);
    }

    [Fact]
    public async Task ReadsAFullSizeAudioEnvelope()
    {
        var pcm = new byte[ProtocolConstants.PcmBytesPerFrame];
        Random.Shared.NextBytes(pcm);
        var frame = FrameCodec.EncodeFrame(FrameType.Audio, AudioPayloadCodec.EncodeAudioPayload(3u, 60000ul, pcm));
        using var stream = new ChunkedStream(frame, chunkSize: 511);
        var reader = new FrameReader(stream);

        var received = await reader.ReadFrameAsync(ShortDeadline());

        Assert.Equal(FrameType.Audio, received!.Value.Type);
        Assert.Equal(ProtocolConstants.AudioPayloadSize, received.Value.Payload.Length);
    }

    [Fact]
    public async Task ReturnsNullOnACleanEndOfStream()
    {
        using var stream = new MemoryStream(Array.Empty<byte>());
        var reader = new FrameReader(stream);

        Assert.Null(await reader.ReadFrameAsync(ShortDeadline()));
    }

    [Fact]
    public async Task ThrowsWhenTheStreamEndsMidFrame()
    {
        var frame = FrameCodec.EncodeFrame(FrameType.Control, new byte[] { 1, 2, 3, 4 });
        using var stream = new MemoryStream(frame.AsSpan(0, frame.Length - 2).ToArray());
        var reader = new FrameReader(stream);

        var error = await Assert.ThrowsAsync<ProtocolException>(() => reader.ReadFrameAsync(ShortDeadline()));
        Assert.Contains("mid-frame", error.Message);
    }

    [Fact]
    public async Task PropagatesAnUnknownFrameTypeAsAProtocolViolation()
    {
        using var stream = new MemoryStream(new byte[] { 9, 0, 0, 0, 0 });
        var reader = new FrameReader(stream);

        await Assert.ThrowsAsync<ProtocolException>(() => reader.ReadFrameAsync(ShortDeadline()));
    }

    [Fact]
    public async Task PropagatesAnOversizedLengthAsAProtocolViolation()
    {
        using var stream = new MemoryStream(new byte[] { 1, 0x00, 0x10, 0x00, 0x01, 0x00 });
        var reader = new FrameReader(stream);

        await Assert.ThrowsAsync<ProtocolException>(() => reader.ReadFrameAsync(ShortDeadline()));
    }

    /// <summary>A stream that hands out at most `chunkSize` bytes per read.</summary>
    private sealed class ChunkedStream : Stream
    {
        private readonly byte[] _data;
        private readonly int _chunkSize;
        private int _position;

        public ChunkedStream(byte[] data, int chunkSize)
        {
            _data = data;
            _chunkSize = chunkSize;
        }

        public override bool CanRead => true;

        public override bool CanSeek => false;

        public override bool CanWrite => false;

        public override long Length => _data.Length;

        public override long Position
        {
            get => _position;
            set => throw new NotSupportedException();
        }

        public override int Read(byte[] buffer, int offset, int count)
        {
            var take = Math.Min(Math.Min(count, _chunkSize), _data.Length - _position);
            Array.Copy(_data, _position, buffer, offset, take);
            _position += take;
            return take;
        }

        public override void Flush()
        {
        }

        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();

        public override void SetLength(long value) => throw new NotSupportedException();

        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
