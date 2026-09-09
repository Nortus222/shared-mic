"""Measure an isolated real Windows agent. Never write audio or credentials."""

import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import queue
import socket
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "harness"))
from sharedmic_protocol.auth import decode_pairing_string
from sharedmic_protocol.client import MockMacClient
from sharedmic_protocol.tls import client_context


class MemoryCounters(ctypes.Structure):
    _fields_ = [("cb", wintypes.DWORD), ("faults", wintypes.DWORD)] + [
        (name, ctypes.c_size_t) for name in
        ("peakWorkingSet", "workingSet", "peakPaged", "paged", "peakNonPaged",
         "nonPaged", "pagefile", "peakPagefile")
    ]


def process_sample(process):
    times = [wintypes.FILETIME() for _ in range(4)]
    handle = wintypes.HANDLE(int(process._handle))
    if not ctypes.windll.kernel32.GetProcessTimes(handle, *(ctypes.byref(t) for t in times)):
        raise ctypes.WinError()
    memory = MemoryCounters()
    memory.cb = ctypes.sizeof(memory)
    if not ctypes.windll.psapi.GetProcessMemoryInfo(handle, ctypes.byref(memory), memory.cb):
        raise ctypes.WinError()
    cpu = sum((t.dwHighDateTime << 32) + t.dwLowDateTime for t in times[2:]) / 1e7
    return cpu, memory.workingSet


def discard_audio(client):
    while True:
        try:
            client._audio_in.get_nowait()
        except queue.Empty:
            return


def phase(client, process, seconds):
    discard_audio(client)
    frames_before = client.audio_frames_received
    gaps_before = client.sequence_gaps
    cpu_before, memory_before = process_sample(process)
    start = time.perf_counter()
    next_ping = start + 5
    while time.perf_counter() - start < seconds:
        discard_audio(client)
        if time.perf_counter() >= next_ping:
            client.ping()
            next_ping += 5
        time.sleep(0.01)
    elapsed = time.perf_counter() - start
    cpu_after, memory_after = process_sample(process)
    frames = client.audio_frames_received - frames_before
    discard_audio(client)
    return dict(seconds=elapsed, audioFrames=frames, pcmBytes=frames * 1920,
                envelopeBytes=frames * 1937, framesPerSecond=frames / elapsed,
                sequenceGaps=client.sequence_gaps - gaps_before,
                cpuSeconds=cpu_after - cpu_before,
                cpuPercentOneCore=(cpu_after - cpu_before) / elapsed * 100,
                cpuPercentMachine=(cpu_after - cpu_before) / elapsed * 100 / os.cpu_count(),
                workingSetBeforeBytes=memory_before, workingSetAfterBytes=memory_after)


def main():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    # Only this disposable identity is created. Existing agent settings are untouched.
    with tempfile.TemporaryDirectory(prefix="sharedmic-performance-") as identity:
        executable = ROOT / "windows/SharedMic.Agent/bin/Release/net10.0-windows/SharedMic.Agent.exe"
        process = subprocess.Popen(
            [str(executable), "--headless", "--loopback-only", "--port", str(port),
             "--data-dir", identity], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, creationflags=subprocess.CREATE_NO_WINDOW)
        banner = queue.Queue()

        def read_output():
            for line in process.stdout:
                # Read credentials in memory; discard all remaining agent output.
                for field in ("fingerprint:", "pairing string:"):
                    if field in line:
                        banner.put((field, line.split(field, 1)[1].strip()))

        threading.Thread(target=read_output, daemon=True).start()
        client = None
        try:
            fields = dict(banner.get(timeout=15) for _ in range(2))
            time.sleep(1)
            client = MockMacClient(decode_pairing_string(fields["pairing string:"]),
                                   "127.0.0.1", port, ssl_context=client_context(),
                                   expected_fingerprint=fields["fingerprint:"])
            hello = client.connect()
            if not hello["micPresent"]:
                raise RuntimeError("Pinned microphone is absent.")
            print("Measuring 15 seconds idle...", flush=True)
            idle = phase(client, process, 15)
            activation = []
            print("Measuring 20 START-to-first-received-frame cycles...", flush=True)
            for _ in range(20):
                discard_audio(client)
                start = time.perf_counter()
                client.start_session()
                client.wait_for_audio_frames(1, timeout=5)
                activation.append((time.perf_counter() - start) * 1000)
                client.stop_session()
                time.sleep(0.25)
                discard_audio(client)
            client.start_session()
            client.wait_for_audio_frames(1, timeout=5)
            print("Measuring 30 seconds active...", flush=True)
            active = phase(client, process, 30)
            client.stop_session()
            time.sleep(0.5)  # exclude in-flight teardown from the settled-idle interval
            print("Measuring 15 seconds after STOP...", flush=True)
            stopped = phase(client, process, 15)
            result = dict(device=hello.get("deviceLabel", "Pinned Samson Meteorite Mic"),
                          activationMs=activation, idle=idle, active=active, stopped=stopped,
                          cpuMethod="GetProcessTimes delta; machine percentage divides by logical processors",
                          memoryMethod="GetProcessMemoryInfo working set at phase boundaries; not peak or leak test",
                          transport="TLS over 127.0.0.1; real Windows capture; Python receiver; no Mac rendering",
                          heartbeat="PING every 5 seconds during each phase; not the product 15-second cadence")
            Path(sys.argv[1]).write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
            if idle["audioFrames"] or stopped["audioFrames"] or not active["audioFrames"]:
                raise RuntimeError("Idle/active audio counter check failed; see result JSON.")
        finally:
            if client is not None:
                client.close()
            process.terminate()
            process.wait(timeout=10)
            process.stdout.close()


if __name__ == "__main__":
    main()
