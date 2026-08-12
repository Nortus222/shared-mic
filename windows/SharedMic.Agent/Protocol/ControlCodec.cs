using System.Text.Encodings.Web;
using System.Text.Json;

namespace SharedMic.Agent.Protocol;

/// <summary>
/// The CONTROL payload of protocol-v1.md section 5: a single UTF-8 JSON object
/// with no line breaks or padding, keys sorted lexicographically (recursively),
/// and no ASCII escaping of non-ASCII characters. The target is the bytes that
/// json.dumps(msg, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
/// produces in the reference harness, which is what makes two implementations
/// that build the same logical message interoperable byte for byte.
///
/// That target is met for every string this protocol realistically carries, but
/// not universally: JavaScriptEncoder.UnsafeRelaxedJsonEscaping is close to
/// Python's ensure_ascii=False, not identical to it. Measured on .NET 10, the
/// two diverge in exactly two ways. First, .NET escapes as a \u sequence a
/// handful of code points Python emits as raw UTF-8: U+007F (DEL),
/// U+0080-U+009F, U+00A0 (no-break space), U+2028, U+2029, U+FDD0-U+FDEF, and
/// the U+FFFE/U+FFFF noncharacters. Second, for the control characters both
/// sides escape, .NET writes the hex digits in uppercase and Python writes them
/// in lowercase, so U+001F becomes backslash-u-001F here and backslash-u-001f
/// there. Everything else matches, including the characters the default encoder
/// would have escaped: &lt; &gt; &amp; ' + = ` / are all emitted literally, and
/// the quote, backslash, backspace, form feed, newline, carriage return and tab
/// escapes agree.
///
/// The reachable case is U+00A0 inside a Windows MMDevice friendly name
/// reaching deviceLabel. The consequence is bounded: such a payload still
/// decodes to the identical logical message on the far end, and section 6's
/// mac is an HMAC over the raw nonce bytes rather than over canonical JSON, so
/// authentication is unaffected. What would break is the byte-identity claim of
/// section 10: a vector containing one of those code points would not compare
/// equal across the two implementations. No committed vector contains one.
/// Closing the gap needs a custom encoder, which should be a deliberate future
/// decision rather than something done by accident.
///
/// Validation runs on both encode and decode, deliberately: a bug here should
/// surface as a loud local failure rather than as bytes the far end has to
/// guess about.
///
/// Messages are modelled as Dictionary&lt;string, object?&gt; with values
/// restricted to string, bool, long, double and nested dictionaries. That is
/// exactly the value space protocol version 1 uses, and it lets the conformance
/// test iterate the committed vectors generically.
/// </summary>
public static class ControlCodec
{
    public static readonly IReadOnlyDictionary<string, string[]> RequiredFields =
        new Dictionary<string, string[]>(StringComparer.Ordinal)
        {
            ["GREETING"] = new[] { "serverId", "nonce" },
            ["HELLO"] = new[] { "clientId", "mac" },
            ["HELLO_ACK"] = new[] { "serverId", "micPresent", "deviceLabel" },
            ["START"] = new[] { "requestId", "preferredFormat" },
            ["START_ACK"] = new[] { "requestId", "sessionId", "format" },
            ["START_NACK"] = new[] { "requestId", "reason" },
            ["STOP"] = new[] { "requestId", "sessionId" },
            ["STOP_ACK"] = new[] { "requestId", "sessionId" },
            ["STATUS"] = new[] { "micPresent", "active", "deviceLabel" },
            ["PING"] = new[] { "seq" },
            ["PONG"] = new[] { "seq" },
        };

    private static readonly JsonWriterOptions WriterOptions = new()
    {
        Indented = false,
        SkipValidation = false,

        // The default encoder escapes every non-ASCII character as a \u
        // sequence and also escapes characters such as '+' and '&'. The
        // reference encoder uses ensure_ascii=False and escapes only what JSON
        // requires, so the relaxed encoder is what produces matching bytes.
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static byte[] Encode(IReadOnlyDictionary<string, object?> message)
    {
        var normalized = Normalize(message);
        Validate(normalized);

        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, WriterOptions))
        {
            WriteObject(writer, normalized);
        }

        return stream.ToArray();
    }

    public static Dictionary<string, object?> Decode(ReadOnlySpan<byte> payload)
    {
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(payload.ToArray());
        }
        catch (JsonException exception)
        {
            throw new ProtocolException($"malformed JSON control payload: {exception.Message}");
        }

        using (document)
        {
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                throw new ProtocolException("control message must be a JSON object");
            }

            var message = FromJsonElement(document.RootElement);
            Validate(message);
            return message;
        }
    }

    /// <summary>
    /// Widen every integer to long and copy nested dictionaries, so that a
    /// message built with int literals compares and encodes identically to one
    /// decoded off the wire.
    /// </summary>
    public static Dictionary<string, object?> Normalize(IReadOnlyDictionary<string, object?> message)
    {
        var normalized = new Dictionary<string, object?>(StringComparer.Ordinal);
        foreach (var pair in message)
        {
            normalized[pair.Key] = NormalizeValue(pair.Value);
        }

        return normalized;
    }

    public static void Validate(IReadOnlyDictionary<string, object?> message)
    {
        if (!message.TryGetValue("type", out var typeValue) || typeValue is not string type ||
            !RequiredFields.ContainsKey(type))
        {
            throw new ProtocolException($"unknown control type '{typeValue ?? "(missing)"}'");
        }

        if (!message.TryGetValue("v", out var versionValue) || versionValue is not long version ||
            version != ProtocolConstants.ProtocolVersion)
        {
            throw new ProtocolException($"unsupported protocol version '{versionValue ?? "(missing)"}'");
        }

        foreach (var field in RequiredFields[type])
        {
            if (!message.ContainsKey(field))
            {
                throw new ProtocolException($"{type} missing required field '{field}'");
            }
        }
    }

    public static Dictionary<string, object?> FromJsonElement(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            throw new ProtocolException("control message must be a JSON object");
        }

        var message = new Dictionary<string, object?>(StringComparer.Ordinal);
        foreach (var property in element.EnumerateObject())
        {
            message[property.Name] = ValueFromJsonElement(property.Value);
        }

        return message;
    }

    /// <summary>
    /// Field-for-field equality ignoring key order, which is the decode-side
    /// conformance rule of protocol-v1.md section 10.
    /// </summary>
    public static bool DeepEquals(object? left, object? right)
    {
        if (left is IReadOnlyDictionary<string, object?> leftObject &&
            right is IReadOnlyDictionary<string, object?> rightObject)
        {
            if (leftObject.Count != rightObject.Count)
            {
                return false;
            }

            foreach (var pair in leftObject)
            {
                if (!rightObject.TryGetValue(pair.Key, out var other) || !DeepEquals(pair.Value, other))
                {
                    return false;
                }
            }

            return true;
        }

        return Equals(left, right);
    }

    private static object? NormalizeValue(object? value) => value switch
    {
        null => null,
        string text => text,
        bool flag => flag,
        int number => (long)number,
        uint number => (long)number,
        long number => number,
        double number => number,
        IReadOnlyDictionary<string, object?> nested => Normalize(nested),
        _ => throw new ProtocolException($"unsupported control value type {value.GetType().Name}"),
    };

    private static object? ValueFromJsonElement(JsonElement element) => element.ValueKind switch
    {
        JsonValueKind.Object => FromJsonElement(element),
        JsonValueKind.String => element.GetString(),
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        JsonValueKind.Null => null,

        // The cast to object is load bearing: without it both branches of the
        // conditional would unify to double, and every integer on the wire —
        // including "v" — would decode as a double instead of a long.
        JsonValueKind.Number => element.TryGetInt64(out var integer) ? integer : (object)element.GetDouble(),
        _ => throw new ProtocolException($"unsupported JSON value kind {element.ValueKind} in a control message"),
    };

    private static void WriteObject(Utf8JsonWriter writer, IReadOnlyDictionary<string, object?> message)
    {
        // Ordinal, never culture-aware: the reference encoder sorts keys by
        // code point, and a culture-aware collation would order pairs such as
        // "Z" and "a" the other way round.
        writer.WriteStartObject();
        foreach (var key in message.Keys.OrderBy(key => key, StringComparer.Ordinal))
        {
            writer.WritePropertyName(key);
            WriteValue(writer, message[key]);
        }

        writer.WriteEndObject();
    }

    private static void WriteValue(Utf8JsonWriter writer, object? value)
    {
        switch (value)
        {
            case null:
                writer.WriteNullValue();
                break;
            case string text:
                writer.WriteStringValue(text);
                break;
            case bool flag:
                writer.WriteBooleanValue(flag);
                break;
            case long number:
                writer.WriteNumberValue(number);
                break;
            case double number:
                writer.WriteNumberValue(number);
                break;
            case IReadOnlyDictionary<string, object?> nested:
                WriteObject(writer, nested);
                break;
            default:
                throw new ProtocolException($"unsupported control value type {value.GetType().Name}");
        }
    }
}
