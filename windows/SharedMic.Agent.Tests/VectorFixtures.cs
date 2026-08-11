using System.Text.Json;

namespace SharedMic.Agent.Tests;

public sealed record ControlVector(string Name, JsonElement Message, string Hex);

public sealed record AudioVector(string Name, uint Sequence, ulong TimestampUs, string PcmHex, string Hex);

/// <summary>
/// Loads the committed golden vectors from protocol/vectors/, which the test
/// project copies next to its own binary. These files are the conformance
/// contract: an implementation that produces different bytes for the same
/// message is wrong, so nothing here may transform or "fix up" what it reads.
/// </summary>
public static class VectorFixtures
{
    private static readonly Lazy<JsonDocument> ControlDocument = new(() => Load("control-messages.json"));
    private static readonly Lazy<JsonDocument> AudioDocument = new(() => Load("audio-frames.json"));

    private static JsonDocument Load(string fileName)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "vectors", fileName);
        if (!File.Exists(path))
        {
            throw new FileNotFoundException(
                $"Golden vector file not found at '{path}'. The test project must copy " +
                "protocol/vectors/*.json into its output directory under 'vectors/'.", path);
        }

        return JsonDocument.Parse(File.ReadAllBytes(path));
    }

    public static IReadOnlyList<ControlVector> ControlVectors()
    {
        var vectors = new List<ControlVector>();
        foreach (var element in ControlDocument.Value.RootElement.EnumerateArray())
        {
            vectors.Add(new ControlVector(
                element.GetProperty("name").GetString()!,
                element.GetProperty("message"),
                element.GetProperty("hex").GetString()!));
        }

        return vectors;
    }

    public static IReadOnlyList<AudioVector> AudioVectors()
    {
        var vectors = new List<AudioVector>();
        foreach (var element in AudioDocument.Value.RootElement.EnumerateArray())
        {
            vectors.Add(new AudioVector(
                element.GetProperty("name").GetString()!,
                element.GetProperty("sequence").GetUInt32(),
                element.GetProperty("timestampUs").GetUInt64(),
                element.GetProperty("pcmHex").GetString()!,
                element.GetProperty("hex").GetString()!));
        }

        return vectors;
    }

    public static ControlVector Control(string name) => ControlVectors().Single(v => v.Name == name);

    public static AudioVector Audio(string name) => AudioVectors().Single(v => v.Name == name);

    public static IEnumerable<object[]> ControlVectorNames() =>
        ControlVectors().Select(v => new object[] { v.Name });

    public static IEnumerable<object[]> AudioVectorNames() =>
        AudioVectors().Select(v => new object[] { v.Name });
}
