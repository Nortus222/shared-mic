namespace SharedMic.Agent.Protocol;

/// <summary>Envelope type byte (protocol-v1.md section 3).</summary>
public enum FrameType : byte
{
    Control = 1,
    Audio = 2,
}
