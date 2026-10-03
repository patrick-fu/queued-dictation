#!/usr/bin/env python3
"""本机原生验收控制；不启动 App、设备或生成按键。仅使用 Python 标准库。"""
import argparse
import base64
import ctypes
from email.parser import BytesParser
from email import policy
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import plistlib
import re
import select
import shutil
import signal
import socketserver
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from urllib.parse import urlparse
import uuid
import wave

SCHEMA = 1
MODELS = {"asr": "qd-native-asr", "polish": "qd-native-polish", "coach": "qd-native-coach"}
SLOTS = ("H1", "H2", "H3", "P1", "P2", "A", "B")
FAKE_KEY = "native-acceptance-fake-key"
LABEL = re.compile(r"Native pair ([0-9]+) (H[123]|P[12]|A|B)\.")
BODY_LIMIT = 160 * 1024 * 1024


class NativeError(Exception):
    pass


def digest(data):
    return hashlib.sha256(data).hexdigest()


def identifier(value):
    try:
        return str(uuid.UUID(str(value)))
    except (ValueError, TypeError, AttributeError):
        raise NativeError("invalid UUID")


def integer(value, name, minimum=0):
    if type(value) is not int or value < minimum:
        raise NativeError("invalid integer: " + name)
    return value


def owned_path(root, name):
    path = (root / name).resolve()
    try:
        path.relative_to(root.resolve())
    except ValueError:
        raise NativeError("evidence path escapes owned root")
    return path


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_name(path.name + "." + str(uuid.uuid4()) + ".tmp")
    with temporary.open("x", encoding="utf-8") as handle:
        os.chmod(temporary, 0o600)
        json.dump(value, handle, ensure_ascii=False, allow_nan=False, indent=2)
        handle.write("\n")
    os.replace(temporary, path)


def prepare_root(value):
    root = Path(value).expanduser().resolve()
    if root == Path(root.anchor) or not Path(value).is_absolute():
        raise NativeError("owned root must be an explicit absolute non-root directory")
    marker = root / "native-owned.json"
    if marker.exists():
        data = json.loads(marker.read_text())
        identifier(data["run_id"])
        if data.get("schema_version") != SCHEMA or data.get("uid") != os.getuid():
            raise NativeError("owned-root marker mismatch")
    else:
        if root.exists() and any(root.iterdir()):
            raise NativeError("refuse unowned nonempty output directory")
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        data = {"schema_version": SCHEMA, "run_id": str(uuid.uuid4()), "uid": os.getuid()}
        write_json(marker, data)
    return root, data["run_id"]


_mach_state = None

def mach_clock():
    global _mach_state
    if _mach_state is None:
        class Timebase(ctypes.Structure):
            _fields_=[("numer",ctypes.c_uint32),("denom",ctypes.c_uint32)]
        library=ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        library.mach_absolute_time.restype=ctypes.c_uint64
        info=Timebase()
        if library.mach_timebase_info(ctypes.byref(info))!=0 or not info.denom:
            raise NativeError("mach timebase unavailable")
        _mach_state=(library,int(info.numer),int(info.denom))
    library,numer,denom=_mach_state
    ticks=int(library.mach_absolute_time())
    return ticks,numer,denom


def monotonic_ns():
    if sys.platform=="darwin":
        ticks,numer,denom=mach_clock()
        return ticks*numer//denom
    return time.monotonic_ns()


def clock_probe():
    before=monotonic_ns(); python_before=time.monotonic_ns()
    if sys.platform=="darwin":
        ticks,numer,denom=mach_clock();basis="mach_absolute_time";selection="direct_mach"
    else:
        ticks,numer,denom=time.monotonic_ns(),1,1;basis="non_mach_fixture_only";selection="fixture_only"
    python_after=time.monotonic_ns();after=monotonic_ns();converted=ticks*numer//denom
    return {"python_implementation":time.get_clock_info("monotonic").implementation,"platform":sys.platform,
            "clock_selection":selection,"clock_basis":basis,"clock_ticks":ticks,"timebase_numer":numer,"timebase_denom":denom,
            "clock_before_ns":before,"clock_after_ns":after,"converted_ns":converted,"valid":before<=converted<=after,
            "python_raw_before_ns":python_before,"python_raw_after_ns":python_after,
            "python_same_epoch":before<=python_before<=python_after<=after}


def wav_details(data):
    try:
        with wave.open(io.BytesIO(data), "rb") as reader:
            if reader.getnchannels() != 1 or reader.getsampwidth() != 2 or reader.getcomptype() != "NONE":
                raise NativeError("WAV must be mono PCM16")
            rate, frames = reader.getframerate(), reader.getnframes()
            pcm = reader.readframes(frames)
            if not 8000 <= rate <= 192000 or not frames or len(pcm) != frames * 2:
                raise NativeError("invalid WAV rate/frame data")
    except (wave.Error, EOFError) as error:
        raise NativeError("invalid WAV: " + str(error))
    return {"frame_count": frames, "rate": rate, "pcm_sha256": digest(pcm), "wav_sha256": digest(data)}, pcm


def multipart_wave(content_type, body):
    if not content_type.lower().startswith("multipart/form-data;"):
        raise NativeError("ASR requires multipart/form-data")
    message = BytesParser(policy=policy.default).parsebytes(
        ("Content-Type: " + content_type + "\r\nMIME-Version: 1.0\r\n\r\n").encode() + body)
    if not message.is_multipart() or message.defects:
        raise NativeError("invalid multipart boundary")
    values = {}
    for part in message.iter_parts():
        name = part.get_param("name", header="content-disposition")
        if name not in ("file", "model") or name in values:
            raise NativeError("unexpected/duplicate multipart field")
        values[name] = (part.get_payload(decode=True), part.get_filename())
    if set(values) != {"file", "model"} or values["file"][1] != "segment.wav":
        raise NativeError("expected model and segment.wav; filename is never identity")
    if values["model"][0].decode("utf-8") != MODELS["asr"]:
        raise NativeError("unexpected ASR model")
    return values["file"][0]


def user_content(body):
    try:
        data = json.loads(body)
        if data.get("stream", False) is not False or not isinstance(data.get("messages"), list):
            raise NativeError("expected nonstreaming chat messages")
        users = [m["content"] for m in data["messages"] if m.get("role") == "user"]
        if len(users) != 1:
            raise NativeError("expected one user message")
        content, audio = users[0], None
        if isinstance(content, str):
            text = content
        elif isinstance(content, list):
            texts = [item["text"] for item in content if item.get("type") == "text"]
            audios = [item["input_audio"] for item in content if item.get("type") == "input_audio"]
            if len(texts) != 1 or len(audios) != 1 or len(content) != 2 or audios[0].get("format") != "wav":
                raise NativeError("unexpected audio chat content")
            text, audio = texts[0], base64.b64decode(audios[0]["data"], validate=True)
        else:
            raise NativeError("invalid user content")
        matches = LABEL.findall(text)
        if len(matches) != 1:
            raise NativeError("chat input must contain exactly one control-issued label")
        return data["model"], int(matches[0][0]), matches[0][1], audio
    except (KeyError, ValueError, TypeError) as error:
        raise NativeError("invalid chat body: " + str(error))


class Controller:
    def __init__(self, root, run_id, pairs, origin, audio_mode):
        self.root, self.run_id, self.pairs = root, run_id, pairs
        self.origin, self.audio_mode = origin, audio_mode
        self.condition = threading.Condition(threading.RLock())
        self.log_lock, self.sequence = threading.Lock(), 0
        self.requests, self.captures, self.recordings, self.hotkeys = {}, {}, {}, []
        self.pair_states, self.failures, self.stopping = {}, [], False
        self.log = (root / "native-http.jsonl").open("x", encoding="utf-8")
        os.chmod(root / "native-http.jsonl", 0o600)
        self.emit("boot", clock_probe=clock_probe(), evidence_origin=origin)

    def emit(self, event, **fields):
        with self.log_lock:
            self.sequence += 1
            value = dict(schema_version=SCHEMA, run_id=self.run_id, event=event,
                         sequence=self.sequence, pid=os.getpid(), monotonic_ns=monotonic_ns())
            value.update(fields)
            self.log.write(json.dumps(value, ensure_ascii=False, allow_nan=False) + "\n")
            self.log.flush()
            return value

    def fail(self, reason):
        with self.condition:
            if reason not in self.failures:
                self.failures.append(reason)
                self.emit("control_failure", reason=reason)
            self.condition.notify_all()

    def pair(self, index):
        return self.pair_states.setdefault(index, {"cue_ns": None, "first_pcm_ns": None,
                                                 "rest_released": False, "drained": False})

    def ingest(self, lane, item):
        if item.get("schema_version") != SCHEMA or item.get("run_id") != self.run_id:
            raise NativeError("observer schema/run mismatch")
        with self.condition:
            event = item.get("event")
            if event == "trace_failure":
                self.fail("observer trace_failure: " + str(item.get("reason")))
            if lane == "core":
                if event == "hotkey":
                    self.hotkeys.append(item)
                elif event == "capture_start":
                    key = identifier(item["capture_id"])
                    if key in self.captures:
                        raise NativeError("duplicate capture_start")
                    candidates = [h for h in self.hotkeys if h.get("accepted") is True and h.get("is_repeat") is False and h.get("edge") == "down"]
                    self.captures[key] = {"start": item, "trigger": candidates[-1] if candidates else None}
                elif event == "capture_finished":
                    key = identifier(item["capture_id"])
                    if key not in self.captures or "finished" in self.captures[key]:
                        raise NativeError("missing start/duplicate capture_finished")
                    self.captures[key]["finished"] = item
                    if item.get("trace_failed") is not False:
                        self.fail("capture trace_failed")
                    duplicates = [x for x in self.captures.values() if x.get("finished", {}).get("pcm_sha256") == item.get("pcm_sha256")]
                    if len(duplicates) != 1:
                        self.fail("ambiguous duplicate captured PCM digest")
                elif event == "pcm" and item.get("yield_result") == "enqueued" and item.get("frames", 0) > 0:
                    key = identifier(item["capture_id"])
                    capture = self.captures.get(key)
                    if not capture:
                        raise NativeError("PCM without capture_start")
                    if "first_pcm" not in capture:
                        capture["first_pcm"] = item
                        index = integer(capture["start"]["capture_index"], "capture_index", 1)
                        pair_index, position = divmod(index - 1, 7)
                        if position == 6:
                            state = self.pair(pair_index + 1)
                            trigger = capture.get("trigger")
                            if state["cue_ns"] is None or not trigger or trigger.get("os_ns", 0) < state["cue_ns"]:
                                self.fail("B physical trigger precedes actual 3/3 cue")
                            state["first_pcm_ns"] = item["monotonic_ns"]
                            self.emit("release", pair_index=pair_index+1, reason="first_pcm", capture_id=key,
                                      pcm_sequence=item["sequence"], first_pcm_ns=item["monotonic_ns"])
            elif lane == "app" and event == "recording_start":
                index = integer(item["recording_index"], "recording_index", 1)
                if index in self.recordings:
                    raise NativeError("duplicate recording_index")
                self.recordings[index] = identifier(item["history_id"])
            self.condition.notify_all()

    def map_audio(self, details):
        end = time.monotonic() + 2.0
        with self.condition:
            while True:
                matches = [x for x in self.captures.values() if x.get("finished", {}).get("pcm_sha256") == details["pcm_sha256"]]
                if len(matches) > 1:
                    raise NativeError("ambiguous PCM digest mapping")
                if len(matches) == 1:
                    capture = matches[0]; finished = capture["finished"]
                    index = integer(finished["capture_index"], "capture_index", 1)
                    if index in self.recordings:
                        if finished["enqueued_frames"] != details["frame_count"] or capture["start"]["rate"] != details["rate"]:
                            raise NativeError("WAV/capture frames or rate mismatch")
                        pcm_path = owned_path(self.root, finished["pcm_path"])
                        if digest(pcm_path.read_bytes()) != details["pcm_sha256"]:
                            raise NativeError("captured PCM file digest mismatch")
                        pair_index, position = divmod(index - 1, 7)
                        if pair_index + 1 > self.pairs:
                            raise NativeError("capture exceeds declared pair count")
                        return identifier(finished["capture_id"]), index, self.recordings[index], pair_index+1, SLOTS[position]
                if self.failures or self.stopping or time.monotonic() >= end:
                    raise NativeError("bounded capture_finished/app mapping wait failed")
                self.condition.wait(min(0.05, max(0, end-time.monotonic())))

    def register(self, record):
        with self.condition:
            if any(r.get("pair_index") == record["pair_index"] and r.get("slot") == record["slot"] and r["role"] == record["role"] for r in self.requests.values()):
                raise NativeError("duplicate role request; no automatic retry allowed")
            self.requests[record["request_id"]] = record
            self.emit("request_mapped", **{k: record[k] for k in ("request_id", "capture_id", "capture_index", "history_id", "pair_index", "slot", "label")})
            self.maybe_cue(record["pair_index"])
            self.condition.notify_all()

    def outstanding(self, role, pair_index):
        return [r for r in self.requests.values() if r["pair_index"] == pair_index and
                (r["role"] == "coach" if role == "coach" else r["role"] in ("asr", "polish")) and
                not r.get("response_begin_ns") and not r.get("disconnected")]

    def maybe_cue(self, pair_index):
        state = self.pair(pair_index)
        main, coach = self.outstanding("main", pair_index), self.outstanding("coach", pair_index)
        if len(main) > 3 or len(coach) > 3:
            self.fail("actual outstanding HTTP exceeds default pool3")
        if state["cue_ns"] is None and {r["slot"] for r in main} == {"P1", "P2", "A"} and {r["slot"] for r in coach} == {"H1", "H2", "H3"} and len(main) == len(coach) == 3:
            event = self.emit("pair_cue", pair_index=pair_index, main_request_ids=[r["request_id"] for r in main], coach_request_ids=[r["request_id"] for r in coach])
            state["cue_ns"] = event["monotonic_ns"]
            print("实际3＋3已收到完整body；现在用实体快捷键录 B：pair %d" % pair_index, flush=True)

    def allowed(self, record):
        state = self.pair(record["pair_index"])
        if record["role"] == "asr" and record["slot"] in ("P1", "P2", "A"):
            return bool(state["first_pcm_ns"]) if record["slot"] == "P1" else state["rest_released"]
        if record["role"] == "coach" and record["slot"] in ("H1", "H2", "H3"):
            return state["rest_released"]
        if record["slot"] == "B":
            return bool(state["first_pcm_ns"])
        return True

    def wait_response(self, record, connection):
        deadline = record["headers_received_ns"] + (60 if record["role"] == "asr" else 30) * 1000000000
        with self.condition:
            while not self.allowed(record) and not self.stopping and not self.failures:
                if monotonic_ns() >= deadline:
                    self.fail("default deadline expired: " + record["request_id"])
                    break
                if select.select([connection], [], [], 0)[0]:
                    try:
                        if connection.recv(1, __import__("socket").MSG_PEEK) == b"":
                            record["disconnected"] = True
                            self.emit("disconnected", request_id=record["request_id"], phase="held", reason="peer closed")
                            self.fail("held request cancelled/disconnected")
                            return None
                    except OSError:
                        record["disconnected"] = True
                        self.emit("disconnected", request_id=record["request_id"], phase="held", reason="peer reset")
                        self.fail("held request cancelled/disconnected")
                        return None
                self.condition.wait(0.025)
            return 503 if self.stopping or self.failures else 200

    def response_finished(self, record):
        with self.condition:
            pair_index = record["pair_index"]
            records = [r for r in self.requests.values() if r["pair_index"] == pair_index]
            if record["slot"] == "B" and record["role"] == "polish" and record.get("status") == 200:
                self.emit("awaiting_b_queue_proof", pair_index=pair_index, history_id=record["history_id"], stage="waitingForPredecessor")
                print("B HTTP已完成；首PCM后观察现有队列，提供 B waitingForPredecessor 证据再 release-rest。", flush=True)
            if len(records) == 21 and all(r.get("response_end_ns") and r.get("status") == 200 for r in records):
                self.pair(pair_index)["drained"] = True
                self.emit("pair_drained", pair_index=pair_index)
            self.condition.notify_all()

    def release_rest(self, proof):
        with self.condition:
            pair_index = integer(proof["pair_index"], "pair_index", 1)
            state = self.pair(pair_index)
            if proof.get("run_id") != self.run_id or proof.get("schema_version") != SCHEMA or proof.get("stage") != "waitingForPredecessor" or proof.get("source") not in ("human", "cua"):
                raise NativeError("invalid explicit operator queue proof")
            history_id = identifier(proof["history_id"])
            b = [r for r in self.requests.values() if r["pair_index"] == pair_index and r["slot"] == "B" and r["role"] == "polish"]
            begin, end = integer(proof["observation_started_ns"], "observation_started_ns", 1), integer(proof["observation_finished_ns"], "observation_finished_ns", 1)
            if not state["first_pcm_ns"] or state["rest_released"] or len(b) != 1 or not b[0].get("response_end_ns") or b[0]["history_id"] != history_id:
                raise NativeError("B not ready for explicit release-rest")
            if not state["first_pcm_ns"] <= begin <= end <= monotonic_ns() or begin < b[0]["response_end_ns"]:
                raise NativeError("queue observation clock interval invalid")
            held = [r for r in self.outstanding("main", pair_index) if r["slot"] in ("P2", "A")]
            if {r["slot"] for r in held} != {"P2", "A"}:
                raise NativeError("P2/A not actually held during queue proof")
            artifact = owned_path(self.root, proof["artifact_path"])
            if not artifact.is_file() or digest(artifact.read_bytes()) != proof["artifact_sha256"]:
                raise NativeError("queue proof artifact missing/digest mismatch")
            self.emit("release", pair_index=pair_index, reason="operator_b_ready", proof=proof)
            state["rest_released"] = True
            self.condition.notify_all()

    def snapshot(self):
        with self.condition:
            return {"clock_ns":monotonic_ns(),"clock_basis":"mach_absolute_time" if sys.platform=="darwin" else "fixture_only", "run_id": self.run_id, "failures": self.failures[:], "pairs": self.pair_states,
                    "requests": [dict(r) for r in self.requests.values()]}


def watch_observers(controller):
    positions, pending = {"core": 0, "app": 0}, {"core": b"", "app": b""}
    while not controller.stopping:
        for lane in ("core", "app"):
            path = controller.root / ("native-" + lane + ".jsonl")
            if not path.exists():
                continue
            try:
                with path.open("rb") as handle:
                    handle.seek(positions[lane]); block = handle.read(); positions[lane] = handle.tell()
                pending[lane] += block
                while b"\n" in pending[lane]:
                    line, pending[lane] = pending[lane].split(b"\n", 1)
                    if line:
                        controller.ingest(lane, json.loads(line))
            except (OSError, ValueError, KeyError, NativeError) as error:
                controller.fail("observer read: " + str(error))
        with controller.condition:
            controller.condition.wait(0.025)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, status, value, record=None):
        body = json.dumps(value, ensure_ascii=False, allow_nan=False).encode()
        state = self.server.controller
        try:
            if record:
                path = "http/responses/" + record["request_id"] + ".json"
                owned_path(state.root, path).parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                owned_path(state.root, path).write_bytes(body)
                record.update(response_begin_ns=monotonic_ns(), status=status)
                state.emit("response_begin", request_id=record["request_id"], status=status, response_path=path,
                           response_sha256=digest(body), response_bytes=len(body))
            self.send_response(status); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body))); self.send_header("Connection", "close"); self.close_connection = True; self.end_headers()
            self.wfile.write(body); self.wfile.flush()
            if record:
                record["response_end_ns"] = monotonic_ns()
                state.emit("response_end", request_id=record["request_id"], status=status,
                           response_end_ns=record["response_end_ns"])
                state.response_finished(record)
        except (BrokenPipeError, ConnectionResetError, OSError) as error:
            if record:
                record["disconnected"] = True
                state.emit("disconnected", request_id=record["request_id"], phase="response", reason=type(error).__name__)
                state.fail("response cancelled/disconnected")

    def do_GET(self):
        if self.path != "/control/status" or self.headers.get("X-Native-Control") != self.server.admin_token:
            self.reply(403, {"error": "owned control authorization required"}); return
        self.reply(200, self.server.controller.snapshot())

    def do_POST(self):
        state, record = self.server.controller, None
        try:
            received = monotonic_ns()
            length = int(self.headers.get("Content-Length", "-1"))
            if not 0 <= length <= BODY_LIMIT or self.headers.get("Transfer-Encoding"):
                raise NativeError("bounded explicit Content-Length required")
            self.connection.settimeout(60)
            body = self.rfile.read(length)
            if len(body) != length:
                raise NativeError("incomplete request body")
            complete = monotonic_ns()
            if self.path.startswith("/control/"):
                if self.headers.get("X-Native-Control") != self.server.admin_token:
                    self.reply(403, {"error": "owned control authorization required"}); return
                command = json.loads(body)
                state.emit("control_command",path=self.path,command=command)
                if self.path == "/control/release-rest":
                    state.release_rest(command); self.reply(200, {"released": True})
                elif self.path == "/control/stop":
                    state.stopping = True
                    with state.condition: state.condition.notify_all()
                    self.reply(200, {"stopped": True})
                    threading.Thread(target=self.server.shutdown, daemon=True).start()
                else:
                    self.reply(404, {"error": "unknown owned command"})
                return
            if self.headers.get("Authorization") != "Bearer " + FAKE_KEY:
                raise NativeError("only explicit fake service key accepted")
            request_id = str(uuid.uuid4())
            body_path = "http/requests/" + request_id + ".body"
            owned_path(state.root, body_path).parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            owned_path(state.root, body_path).write_bytes(body)
            record = {"request_id": request_id, "headers_received_ns": received, "body_complete_ns": complete,
                      "path": self.path, "content_type": self.headers.get("Content-Type", ""), "body_path": body_path,
                      "body_sha256": digest(body), "body_bytes": len(body), "role": "unknown", "model": "unknown"}
            state.emit("request_received", **record)
            audio = None
            if self.path == "/v1/audio/transcriptions":
                audio = multipart_wave(record["content_type"], body)
                details, _ = wav_details(audio)
                role = "asr"
                mapping = state.map_audio(details)
            elif self.path == "/v1/chat/completions":
                model, pair_index, slot, audio = user_content(body)
                role = next((key for key in ("polish", "coach") if MODELS[key] == model), None)
                if not role or (role == "polish" and audio is not None) or (role == "coach" and (audio is not None) != (state.audio_mode == "originalAudio")):
                    raise NativeError("unexpected chat role/input mode")
                with state.condition:
                    matches = [r for r in state.requests.values() if r.get("pair_index") == pair_index and r.get("slot") == slot and r["role"] == "asr" and r.get("status") == 200]
                if len(matches) != 1:
                    raise NativeError("chat label has no unique actual ASR mapping")
                previous = matches[0]
                mapping = tuple(previous[key] for key in ("capture_id", "capture_index", "history_id", "pair_index", "slot"))
                if audio is not None:
                    details, _ = wav_details(audio)
                    if details["pcm_sha256"] != previous["pcm_sha256"]:
                        raise NativeError("Coach WAV differs from actual ASR PCM")
            else:
                raise NativeError("unknown model endpoint")
            record.update(role=role, model=MODELS[role])
            if audio is not None:
                record.update(details)
                wave_path = "http/requests/" + request_id + ".wav"
                owned_path(state.root, wave_path).write_bytes(audio); record["wav_path"] = wave_path
            state.emit("request_parsed", **record)
            record.update(zip(("capture_id", "capture_index", "history_id", "pair_index", "slot"), mapping))
            record["label"] = "Native pair %02d %s." % (record["pair_index"], record["slot"])
            state.register(record)
            status = state.wait_response(record, self.connection)
            if status is None: return
            if status != 200:
                self.reply(status, {"error": "native control failure/stop; no retry"}, record)
            elif role == "asr":
                self.reply(200, {"text": record["label"]}, record)
            else:
                text = record["label"] if role == "polish" else '{"kind":"no_card"}'
                self.reply(200, {"choices": [{"message": {"role": "assistant", "content": text}}]}, record)
        except (NativeError, ValueError, KeyError, OSError) as error:
            state.fail("request invalid: " + str(error))
            self.reply(400, {"error": str(error)}, record)


def serve(args):
    if not args.fixture and args.pairs < 30:
        raise NativeError("actual native run requires at least30 pairs")
    root, run_id = prepare_root(args.root)
    if (root / "native-ready.json").exists() or (root / "native-http.jsonl").exists():
        raise NativeError("refuse existing server evidence; use a new owned run")
    def startup(stage, **fields):
        write_json(root/"native-server-startup.json",dict(schema_version=SCHEMA,run_id=run_id,pid=os.getpid(),stage=stage,monotonic_ns=monotonic_ns(),**fields))
    startup("root_prepared")
    origin = "synthetic_contract_fixture" if args.fixture else "native_physical"
    state = Controller(root, run_id, args.pairs, origin, args.coach_input_mode)
    startup("controller_ready")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler, bind_and_activate=False)
    try:
        startup("binding")
        # Fixed loopback needs no reverse DNS; HTTPServer.server_bind calls getfqdn synchronously.
        socketserver.TCPServer.server_bind(server)
        server.server_name, server.server_port = "localhost", server.server_address[1]
        startup("bound",port=server.server_port)
        server.server_activate()
    except BaseException:
        server.server_close(); state.log.close()
        raise
    server.daemon_threads = False
    server.controller, server.admin_token = state, str(uuid.uuid4())
    ready = {"schema_version": SCHEMA, "run_id": run_id, "base_url": "http://localhost:%d/v1" % server.server_port,
             "asr_model": MODELS["asr"], "polish_model": MODELS["polish"], "coach_model": MODELS["coach"],
             "coach_input_mode": args.coach_input_mode, "pairs": args.pairs, "evidence_origin": origin, "fake_service_key": FAKE_KEY}
    write_json(root / "native-control.json", {"schema_version": SCHEMA, "run_id": run_id, "pid": os.getpid(),
               "admin_token": server.admin_token, "port": server.server_port})
    write_json(root / "native-ready.json", ready)
    watcher = threading.Thread(target=watch_observers, args=(state,), name="native-observer", daemon=False)
    watcher.start()
    print(json.dumps({"ready": str(root/"native-ready.json"), "pid": os.getpid(), "port": server.server_port,
                      "native_samples": 0, "evidence_origin": origin}), flush=True)
    def interrupted(_signum, _frame):
        state.stopping = True
        with state.condition: state.condition.notify_all()
        threading.Thread(target=server.shutdown, daemon=True).start()
    signal.signal(signal.SIGINT, interrupted); signal.signal(signal.SIGTERM, interrupted)
    try:
        startup("ready",port=server.server_port)
        server.serve_forever(poll_interval=0.05)
    finally:
        state.stopping = True
        with state.condition: state.condition.notify_all()
        server.server_close(); watcher.join(timeout=3)
        state.emit("server_closed", clock_probe=clock_probe(), failures=state.failures, port=server.server_port)
        state.log.close()
        startup("closed",port=server.server_port)
    return 1 if state.failures else 0


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def admin(root, command="status", value=None):
    ready = json.loads((root/"native-ready.json").read_text())
    ownership = json.loads((root/"native-control.json").read_text())
    endpoint = urlparse(ready["base_url"])
    if endpoint.scheme != "http" or endpoint.hostname != "localhost" or endpoint.path != "/v1" or endpoint.username or endpoint.query or endpoint.fragment or endpoint.port != ownership["port"] or ready["run_id"] != ownership["run_id"]:
        raise NativeError("owned localhost origin/run mismatch")
    request = urllib.request.Request("http://localhost:%d/control/%s" % (endpoint.port, command),
              data=None if value is None else json.dumps(value).encode(), headers={"X-Native-Control": ownership["admin_token"]})
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=5) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise NativeError("owned control refused: " + error.read().decode())


def checkpoint(args):
    root = Path(args.root).resolve(); snapshot = admin(root)
    pair_index = args.pair
    if snapshot["failures"] or not snapshot["pairs"].get(str(pair_index), {}).get("drained"):
        raise NativeError("pair not actually HTTP drained")
    request = {"schema_version": SCHEMA, "run_id": snapshot["run_id"], "checkpoint_id": str(uuid.uuid4())}
    path = root / "commands/checkpoint.json"
    if path.exists():
        previous = json.loads(path.read_text())
        if not owned_path(root, "checkpoints/" + identifier(previous["checkpoint_id"]) + ".json").exists():
            raise NativeError("previous checkpoint request unresolved; no overwrite/retry")
    write_json(path, request)
    end = time.monotonic()+args.wait_seconds
    target = root/"checkpoints"/(request["checkpoint_id"]+".json")
    while not target.exists() and time.monotonic() < end:
        time.sleep(0.025)
    if not target.exists():
        raise NativeError("checkpoint response missing; request retained")
    result = json.loads(target.read_text())
    if result.get("run_id") != request["run_id"] or result.get("checkpoint_id") != request["checkpoint_id"]:
        raise NativeError("checkpoint response identity mismatch")
    index_path = root / "native-checkpoint-index.json"
    items = json.loads(index_path.read_text()) if index_path.exists() else []
    if any(item["pair_index"] == pair_index for item in items):
        raise NativeError("duplicate pair checkpoint")
    items.append({"pair_index": pair_index, "checkpoint_id": request["checkpoint_id"], "path": str(target.relative_to(root)), "sha256": digest(target.read_bytes())})
    write_json(index_path, items)
    with (root/"native-checkpoint-requests.jsonl").open("a", encoding="utf-8") as journal:
        journal.write(json.dumps(dict(schema_version=SCHEMA, run_id=snapshot["run_id"], event="checkpoint_requested", monotonic_ns=monotonic_ns(), **items[-1]))+"\n")
    print(json.dumps(items[-1]))
    return 0


def source_manifest(repo):
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
    if subprocess.check_output(["git", "status", "--porcelain=v1"], cwd=repo):
        raise NativeError("packaging source must be committed and clean")
    paths = subprocess.check_output(["git", "ls-files", "-z"], cwd=repo).decode().split("\0")
    files = {name: digest((repo/name).read_bytes()) for name in paths if name}
    return {"source_sha": head, "files": files, "sha256": digest(json.dumps(files, sort_keys=True).encode())}


def build_command(repo, root):
    return ["swift", "build", "-c", "release", "--arch", "arm64", "--jobs", "2", "--scratch-path", str(root/"build"), "-Xswiftc", "-DNATIVE_ACCEPTANCE"]


def run_logged(argv, cwd, root, name):
    started = monotonic_ns()
    with (root/(name+".log")).open("xb") as handle:
        process = subprocess.run(argv, cwd=cwd, stdout=handle, stderr=subprocess.STDOUT)
    result = {"argv": argv, "cwd": str(cwd), "started_ns": started, "finished_ns": monotonic_ns(), "exit": process.returncode, "log": name+".log"}
    write_json(root/(name+".json"), result)
    if process.returncode:
        raise NativeError("command failed: " + name)
    return result


def build(args):
    repo = Path(args.repo).resolve(); root, run_id = prepare_root(args.root)
    command = build_command(repo, root)
    if args.print_command:
        print(json.dumps(command)); return 0
    manifest = source_manifest(repo)
    required = ("Sources/DictationCore/NativeAcceptanceTrace.swift", "Sources/QueuedDictation/NativeAcceptanceEnvironment.swift")
    if not all((repo/file).is_file() and "NATIVE_ACCEPTANCE" in (repo/file).read_text() for file in required):
        raise NativeError("conditional sampling source is not integrated")
    if (root/"native-build.json").exists():
        raise NativeError("refuse existing build evidence")
    result = run_logged(command, repo, root, "native-build-command")
    if source_manifest(repo) != manifest:
        raise NativeError("source changed during conditional build")
    bin_command = command[:2]+["-c", "release", "--arch", "arm64", "--scratch-path", str(root/"build"), "-Xswiftc", "-DNATIVE_ACCEPTANCE", "--show-bin-path"]
    binary_dir = subprocess.check_output(bin_command, cwd=repo, text=True).strip()
    binary = Path(binary_dir)/"QueuedDictation"
    metadata = {"schema_version": SCHEMA, "run_id": run_id, "artifact_kind": "conditional_sampling",
                "conditional_define": "NATIVE_ACCEPTANCE", "source_manifest": manifest, "build": result,
                "binary_path": str(binary), "binary_sha256": digest(binary.read_bytes())}
    write_json(root/"native-build.json", metadata)
    print(json.dumps({"build": "conditional_sampling", "source_sha": manifest["source_sha"], "native_samples": 0}))
    return 0


def signing_commands(repo, app, identity):
    if identity == "-":
        return (["/usr/bin/codesign","--force","--sign","-",str(app)],
                ["bash",str(repo/"Scripts/verify-app.sh"),"development",str(app)],"adhoc_fixture_only")
    return (["/usr/bin/codesign","--force","--sign",identity,"--options","runtime","--timestamp","--entitlements",str(repo/"App/Release.entitlements"),str(app)],
            ["bash",str(repo/"Scripts/verify-app.sh"),"signed",str(app)],"developer_id")


def package(args):
    repo = Path(args.repo).resolve(); root, run_id = prepare_root(args.root)
    app = root/"app/Queued Dictation.app"
    if app.exists() or app.is_symlink():
        raise NativeError("refuse overwriting an existing App")
    metadata_path = root/"native-build.json"
    if not metadata_path.is_file():
        raise NativeError("matching conditional build evidence required")
    metadata = json.loads(metadata_path.read_text()); manifest = source_manifest(repo)
    if metadata.get("run_id") != run_id or metadata.get("conditional_define") != "NATIVE_ACCEPTANCE" or metadata.get("source_manifest") != manifest or metadata.get("artifact_kind") != "conditional_sampling" or metadata.get("build", {}).get("exit") != 0:
        raise NativeError("conditional build/source provenance mismatch")
    binary = owned_path(root, metadata["binary_path"])
    if digest(binary.read_bytes()) != metadata["binary_sha256"]:
        raise NativeError("build binary digest mismatch")
    if not args.sign_identity:
        raise NativeError("package requires explicit --sign-identity ('-' for ad hoc)")
    contents = app/"Contents"; (contents/"MacOS").mkdir(parents=True); (contents/"Resources").mkdir()
    shutil.copy2(binary, contents/"MacOS/QueuedDictation")
    info = plistlib.loads((repo/"App/Info.plist").read_bytes())
    info.update(QDNativeAcceptanceRoot=str(root), QDNativeAcceptanceSourceCommit=manifest["source_sha"])
    (contents/"Info.plist").write_bytes(plistlib.dumps(info)); shutil.copy2(repo/"LICENSE", contents/"Resources/LICENSE.txt")
    sign_argv, verify_argv, signature_scope = signing_commands(repo,app,args.sign_identity)
    signed = run_logged(sign_argv, repo, root, "native-codesign")
    verified = run_logged(verify_argv, repo, root, "native-codesign-verify")
    verifier_dir=root/"native-verifier";verifier_dir.mkdir()
    shutil.copy2(repo/"Scripts/verify-app.sh",verifier_dir/"verify-app.sh")
    if source_manifest(repo) != manifest:
        raise NativeError("source changed during packaging")
    result = {"schema_version": SCHEMA, "run_id": run_id, "artifact_kind": "conditional_sampling", "conditional_define": "NATIVE_ACCEPTANCE",
              "source_manifest": manifest, "build_metadata": metadata, "app_path": str(app), "binary_sha256": digest((contents/"MacOS/QueuedDictation").read_bytes()),
              "info_plist_sha256": digest((contents/"Info.plist").read_bytes()), "sign_identity": args.sign_identity,
              "signed": signed, "verified": verified, "signature_scope":signature_scope,"verifier_path":"native-verifier/verify-app.sh","verifier_sha256":digest((repo/"Scripts/verify-app.sh").read_bytes()), "notarization": "not_submitted", "gui_launched": False}
    write_json(root/"native-package.json", result)
    print(json.dumps({"app": str(app), "source_sha": manifest["source_sha"], "artifact_kind": "conditional_sampling", "native_samples": 0}))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for command in ("serve", "status", "clock", "stop", "release-rest", "checkpoint", "build", "package"):
        item = sub.add_parser(command); item.add_argument("--root", required=True)
        if command == "serve":
            item.add_argument("--pairs", type=int, default=30); item.add_argument("--fixture", action="store_true")
            item.add_argument("--coach-input-mode", choices=("text", "originalAudio"), default="text")
        if command in ("build", "package"):
            item.add_argument("--repo", required=True)
        if command == "build": item.add_argument("--print-command", action="store_true")
        if command == "package": item.add_argument("--sign-identity")
        if command == "release-rest": item.add_argument("--proof", required=True)
        if command == "checkpoint":
            item.add_argument("--pair", type=int, required=True); item.add_argument("--wait-seconds", type=float, default=5)
    args = parser.parse_args(argv)
    try:
        if args.command == "serve": return serve(args)
        if args.command == "build": return build(args)
        if args.command == "package": return package(args)
        if args.command == "checkpoint": return checkpoint(args)
        root = Path(args.root).resolve()
        if args.command == "clock":
            snapshot=admin(root);print(json.dumps({"clock_ns":snapshot["clock_ns"],"clock_basis":snapshot["clock_basis"],"run_id":snapshot["run_id"]}));return 0
        if args.command == "release-rest":
            proof = json.loads(owned_path(root, args.proof).read_text()); print(json.dumps(admin(root, "release-rest", proof)))
        else:
            print(json.dumps(admin(root, "status" if args.command == "status" else "stop", None if args.command == "status" else {})))
        return 0
    except (NativeError, OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print("native-control: " + str(error), file=sys.stderr); return 1


if __name__ == "__main__":
    sys.exit(main())
