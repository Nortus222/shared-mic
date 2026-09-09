namespace SharedMic.Agent.Audio;

public interface ICaptureSink
{
    void OnCaptureFrame(byte[] pcm, uint sequence, ulong timestampUs);
}
