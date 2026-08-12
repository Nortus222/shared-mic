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

    [Fact]
    public async Task ReassemblesAFrameDeliveredOneByteAtATime()
    {
        var payload = new byte[37];
        Random.Shared.NextBytes(payload);
        var frame = FrameCodec.EncodeFrame(FrameType.Control, payload);

        using var wholeStream = new MemoryStream(frame);
        var whole = await new FrameReader(wholeStream).ReadFrameAsync(ShortDeadline());

        using var byteAtATimeStream = new ChunkedStream(frame, chunkSize: 1);
        var fragmented = await new FrameReader(byteAtATimeStream).ReadFrameAsync(ShortDeadline());

        // Every one of the 5 header bytes, and every payload byte, arrives in its own
        // Read call here. Assert byte-identical content against the whole-delivery
        // baseline, not just that a frame came back.
        Assert.Equal(whole!.Value.Type, fragmented!.Value.Type);
        Assert.Equal(whole.Value.Payload, fragmented.Value.Payload);
        Assert.Equal(FrameType.Control, fragmented.Value.Type);
        Assert.Equal(payload, fragmented.Value.Payload);
    }

    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(3)]
    [InlineData(4)]
    public async Task ReassemblesAFrameWhoseHeaderIsSplitAcrossReads(int headerSplitOffset)
    {
        var payload = new byte[] { 10, 20, 30, 40, 50 };
        var frame = FrameCodec.EncodeFrame(FrameType.Control, payload);

        // First Read call returns exactly `headerSplitOffset` bytes of the 5-byte header
        // (1..4, so the split always lands strictly inside the header, never at its
        // boundary); the second Read call returns everything else in one shot.
        using var stream = new FixedChunksStream(frame, headerSplitOffset);
        var reader = new FrameReader(stream);

        var received = await reader.ReadFrameAsync(ShortDeadline());

        Assert.Equal(FrameType.Control, received!.Value.Type);
        Assert.Equal(payload, received.Value.Payload);
    }

    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(3)]
    [InlineData(4)]
    public async Task ThrowsWhenTheStreamEndsInsideTheHeader(int headerBytesBeforeEof)
    {
        var frame = FrameCodec.EncodeFrame(FrameType.Control, new byte[] { 1, 2, 3, 4 });
        // Fewer than the 5 header bytes ever arrive, then the stream ends. This must be
        // reported as a truncated frame, never as a clean end-of-stream: it is the case
        // where a reader that special-cased "no bytes buffered yet" would silently hide
        // a real error.
        using var stream = new MemoryStream(frame.AsSpan(0, headerBytesBeforeEof).ToArray());
        var reader = new FrameReader(stream);

        var error = await Assert.ThrowsAsync<ProtocolException>(() => reader.ReadFrameAsync(ShortDeadline()));
        Assert.Contains("mid-frame", error.Message);
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

    /// <summary>
    /// A stream whose first Read call returns exactly <paramref name="firstChunkSize"/>
    /// bytes (letting a test land a split at a precise offset, e.g. inside the 5-byte
    /// header) and whose subsequent Read calls return all remaining data in one shot.
    /// </summary>
    private sealed class FixedChunksStream : Stream
    {
        private readonly byte[] _data;
        private readonly int _firstChunkSize;
        private int _position;
        private bool _firstReadDone;

        public FixedChunksStream(byte[] data, int firstChunkSize)
        {
            _data = data;
            _firstChunkSize = firstChunkSize;
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
            var chunkLimit = _firstReadDone ? _data.Length - _position : _firstChunkSize;
            _firstReadDone = true;
            var take = Math.Min(Math.Min(count, chunkLimit), _data.Length - _position);
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
