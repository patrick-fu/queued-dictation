#!/usr/bin/env python3
"""Generated PCM -> public recorder -> real HTTP -> SIGKILL -> fresh public reads."""
import argparse
import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import struct
import subprocess
import threading
import time


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def generated_pcm(ordinal=0):
    return b"".join(struct.pack("<H", (i * 13 + ordinal * 137) & 65535) for i in range(4000))


class Server:
    def __init__(self):
        self.requests = []
        self.lock = threading.Lock()
        self.hold_role = None
        self.release = threading.Event()
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                if self.path.endswith("audio/transcriptions"):
                    role, payload = "asr", None
                    start = body.index(b"RIFF")
                    length = struct.unpack("<I", body[start + 4:start + 8])[0] + 8
                    wave = body[start:start + length]
                    require(wave[8:12] == b"WAVE" and wave[44:] == generated_pcm(), "uploaded WAV was incomplete or changed")
                    response = {"text": "I go yesterday."}
                else:
                    payload = json.loads(body)
                    role = "coach" if "coach" in payload["model"] else "polish"
                    content = '{"kind":"card","suggestions":[{"category":"grammar","original":"go","improved":"went","reason":"Use the past tense."}]}' if role == "coach" else "I went yesterday."
                    response = {"choices": [{"message": {"content": content}}]}
                with owner.lock:
                    owner.requests.append({"role": role, "path": self.path, "authorization": self.headers.get("Authorization"),
                                           "body": body, "payload": payload, "waveSHA": hashlib.sha256(wave).hexdigest() if role == "asr" else None})
                if owner.hold_role == role:
                    owner.release.wait(10)
                encoded = json.dumps(response).encode()
                try:
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(encoded)))
                    self.end_headers()
                    self.wfile.write(encoded)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        self.http = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.http.daemon_threads = True
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.http.server_port}/v1"

    def captured(self):
        with self.lock:
            return list(self.requests)

    def wait_role(self, role):
        deadline = time.monotonic() + 5
        while not any(r["role"] == role for r in self.captured()):
            require(time.monotonic() < deadline, f"actual {role} HTTP not received")
            time.sleep(0.002)

    def stop(self):
        self.release.set()
        self.http.shutdown()
        self.http.server_close()
        self.thread.join(2)


class Replay:
    def __init__(self, binary, output):
        self.binary, self.output = binary, output
        self.processes = []
        self.reports = []

    def command(self, mode, root, server, point="none", flavor="old", action="none", key="correct", document="New window: "):
        return [str(self.binary), mode, str(root), server.url, point, flavor, action, key, base64.b64encode(document.encode()).decode()]

    def launch(self, command):
        child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.processes.append(child)
        return child

    def kill_at(self, root, server, mode="seed", point="none", actual_role=None):
        child = self.launch(self.command(mode, root, server, point, document="Before: "))
        if actual_role:
            server.wait_role(actual_role)
            os.kill(child.pid, signal.SIGSTOP)
            marker = {"actualHTTP": actual_role}
        else:
            selector = selectors.DefaultSelector()
            selector.register(child.stdout, selectors.EVENT_READ)
            deadline = time.monotonic() + 8
            marker = None
            while marker is None:
                require(time.monotonic() < deadline, f"child did not reach {point or mode}; rc={child.poll()}")
                ready = selector.select(0.1)
                if ready:
                    line = child.stdout.readline()
                    if not line:
                        raise AssertionError(f"child exited before fault point: {child.stderr.read()}")
                    value = json.loads(line)
                    if "stoppedAt" in value:
                        marker = value
            selector.close()
        waited_pid, status = os.waitpid(child.pid, os.WUNTRACED)
        require(waited_pid == child.pid and os.WIFSTOPPED(status), "child was not truly stopped")
        os.kill(child.pid, signal.SIGKILL)
        child.wait(timeout=3)
        require(child.returncode == -signal.SIGKILL, "child did not die by SIGKILL")
        remainder, error = child.communicate()
        require(not error, f"killed child emitted an error: {error}")
        marker["childExit"] = child.returncode
        if remainder:
            marker["stdoutAfterMarker"] = remainder.strip()
        return marker

    def read(self, root, server, *, mode="read", flavor="old", action="none", key="correct", document="New window: "):
        child = self.launch(self.command(mode, root, server, flavor=flavor, action=action, key=key, document=document))
        out, error = child.communicate(timeout=8)
        require(child.returncode == 0, f"fresh process failed {child.returncode}: {error}")
        require(not error, f"fresh process emitted an error: {error}")
        value = json.loads(out.strip().splitlines()[-1])
        value["processExit"] = child.returncode
        return value

    def record(self, name, marker, before, after=None, server=None):
        requests = server.captured() if server else []
        safe_requests = [{"role": r["role"], "bodySHA": hashlib.sha256(r["body"]).hexdigest(), "waveSHA": r["waveSHA"],
                          "newCredential": r["authorization"] == "Bearer latest-synthetic-key", "model": r["payload"]["model"] if r["payload"] else None} for r in requests]
        self.reports.append({"case": name, "kill": marker, "before": before, "after": after, "http": safe_requests})
        (self.output / "results.json").write_text(json.dumps(self.reports, indent=2) + "\n")
        print(json.dumps({"case": name, "passed": True, "httpCount": len(requests)}, sort_keys=True), flush=True)

    def close(self):
        for process in self.processes:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=3)


def cipher_hashes(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob("*") if p.is_file()}


def assert_paused(value, frames=4000):
    require("readError" not in value and len(value["history"]) == 1, "authenticated history was not recovered")
    entry = value["history"][0]
    require(entry["frameCount"] == frames and entry["sampleRate"] == 8000, "authenticated prefix format/frames changed")
    require(value["capturedTargets"] == 0 and value["document"] == "New window: ", "fresh process captured or wrote a target")
    require(base64.b64decode(value["waves"][0]["pcm"]) == generated_pcm(), "recovered wave differs from the authenticated prefix")
    return entry


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    replay = Replay(args.binary.resolve(), args.output.resolve())
    servers = []

    def fresh(name):
        root = replay.output / name
        root.mkdir()
        server = Server()
        servers.append(server)
        return root, server

    try:
        for point, mode in [("none", "capture-empty"), ("formatCheckpoint", "capture")]:
            root, server = fresh(mode + "-" + point)
            marker = replay.kill_at(root, server, mode=mode, point=point)
            value = replay.read(root, server)
            require(not value["history"] and value["recoveryNotice"], "zero authenticated audio generated history or lost its warning")
            require(not server.captured(), "empty interrupted recording dispatched HTTP")
            replay.record(mode + "-" + point, marker, value, server=server)

        for point in ["audioSaved", "entrySavedBeforeMove"]:
            root, server = fresh(point)
            marker = replay.kill_at(root, server, mode="capture" if point == "audioSaved" else "seed", point=point)
            value = replay.read(root, server)
            entry = assert_paused(value)
            require(entry["id"].upper() == marker["id"].upper() and entry["recordingOrder"] == 1 and entry["interruptedRecording"], "recording identity/order was replaced")
            require(("recordingEndedAt" in entry) == (point == "entrySavedBeforeMove"), "an actual end timestamp was lost or invented")
            require(value["recovery"][0]["canResume"] and not server.captured(), "unsent recovered ASR did not remain paused")
            again = replay.read(root, server)
            require(len(again["history"]) == 1 and again["history"][0]["id"] == entry["id"], "recovery promotion was not idempotent")
            resumed = replay.read(root, server, flavor="latest", action="resume")
            require([r["role"] for r in server.captured()].count("asr") == 1 and len(server.captured()) == 3, "resume duplicated a role or lost downstream work")
            require(all(r["authorization"] == "Bearer latest-synthetic-key" for r in server.captured()), "resumed role used old credentials")
            require(resumed["document"] == "New window: " and resumed["capturedTargets"] == 0, "resumed result targeted the new document")
            replay.record(point, marker, value, resumed, server)

        root, server = fresh("prefix-corruption")
        marker = replay.kill_at(root, server, mode="capture-multi")
        original = replay.output / "prefix-gap"
        shutil.copytree(root, original)
        folder = next((root / "vault" / "active").iterdir())
        corrupt = folder / "00000001.audio"
        bytes_ = bytearray(corrupt.read_bytes()); bytes_[-1] ^= 1; corrupt.write_bytes(bytes_)
        for candidate, name in [(root, "corrupted-suffix"), (original, "missing-middle")]:
            if candidate == original:
                (next((candidate / "vault" / "active").iterdir()) / "00000001.audio").unlink()
            value = replay.read(candidate, server)
            assert_paused(value)
            require(len(value["history"]) == 1 and value["history"][0]["id"].upper() == marker["id"].upper(), "suffix recovery changed identity")
            replay.record(name, marker, value, server=server)

        root, server = fresh("legacy-format")
        marker = replay.kill_at(root, server, mode="capture")
        replay.read(root, server, mode="legacy-format")
        preserved = cipher_hashes(root / "vault")
        value = replay.read(root, server)
        require(not value["history"] and value["recoveryNotice"], "legacy unknown format was guessed")
        audio = [p for p in preserved if p.endswith(".audio")]
        require(all(cipher_hashes(root / "vault")[p] == preserved[p] for p in audio), "unknown-format audio was modified")
        ordered = replay.read(root, server, mode="order")
        require(ordered["history"][0]["recordingOrder"] == 2, "active order did not reserve the next recording floor")
        require(not server.captured(), "legacy audio was automatically sent")
        replay.record("legacy-format-order-floor", marker, value, ordered, server)

        root, server = fresh("raw-atomic-roles")
        marker = replay.kill_at(root, server, point="rawCommittedBeforeMemory")
        value = replay.read(root, server)
        entry = assert_paused(value)
        require(entry["rawTranscription"] == "I go yesterday." and entry["polish"]["status"] == "waitingForSlot" and entry["coach"]["status"] == "waitingForResume", "raw and queued roles were not atomic")
        require(len(server.captured()) == 1, "restart resent a durable raw result")
        resumed = replay.read(root, server, flavor="latest", action="resume")
        requests = server.captured()
        require([r["role"] for r in requests].count("asr") == 1 and len(requests) == 3, "queued roles were lost or raw was re-transcribed")
        require(all(r["authorization"] == "Bearer latest-synthetic-key" and r["payload"]["messages"][1]["content"] == "I go yesterday." for r in requests[1:]), "downstream resume missed latest credentials or raw input")
        require(resumed["history"][0]["polishedText"] == "I went yesterday." and resumed["document"] == "New window: ", "valid polish was lost or replayed")
        replay.record("raw-atomic-roles", marker, value, resumed, server)

        root, server = fresh("manual-polish-queued")
        marker = replay.kill_at(root, server, point="polishQueued")
        value = replay.read(root, server)
        entry = assert_paused(value)
        require(entry["disposition"] == "completed" and value["recovery"][0]["canResume"], "completed main lost its manual polish job")
        resumed = replay.read(root, server, flavor="latest", action="resume")
        require(len(server.captured()) == 2 and [r["role"] for r in server.captured()] == ["asr", "polish"], "manual polish replayed another role")
        require(resumed["history"][0]["disposition"] == "completed" and resumed["document"] == "New window: ", "manual historical polish replayed delivery")
        replay.record("manual-polish-queued", marker, value, resumed, server)

        for role, action in [("asr", "retryASR"), ("polish", "repolish"), ("coach", "retryCoach")]:
            root, server = fresh("actual-inflight-" + role)
            server.hold_role = role
            marker = replay.kill_at(root, server, actual_role=role)
            before_count = len(server.captured())
            server.hold_role = None; server.release.set()
            value = replay.read(root, server, flavor="latest")
            entry = assert_paused(value)
            require(entry["transcription" if role == "asr" else role]["status"] == "interrupted", "unknown actual HTTP was treated as queued")
            require(len(server.captured()) == before_count, "latest configuration automatically retried an unknown HTTP")
            resumed = replay.read(root, server, action="resume", flavor="latest")
            require(len([r for r in server.captured() if r["role"] == role]) == 1, "resume resent an unknown request")
            retried = replay.read(root, server, action=action, flavor="latest")
            require(len([r for r in server.captured() if r["role"] == role]) == 2, "explicit retry did not dispatch exactly one fresh role")
            require(retried["document"] == "New window: " and retried["capturedTargets"] == 0, "explicit retry replayed old delivery")
            replay.record("actual-inflight-" + role, marker, value, retried, server)

        for point in ["polishResultSaved", "coachResultSaved"]:
            root, server = fresh(point)
            marker = replay.kill_at(root, server, point=point)
            value = replay.read(root, server, flavor="latest")
            entry = assert_paused(value)
            field = "polish" if point == "polishResultSaved" else "coach"
            require(entry[field]["status"] == "succeeded", "durable valid role result was changed")
            require(value["cards"] == 0, "old coach result replayed a card")
            role = "polish" if field == "polish" else "coach"
            require(len([r for r in server.captured() if r["role"] == role]) == 1, "valid result was requested again")
            replay.record(point, marker, value, server=server)

        for point in ["deliveryUncertain", "deliveryPerformed", "completed"]:
            root, server = fresh(point)
            marker = replay.kill_at(root, server, point=point)
            value = replay.read(root, server, document=marker["document"])
            require(len(server.captured()) == 1 and value["capturedTargets"] == 0 and value["document"] == marker["document"], "saved result was requested or delivered again")
            if point != "completed":
                require(value["history"][0]["delivery"] == "uncertain" and value["queue"][0]["head"], "uncertain delivery lost FIFO block")
                copied = replay.read(root, server, action="copy", document=marker["document"])
                require(len(copied["queue"]) == 1, "copy released an uncertain head")
                inserted = replay.read(root, server, action="insert", document=marker["document"])
                require(inserted.get("actionError") == "deliveryUncertain" and inserted["document"] == marker["document"], "uncertain text was reinserted")
                confirmed = replay.read(root, server, action="confirm", document=marker["document"])
                require(not confirmed["queue"] and confirmed["document"] == marker["document"], "explicit confirmation replayed text")
            else:
                require(not value["recovery"] and not value["queue"], "completed delivery became pending")
            replay.record(point, marker, value, server=server)

        root, server = fresh("key-preservation")
        marker = replay.kill_at(root, server, mode="capture")
        before = cipher_hashes(root / "vault")
        controls = []
        for key in ["missing", "wrong"]:
            value = replay.read(root, server, key=key)
            require(value["start"] is False and value["keyCreations"] == 0 and "readError" in value, "unavailable key created replacement work")
            require(cipher_hashes(root / "vault") == before, "unavailable key modified ciphertext")
            controls.append(value)
        replay.record("key-preservation", marker, controls, server=server)
        require(all(p.poll() is not None for p in replay.processes), "a child process remained running")
        print(json.dumps({"cases": len(replay.reports), "ownedChildrenRunning": 0, "passed": True}), flush=True)
    finally:
        replay.close()
        for server in servers:
            server.stop()


if __name__ == "__main__":
    main()
