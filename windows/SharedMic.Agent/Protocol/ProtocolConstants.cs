namespace SharedMic.Agent.Protocol;

/// <summary>
/// Every fixed value in protocol/protocol-v1.md, in one place. Changing any of
/// these is a protocol version change (protocol-v1.md section 1), not an
/// implementation decision.
/// </summary>
public static class ProtocolConstants
{
    public const int ProtocolVersion = 1;

    public const int DefaultPort = 47800;

    public const int EnvelopeSize = 5;
    public const int MaxPayloadBytes = 1048576;

    public const int AudioHeaderSize = 12;
    public const int PcmBytesPerFrame = 1920;
    public const int AudioPayloadSize = AudioHeaderSize + PcmBytesPerFrame;
    public const int AudioEnvelopeSize = EnvelopeSize + AudioPayloadSize;

    public const int SampleRate = 48000;
    public const int Channels = 1;
    public const string SampleFormat = "s16le";
    public const int SamplesPerFrame = 960;
    public const int FramesPerSecond = 50;
    public const int FrameDurationMs = 20;
    public const long FrameDurationUs = 20000;

    public const int AudioQueueCapacity = 25;

    public const int TokenBytes = 32;
    public const int NonceBytes = 32;
    public const int MaxAuthFailures = 5;

    public const int CertificateValidityDays = 3650;
    public const string CertificateCommonName = "shared-mic";

    public static readonly TimeSpan HelloDeadline = TimeSpan.FromSeconds(5);
    public static readonly TimeSpan HeartbeatInterval = TimeSpan.FromSeconds(15);
    public static readonly TimeSpan PeerDeadTimeout = TimeSpan.FromSeconds(45);
    public static readonly TimeSpan AuthLockoutDuration = TimeSpan.FromSeconds(30);
    public static readonly TimeSpan CertificateBackdate = TimeSpan.FromMinutes(5);
}
