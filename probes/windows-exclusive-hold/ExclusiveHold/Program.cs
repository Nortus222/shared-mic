using NAudio.CoreAudioApi;

// Holds the Samson Meteorite in WASAPI exclusive mode so the agent's
// shared-mode open can be tested against a locked device. While this holds,
// the agent must answer START with START_NACK and MIC_UNAVAILABLE, then
// accept normally once this releases.
//
// Usage: ExclusiveHold [holdSeconds] [endpointId]
// Defaults: 30 seconds on the pinned Meteorite endpoint.
if (args.Length > 0 && args[0] == "list")
{
    var lister = new MMDeviceEnumerator();
    foreach (var dev in lister.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.All))
    {
        Console.WriteLine($"{dev.ID} | {dev.State} | {dev.FriendlyName}");
        dev.Dispose();
    }

    lister.Dispose();
    return 0;
}

if (args.Length > 0 && args[0] == "sessions")
{
    string target = args.Length > 1
        ? args[1]
        : "{0.0.1.00000000}.{dcea823c-c06f-40bf-8f35-9de9fb96acfd}";
    var sessionLister = new MMDeviceEnumerator();
    var sessionDevice = sessionLister.GetDevice(target);
    var manager = sessionDevice.AudioSessionManager;
    Console.WriteLine($"audio sessions on {sessionDevice.FriendlyName}:");
    var sessions = manager.Sessions;
    for (int index = 0; index < sessions.Count; index++)
    {
        var session = sessions[index];
        Console.WriteLine(
            $"  [{index}] state={session.State} id={session.GetSessionIdentifier} icon={session.IconPath}");
    }

    if (sessions.Count == 0)
    {
        Console.WriteLine("  (none)");
    }

    sessionDevice.Dispose();
    sessionLister.Dispose();
    return 0;
}

string endpointId = args.Length > 1
    ? args[1]
    : "{0.0.1.00000000}.{dcea823c-c06f-40bf-8f35-9de9fb96acfd}";
int holdSeconds = args.Length > 0 && int.TryParse(args[0], out int parsed) ? parsed : 30;
long buffer100ns = args.Length > 2 && long.TryParse(args[2], out long parsedMs) ? parsedMs * 10000L : 5000000L;
Console.WriteLine($"requested buffer: {buffer100ns / 10000L} ms");

var enumerator = new MMDeviceEnumerator();
var device = enumerator.GetDevice(endpointId);
var audioClient = device.AudioClient;
var format = audioClient.MixFormat;
Console.WriteLine($"device: {device.FriendlyName}");
Console.WriteLine($"mix format: {format.SampleRate} Hz, {format.BitsPerSample} bit, {format.Channels} ch, {format.Encoding}");

try
{
    audioClient.Initialize(
        AudioClientShareMode.Exclusive,
        AudioClientStreamFlags.None,
        buffer100ns,
        buffer100ns,
        format,
        Guid.Empty);
}
catch (Exception exception)
{
    Console.WriteLine($"EXCLUSIVE OPEN FAILED: {exception.GetType().Name}: {exception.Message}");
    return 2;
}

audioClient.Start();
Console.WriteLine($"EXCLUSIVE HELD for {holdSeconds} s");
Thread.Sleep(TimeSpan.FromSeconds(holdSeconds));
audioClient.Stop();
Console.WriteLine("RELEASED");
audioClient.Dispose();
device.Dispose();
enumerator.Dispose();
return 0;





