using System.Text;
using System.Text.Json;
using SharedMic.Agent.Protocol;
using Xunit;

namespace SharedMic.Agent.Tests;

public class ControlCodecTests
{
    [Fact]
    public void EncodesWithSortedKeysAndNoSeparatorWhitespace()
    {
        var message = new Dictionary<string, object?>
        {
            ["v"] = 1L,
            ["type"] = "PONG",
            ["seq"] = 7L,
        };

        Assert.Equal("{\"seq\":7,\"type\":\"PONG\",\"v\":1}", Encoding.UTF8.GetString(ControlCodec.Encode(message)));
    }

    [Fact]
    public void SortsNestedObjectKeysToo()
    {
        var json = Encoding.UTF8.GetString(ControlCodec.Encode(ControlMessages.Start("req-0001")));

        Assert.Equal(
            "{\"preferredFormat\":{\"channels\":1,\"sampleFormat\":\"s16le\",\"sampleRate\":48000}," +
            "\"requestId\":\"req-0001\",\"type\":\"START\",\"v\":1}",
            json);
    }

    [Fact]
    public void KeyOrderAtTheCallSiteDoesNotChangeTheBytes()
    {
        var a = new Dictionary<string, object?> { ["v"] = 1L, ["type"] = "STOP", ["requestId"] = "r", ["sessionId"] = "s" };
        var b = new Dictionary<string, object?> { ["sessionId"] = "s", ["requestId"] = "r", ["type"] = "STOP", ["v"] = 1L };

        Assert.Equal(ControlCodec.Encode(a), ControlCodec.Encode(b));
    }

    [Fact]
    public void EncodesAsUtf8WithoutAsciiEscaping()
    {
        var message = ControlMessages.HelloAck("win-desktop", true, "Mikrofón");

        var frame = FrameCodec.EncodeFrame(FrameType.Control, ControlCodec.Encode(message));

        Assert.Equal(
            "010000005f7b226465766963654c6162656c223a224d696b726f66c3b36e222c226d696350726573" +
            "656e74223a747275652c227365727665724964223a2277696e2d6465736b746f70222c2274797065" +
            "223a2248454c4c4f5f41434b222c2276223a317d",
            Convert.ToHexString(frame).ToLowerInvariant());
    }

    [Fact]
    public void IntegersEncodeWithoutADecimalPoint()
    {
        var message = new Dictionary<string, object?> { ["v"] = 1, ["type"] = "PING", ["seq"] = 42 };

        Assert.Equal("{\"seq\":42,\"type\":\"PING\",\"v\":1}", Encoding.UTF8.GetString(ControlCodec.Encode(message)));
    }

    [Fact]
    public void DecodesToTheSameLogicalMessage()
    {
        var message = ControlMessages.StartAck("req-0001", "sess-0001");

        var decoded = ControlCodec.Decode(ControlCodec.Encode(message));

        Assert.True(ControlCodec.DeepEquals(ControlCodec.Normalize(message), decoded));
        Assert.Equal("sess-0001", decoded["sessionId"]);
        Assert.Equal(1L, decoded["v"]);
    }

    [Fact]
    public void RejectsWrongProtocolVersionOnDecode()
    {
        var payload = Encoding.UTF8.GetBytes("{\"seq\":1,\"type\":\"PING\",\"v\":2}");

        var error = Assert.Throws<ProtocolException>(() => ControlCodec.Decode(payload));
        Assert.Contains("unsupported protocol version", error.Message);
    }

    [Fact]
    public void RejectsUnknownMessageType()
    {
        var payload = Encoding.UTF8.GetBytes("{\"type\":\"NOPE\",\"v\":1}");

        Assert.Throws<ProtocolException>(() => ControlCodec.Decode(payload));
    }

    [Fact]
    public void RejectsMissingRequiredField()
    {
        var payload = Encoding.UTF8.GetBytes("{\"requestId\":\"r\",\"type\":\"START_ACK\",\"v\":1}");

        var error = Assert.Throws<ProtocolException>(() => ControlCodec.Decode(payload));
        Assert.Contains("missing required field", error.Message);
    }

    [Fact]
    public void RejectsMalformedJson()
    {
        Assert.Throws<ProtocolException>(() => ControlCodec.Decode(Encoding.UTF8.GetBytes("{\"type\":")));
    }

    [Fact]
    public void RejectsNonObjectJson()
    {
        Assert.Throws<ProtocolException>(() => ControlCodec.Decode(Encoding.UTF8.GetBytes("[1,2,3]")));
    }

    [Fact]
    public void RejectsInvalidUtf8()
    {
        Assert.Throws<ProtocolException>(() => ControlCodec.Decode(new byte[] { 0x7b, 0xff, 0xfe, 0x7d }));
    }

    [Fact]
    public void ValidatesOnEncodeTooSoAHarnessBugIsLoud()
    {
        var message = new Dictionary<string, object?> { ["v"] = 1L, ["type"] = "PONG" };

        Assert.Throws<ProtocolException>(() => ControlCodec.Encode(message));
    }

    [Fact]
    public void RequiredFieldsTableCoversExactlyElevenTypes()
    {
        Assert.Equal(11, ControlCodec.RequiredFields.Count);
        Assert.Equal(
            new[]
            {
                "GREETING", "HELLO", "HELLO_ACK", "PING", "PONG", "START", "START_ACK",
                "START_NACK", "STATUS", "STOP", "STOP_ACK",
            },
            ControlCodec.RequiredFields.Keys.OrderBy(k => k, StringComparer.Ordinal).ToArray());
    }

    [Fact]
    public void EveryFactoryProducesAMessageTheCodecAccepts()
    {
        var messages = new[]
        {
            ControlMessages.Greeting("win-desktop", new string('0', 64)),
            ControlMessages.Hello("mac-studio", new string('a', 64)),
            ControlMessages.HelloAck("win-desktop", true, "USB Microphone"),
            ControlMessages.Start("req-0001"),
            ControlMessages.StartAck("req-0001", "sess-0001"),
            ControlMessages.StartNack("req-0002", "MIC_UNAVAILABLE"),
            ControlMessages.Stop("req-0003", "sess-0001"),
            ControlMessages.StopAck("req-0003", "sess-0001"),
            ControlMessages.Status(false, false, "USB Microphone"),
            ControlMessages.Ping(1L),
            ControlMessages.Pong(1L),
        };

        foreach (var message in messages)
        {
            var decoded = ControlCodec.Decode(ControlCodec.Encode(message));
            Assert.True(ControlCodec.DeepEquals(ControlCodec.Normalize(message), decoded));
        }
    }

    [Fact]
    public void FromJsonElementBuildsTheSameModelTheDecoderDoes()
    {
        using var document = JsonDocument.Parse("{\"v\":1,\"type\":\"STATUS\",\"micPresent\":false,\"active\":false,\"deviceLabel\":\"x\"}");

        var fromElement = ControlCodec.FromJsonElement(document.RootElement);
        var fromBytes = ControlCodec.Decode(Encoding.UTF8.GetBytes(document.RootElement.GetRawText()));

        Assert.True(ControlCodec.DeepEquals(fromElement, fromBytes));
    }

    [Fact]
    public void DeepEqualsIgnoresKeyOrderAndComparesNestedObjects()
    {
        var a = ControlCodec.Normalize(ControlMessages.StartAck("r", "s"));
        var b = ControlCodec.Decode(ControlCodec.Encode(ControlMessages.StartAck("r", "s")));
        var c = ControlCodec.Decode(ControlCodec.Encode(ControlMessages.StartAck("r", "other")));

        Assert.True(ControlCodec.DeepEquals(a, b));
        Assert.False(ControlCodec.DeepEquals(a, c));
    }
}
