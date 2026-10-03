#!/usr/bin/env python3
"""严格归约原生验收证据；fixture 仅检查工具合同，永不输出 native PASS。"""
import argparse
from decimal import Decimal
import importlib.util
import json
import math
from pathlib import Path
import plistlib
import re
import sys

spec = importlib.util.spec_from_file_location("native_control", Path(__file__).with_name("native-control.py"))
control = importlib.util.module_from_spec(spec)
spec.loader.exec_module(control)

DEFAULTS = {"main_limit": 3, "coach_limit": 3, "asr_timeout": 60, "polish_timeout": 30, "coach_timeout": 30,
            "maximum_pending_segments": 20, "maximum_pending_duration": 1800, "maximum_pending_audio_bytes": 268435456,
            "maximum_recording_duration": 300, "maximum_local_bytes": 5368709120, "automatic_sending_window": 86400}


class IncompleteEvidence(control.NativeError):
    pass


def fail(condition, code):
    if not condition:
        raise control.NativeError(code)


def load_json(root, path):
    return json.loads(control.owned_path(root, path).read_text())


def events(root, name, run_id):
    data = control.owned_path(root, name).read_bytes()
    fail(not data or data.endswith(b"\n"), name+": partial final line")
    result, previous = [], 0
    for line in data.splitlines():
        item = json.loads(line)
        fail(item.get("schema_version") == 1 and item.get("run_id") == run_id, name+": schema/run mismatch")
        sequence = control.integer(item.get("sequence"), "sequence", 1)
        fail(sequence > previous, name+": duplicate/unordered sequence")
        previous = sequence
        control.integer(item.get("pid"), "pid", 1); control.integer(item.get("monotonic_ns"), "monotonic_ns", 1)
        result.append(item)
    fail(bool(result), name+": missing events")
    fail(not any(e["event"] in ("trace_failure", "control_failure", "disconnected") for e in result), name+": trace/control failure or disconnect")
    return result


def unique(items, event, key):
    result = {}
    for item in items:
        if item["event"] == event:
            value = item[key]
            if key.endswith("_id"): value = control.identifier(value)
            fail(value not in result, "duplicate " + event + "/" + key)
            result[value] = item
    return result


def one(items, event):
    selected = [item for item in items if item["event"] == event]
    fail(len(selected) == 1, "expected exactly one " + event)
    return selected[0]


def clock_checks(core_boot, http):
    numer = control.integer(core_boot.get("timebase_numer"), "timebase_numer", 1)
    denom = control.integer(core_boot.get("timebase_denom"), "timebase_denom", 1)
    ticks = control.integer(core_boot.get("clock_ticks"), "clock_ticks", 1)
    fail(core_boot.get("clock_basis") == "mach_absolute_time" and ticks*numer//denom <= core_boot.get("monotonic_ns", 0), "Core raw mach conversion mismatch")
    fail(core_boot.get("calibration_valid") is True, "invalid OS clock calibration")
    control.integer(core_boot.get("calibration_uncertainty_ns"), "calibration_uncertainty_ns")
    for before, after, value, offset in (
        ("calibration_before_ns", "calibration_after_ns", "os_calibration_ns", "os_to_mono_offset_ns"),):
        low = control.integer(core_boot.get(before), before, 1); high = control.integer(core_boot.get(after), after, 1)
        raw = control.integer(core_boot.get(value), value, 1)
        fail(type(core_boot.get(offset)) is int and low <= raw+core_boot[offset] <= high, "independent OS/mach calibration bracket mismatch")
    fail(abs(int(Decimal(str(core_boot["carbon_value_seconds"]))*1000000000)-core_boot["os_calibration_ns"]) <= 1, "Carbon raw rounding/units mismatch (>1ns)")
    fail(abs(core_boot["os_to_mono_offset_ns"]) <= 2000000 and core_boot["calibration_after_ns"]-core_boot["calibration_before_ns"] <= 10000000, "Carbon clock offset/uncertainty guard")
    quartz_source=core_boot.get("quartz_source")
    if quartz_source == "documented_nanoseconds_since_startup":
        if "https://developer.apple.com/documentation/coregraphics/cgeventtimestamp" not in str(core_boot.get("quartz_epoch_source", "")): raise IncompleteEvidence("official Quartz epoch source missing")
        fail(core_boot.get("quartz_to_mono_offset_ns") == 0, "raw Fn epoch must not be shifted")
    elif quartz_source == "synthetic_contract_fixture":
        pass
    else:
        raise IncompleteEvidence("unknown Quartz epoch provenance")
    uptime = int(Decimal(str(core_boot["process_uptime_seconds"]))*1000000000)
    fail(core_boot.get("epoch_tolerance_ns", 2000000) == 2000000, "epoch qualification changed")
    fail(core_boot["uptime_before_ns"]-1 <= uptime <= core_boot["uptime_after_ns"]+1 and core_boot["uptime_after_ns"]-core_boot["uptime_before_ns"] <= 10000000 and abs((core_boot["uptime_before_ns"]+core_boot["uptime_after_ns"])//2-uptime) <= 2000000, "uptime/mach bracket mismatch")
    probes = [one(http, "boot")["clock_probe"], one(http, "server_closed")["clock_probe"]]
    native_clock = True
    for probe in probes:
        fail(probe.get("valid") is True and probe["clock_before_ns"] <= probe["converted_ns"] <= probe["clock_after_ns"], "Python/mach calibration invalid")
        fail(probe["converted_ns"] == probe["clock_ticks"]*probe["timebase_numer"]//probe["timebase_denom"], "HTTP raw clock units mismatch")
        if probe.get("clock_basis") != "mach_absolute_time" or probe.get("platform") != "darwin" or probe.get("clock_selection") != "direct_mach":
            native_clock = False
        else:
            fail(probe["timebase_numer"] == numer and probe["timebase_denom"] == denom, "HTTP/Core mach timebases differ")
    fail(probes[1]["clock_before_ns"] >= probes[0]["clock_after_ns"], "HTTP clock reversed")
    return numer, denom, native_clock


def package_checks(root, run_id, source):
    package = load_json(root, "native-package.json")
    fail(package.get("schema_version") == 1 and package.get("run_id") == run_id and package.get("artifact_kind") == "conditional_sampling" and package.get("conditional_define") == "NATIVE_ACCEPTANCE", "not a matching conditional sampling package")
    manifest = package["source_manifest"]
    fail(manifest.get("source_sha") == source and re.fullmatch("[0-9a-f]{40}", source or ""), "package source SHA mismatch")
    fail(control.digest(json.dumps(manifest["files"], sort_keys=True).encode()) == manifest["sha256"], "source manifest digest mismatch")
    fail(all(name in manifest["files"] for name in ("Sources/DictationCore/NativeAcceptanceTrace.swift", "Sources/QueuedDictation/NativeAcceptanceEnvironment.swift")), "sampling sources absent")
    build = package["build_metadata"]
    fail(build.get("artifact_kind") == "conditional_sampling" and build.get("conditional_define") == "NATIVE_ACCEPTANCE" and build.get("source_manifest") == manifest and build.get("run_id") == run_id, "build provenance mismatch")
    argv = build["build"]["argv"]
    fail(build["build"]["exit"] == 0 and argv[:2] == ["swift", "build"] and "-DNATIVE_ACCEPTANCE" in argv and "--scratch-path" in argv and argv[argv.index("--arch")+1] == "arm64" and argv[argv.index("--jobs")+1] == "2" and argv[argv.index("-c")+1] == "release", "actual conditional build argv missing")
    for step in (package["signed"], package["verified"], build["build"]):
        fail(step["exit"] == 0 and control.owned_path(root, step["log"]).is_file(), "actual build/sign/verify log missing")
    if package.get("signature_scope")!="developer_id" or package.get("sign_identity")=="-": raise IncompleteEvidence("ad hoc package is fixture only; Developer ID runtime required")
    argv=package["signed"]["argv"]
    fail(argv[:3]==["/usr/bin/codesign","--force","--sign"] and argv[3]==package["sign_identity"] and "--options" in argv and argv[argv.index("--options")+1]=="runtime" and "--timestamp" in argv and "--entitlements" in argv, "production signing parameters missing")
    fail(package["verified"]["argv"][0]=="bash" and Path(package["verified"]["argv"][1]).name=="verify-app.sh" and package["verified"]["argv"][2]=="signed", "existing signed verifier proof missing")
    verifier=control.owned_path(root,package["verifier_path"])
    fail(control.digest(verifier.read_bytes())==package["verifier_sha256"]==manifest["files"].get("Scripts/verify-app.sh"), "frozen production verifier differs")
    app = control.owned_path(root, package["app_path"])
    binary, plist = app/"Contents/MacOS/QueuedDictation", app/"Contents/Info.plist"
    fail(control.digest(binary.read_bytes()) == package["binary_sha256"] and control.digest(plist.read_bytes()) == package["info_plist_sha256"], "packaged artifact changed")
    info = plistlib.loads(plist.read_bytes())
    fail(info.get("QDNativeAcceptanceRoot") == str(root) and info.get("QDNativeAcceptanceSourceCommit") == source and info.get("CFBundleIdentifier") == "io.github.patrick-fu.queued-dictation", "sampling Info/source/root mismatch")
    # Reuse the frozen production verifier: boolean/log declarations are not signature evidence.
    verification=control.run_logged(["bash",str(verifier),"signed",str(app)],root,root,"native-report-signature-"+str(control.uuid.uuid4()))
    fail(verification["exit"]==0,"actual existing signed verifier rejected artifact")
    return package


def reduce(root):
    root = root.resolve()
    errors, incomplete, missing, rows = [], [], [], []
    result = {"schema_version": 1, "verdict": "INCOMPLETE", "native_samples": 0, "all_attempts": [],
              "errors": errors, "missing_evidence": missing, "missing_native_proof": incomplete, "scope": {"full_spec_matrix": False, "provider_quality": False}}
    def attempt(name, operation):
        try:
            return operation()
        except (IncompleteEvidence, FileNotFoundError, KeyError) as error:
            missing.append(name+": "+str(error)); return None
        except (control.NativeError, OSError, ValueError, TypeError, IndexError, ZeroDivisionError) as error:
            errors.append(name+": "+str(error)); return None
    ready = attempt("ready", lambda: load_json(root, "native-ready.json"))
    if not ready: return result
    run_id = attempt("run_id", lambda: control.identifier(ready["run_id"]))
    pairs = attempt("pairs", lambda: control.integer(ready["pairs"], "pairs", 1))
    if not run_id or not pairs: return result
    result.update(run_id=run_id, declared_pairs=pairs)
    result["all_attempts"]=[{"pair_index":p,"valid":False,"latency_ms":None} for p in range(1,pairs+1)]
    origin = ready.get("evidence_origin")
    fixture = origin == "synthetic_contract_fixture"
    if origin not in ("native_physical", "synthetic_contract_fixture"): incomplete.append("ready explicit evidence_origin missing")
    for key, value in (("asr_model", control.MODELS["asr"]), ("polish_model", control.MODELS["polish"]), ("coach_model", control.MODELS["coach"]), ("fake_service_key", control.FAKE_KEY)):
        if ready.get(key) != value: errors.append("ready model/fake key mismatch: "+key)
    endpoint = control.urlparse(ready.get("base_url", ""))
    if endpoint.scheme != "http" or endpoint.hostname != "localhost" or endpoint.path != "/v1" or not endpoint.port or endpoint.username or endpoint.query or endpoint.fragment:
        errors.append("ready is not exact localhost origin")
    core = attempt("core", lambda: events(root, "native-core.jsonl", run_id))
    app = attempt("app", lambda: events(root, "native-app.jsonl", run_id))
    http = attempt("http", lambda: events(root, "native-http.jsonl", run_id))
    if not core or not app or not http: return result
    core_boot = attempt("Core boot", lambda: one(core, "boot"))
    app_boot = attempt("App boot", lambda: one(app, "boot"))
    http_boot = attempt("HTTP boot", lambda: one(http, "boot"))
    if not core_boot or not app_boot or not http_boot: return result
    if core_boot.get("quartz_source") == "synthetic_contract_fixture": fixture = True; incomplete.append("synthetic Quartz calibration cannot prove native")
    if core_boot.get("quartz_source") not in ("synthetic_contract_fixture", "documented_nanoseconds_since_startup"):
        incomplete.append("unrecognized real Quartz calibration source")
    if http_boot.get("evidence_origin") != origin: errors.append("HTTP/ready evidence origin mismatch")
    source = core_boot.get("source_sha")
    if app_boot.get("source_sha") != source or app_boot.get("local_only") is not True or Path(app_boot.get("root", "")).resolve() != root or app_boot.get("main_limit") != 3 or app_boot.get("coach_limit") != 3:
        errors.append("whole App source/root/local-only/default pool proof mismatch")
    if app_boot.get("pid") != core_boot.get("pid"): errors.append("App/Core producer PID mismatch")
    clock = attempt("clock", lambda: clock_checks(core_boot, http))
    if not clock: return result
    numer, denom, native_clock = clock
    if not native_clock: incomplete.append("Python/Mach identity unavailable")
    try:
        package_checks(root, run_id, source)
    except (control.NativeError, OSError, ValueError, KeyError, TypeError, IndexError) as error:
        incomplete.append("sampling package: "+str(error))
    operator = attempt("operator", lambda: load_json(root, "operator.json"))
    if not operator:
        incomplete.append("explicit operator metadata missing")
        operator = {}
    if operator.get("evidence_origin") == "synthetic_contract_fixture": fixture = True
    if operator.get("evidence_origin") not in (origin, "synthetic_contract_fixture"): incomplete.append("operator/ready evidence origin mismatch")
    physical = operator.get("schema_version") == 1 and operator.get("run_id") == run_id and operator.get("evidence_origin") == "native_physical" and operator.get("physical_input") is True and operator.get("source") in ("human", "cua")
    for key in ("os_version", "hardware_model", "architecture", "keyboard", "microphone", "matrix_id", "binding", "gesture", "document_source", "attestation_source"):
        if not isinstance(operator.get(key), str) or not operator[key].strip(): physical = False
    if operator.get("architecture") != "arm64" or not re.match(r"^(1[4-9]|[2-9][0-9])\.", str(operator.get("os_version", ""))) or operator.get("document_source") not in ("human", "cua"):
        physical = False
    if operator.get("sleep_or_device_change") is not False or operator.get("permissions_authorized_before_sampling") is not True: physical = False
    if not physical: incomplete.append("explicit physical/device/matrix/stable/document attestation incomplete")
    if operator.get("attestation_artifact"):
        try:
            evidence = control.owned_path(root, operator["attestation_artifact"])
            fail(evidence.is_file() and control.digest(evidence.read_bytes()) == operator.get("attestation_sha256"), "operator source artifact mismatch")
        except (control.NativeError, OSError) as error: incomplete.append(str(error))
    elif not fixture:
        incomplete.append("operator source artifact missing")
    result["scope"].update(matrix_id=operator.get("matrix_id"), os_version=operator.get("os_version"), hardware_model=operator.get("hardware_model"), minimum_os14_observed=str(operator.get("os_version", "")).startswith("14."))
    starts = attempt("capture_start", lambda: unique(core, "capture_start", "capture_id")) or {}
    finished = attempt("capture_finished", lambda: unique(core, "capture_finished", "capture_id")) or {}
    stopped = attempt("capture_stop", lambda: unique(core, "capture_stop", "capture_id")) or {}
    recordings = attempt("recording_start", lambda: unique(app, "recording_start", "recording_index")) or {}
    ended = attempt("recording_end", lambda: unique(app, "recording_end", "recording_index")) or {}
    expected_indices = set(range(1, pairs*7+1))
    if set(recordings) != expected_indices or set(ended) != expected_indices or len(starts) != pairs*7 or len(finished) != pairs*7:
        errors.append("every attempt required: capture/recording/end count differs from declared pairs")
    captured, used_triggers, pcm_hashes = {}, set(), set()
    # Retain raw latency for failed audio/checkpoint attempts as well; never filter slow failures out of rank.
    for pair_index in range(1,pairs+1):
        row={"pair_index":pair_index,"latency_ms":None,"valid":False}
        try:
            selected=[(cid,start) for cid,start in starts.items() if start.get("capture_index")==pair_index*7]
            if len(selected)!=1: raise IncompleteEvidence("missing/ambiguous B capture")
            cid,start=selected[0]
            pcm=[e for e in core if e["event"]=="pcm" and control.identifier(e["capture_id"])==cid and e.get("yield_result")=="enqueued" and e.get("frames",0)>0]
            keys=[e for e in core if e["event"]=="hotkey" and e.get("accepted") is True and e.get("is_repeat") is False and e.get("edge")=="down" and e["sequence"]<start["sequence"]]
            if not pcm or not keys: raise IncompleteEvidence("missing PCM/trigger")
            t0,t1=keys[-1]["os_ns"],pcm[0]["monotonic_ns"]
            row.update(capture_id=cid,t0_ns=t0,t1_ns=t1,latency_ns=t1-t0,latency_ms=(t1-t0)/1000000)
        except (control.NativeError,KeyError,TypeError): pass
        rows.append(row)
    def capture_check(capture_id, start):
        index = control.integer(start["capture_index"], "capture_index", 1)
        fail(index not in captured and index in expected_indices, "duplicate/outside capture_index")
        final, stop = finished[capture_id], stopped[capture_id]
        fail(final["capture_index"] == index and final.get("trace_failed") is False and type(start.get("channels")) is int and start["channels"] >= 1, "capture identity/trace/mono invalid")
        chunks = [item for item in core if item["event"] == "pcm" and control.identifier(item["capture_id"]) == capture_id]
        fail(bool(chunks), "missing first PCM")
        first, frames, sample_end, chunk_index = None, 0, None, -1
        for item in chunks:
            fail(item["chunk_index"] == chunk_index+1, "chunk order/gap")
            chunk_index += 1
            fail(item.get("host_time_valid") is True and item.get("sample_time_valid") is True and item.get("channels") == 1 and item.get("input_channels") == start["channels"] and item["rate"] == start["rate"], "invalid native PCM time/format flags")
            count = control.integer(item["frames"], "frames", 1)
            fail(type(item["sample_time"]) is int and (sample_end is None or item["sample_time"] == sample_end), "sample_time discontinuity")
            sample_end = item["sample_time"]+count
            host_ns = control.integer(item["host_ticks"], "host_ticks", 1)*numer//denom
            fail(host_ns <= item["converted_ns"] <= item["monotonic_ns"], "PCM clock ordering/negative latency")
            if item["yield_result"] != "enqueued":
                fail(item["yield_result"] in ("dropped", "terminated") and item["monotonic_ns"] >= stop["stop_ns"], "yield loss before stop")
                continue
            frames += count
            if first is None: first = item
        fail(first is not None and frames == final["enqueued_frames"], "enqueued frame count mismatch")
        pcm = control.owned_path(root, final["pcm_path"]).read_bytes()
        fail(len(pcm) == frames*2 and control.digest(pcm) == final["pcm_sha256"] and final["pcm_sha256"] not in pcm_hashes, "source PCM byte count/hash/ambiguity")
        pcm_hashes.add(final["pcm_sha256"])
        fail(recordings[index]["history_id"] == ended[index]["history_id"], "recording history ID changed")
        candidates = [e for e in core if e["event"] == "hotkey" and e.get("accepted") is True and e.get("is_repeat") is False and e.get("edge") == "down" and e["sequence"] < start["sequence"]]
        fail(bool(candidates), "capture has no accepted physical trigger")
        trigger = candidates[-1]
        fail(trigger["sequence"] not in used_triggers, "one hotkey mapped to multiple captures")
        used_triggers.add(trigger["sequence"])
        raw = int(Decimal(str(trigger["os_value"]))*1000000000) if trigger["os_units"] == "seconds_since_boot" else trigger["os_value"]
        tolerance = 1 if trigger["os_units"] == "seconds_since_boot" else 0
        fail(trigger["os_units"] in ("seconds_since_boot", "nanoseconds_since_boot") and type(raw) is int and abs(raw+(core_boot["os_to_mono_offset_ns"] if trigger["os_units"] == "seconds_since_boot" else 0)-trigger["os_ns"]) <= tolerance and raw > 0 and trigger["os_ns"] <= trigger["callback_ns"] <= start["monotonic_ns"] <= first["monotonic_ns"], "raw hotkey units/negative or reordered clock")
        fail(trigger.get("binding") in ("fn", "combination") and trigger.get("binding") == operator.get("binding") and recordings[index].get("main_limit") == 3 and recordings[index].get("coach_limit") == 3, "binding/default recording pools invalid")
        captured[index] = {"capture_id": capture_id, "history_id": control.identifier(recordings[index]["history_id"]), "frame_count": frames,
                           "rate": start["rate"], "pcm_sha256": final["pcm_sha256"], "trigger": trigger, "first_pcm": first}
    for capture_id, start in starts.items(): attempt("capture "+capture_id, lambda c=capture_id,s=start: capture_check(c,s))
    accepted=[e for e in core if e["event"]=="hotkey" and e.get("accepted") is True and e.get("is_repeat") is False and e.get("edge")=="down" and e.get("binding") in ("fn","combination")]
    meaningful=[]
    for key in accepted:
        if operator.get("gesture")=="tapToToggle":
            intervals=[(recordings[i]["monotonic_ns"],ended[i]["monotonic_ns"]) for i in recordings if i in ended]
            if any(a<=key["callback_ns"]<=b for a,b in intervals): continue
        elif operator.get("gesture")!="holdToRecord":
            missing.append("recording gesture cannot classify physical attempts")
        meaningful.append(key)
    matched_start_sequences=[]
    for start in starts.values():
        candidates=[e for e in meaningful if e["sequence"]<start["sequence"]]
        if candidates: matched_start_sequences.append(candidates[-1]["sequence"])
    fail_keys=[e for e in meaningful if e["sequence"] not in matched_start_sequences]
    if fail_keys or len(matched_start_sequences)!=len(set(matched_start_sequences)):
        errors.append("unmatched meaningful accepted start attempts; later successful retries cannot hide failures")
    result["meaningful_start_count"]=len(meaningful)
    result["unmatched_start_attempts"]=[dict(trigger_sequence=e["sequence"],t0_ns=e["os_ns"],binding=e["binding"]) for e in fail_keys]
    extra_rows=[dict(pair_index=None,trigger_sequence=e["sequence"],t0_ns=e["os_ns"],latency_ms=None,valid=False,failure_reason="accepted start without capture/PCM") for e in fail_keys]
    received = attempt("HTTP receive", lambda: unique(http, "request_received", "request_id")) or {}
    parsed = attempt("HTTP parsed", lambda: unique(http, "request_parsed", "request_id")) or {}
    mapped = attempt("HTTP mapping", lambda: unique(http, "request_mapped", "request_id")) or {}
    responses = attempt("HTTP responses", lambda: unique(http, "response_begin", "request_id")) or {}
    response_ends = attempt("HTTP ends", lambda: unique(http, "response_end", "request_id")) or {}
    if len(received) != pairs*21 or set(received) != set(parsed) or set(received) != set(mapped) or set(received) != set(responses) or set(received) != set(response_ends):
        errors.append("true full HTTP receive/parse/map/respond count mismatch")
    requests = {}
    def http_check(request_id, raw):
        item, mapping = parsed[request_id], mapped[request_id]
        fail(raw["body_complete_ns"] == item["body_complete_ns"] and raw["headers_received_ns"] == item["headers_received_ns"] and raw["body_sha256"] == item["body_sha256"], "receive facts changed after mapping")
        body = control.owned_path(root, raw["body_path"]).read_bytes()
        fail(len(body) == raw["body_bytes"] and control.digest(body) == raw["body_sha256"], "actual full HTTP body missing/hash mismatch")
        index = mapping["capture_index"]; capture = captured[index]
        pair_index, position = divmod(index-1, 7); pair_index += 1; slot = control.SLOTS[position]
        label = "Native pair %02d %s." % (pair_index, slot)
        fail(mapping["pair_index"] == pair_index and mapping["slot"] == slot and mapping["label"] == label and control.identifier(mapping["history_id"]) == capture["history_id"] and control.identifier(mapping["capture_id"]) == capture["capture_id"], "HTTP capture digest/recording mapping mismatch")
        role = item["role"]
        fail(role in control.MODELS and item["model"] == control.MODELS[role], "model/role mismatch")
        if role == "asr":
            fail(raw["path"] == "/v1/audio/transcriptions", "ASR path mismatch")
            audio = control.multipart_wave(raw["content_type"], body)
            details, _ = control.wav_details(audio)
            fail(details["pcm_sha256"] == capture["pcm_sha256"] and details["frame_count"] == capture["frame_count"] and details["rate"] == capture["rate"], "uploaded WAV differs from actual captured PCM")
            fail(control.owned_path(root, item["wav_path"]).read_bytes() == audio and all(item[key] == details[key] for key in details), "WAV saved/metadata mismatch")
        else:
            fail(raw["path"] == "/v1/chat/completions", "chat path mismatch")
            model, actual_pair, actual_slot, audio = control.user_content(body)
            fail(model == item["model"] and actual_pair == pair_index and actual_slot == slot, "chat input label/model mismatch")
            if role == "coach":
                fail((audio is not None) == (ready["coach_input_mode"] == "originalAudio"), "Coach input mode mismatch")
                if audio is not None:
                    details,_ = control.wav_details(audio)
                    fail(details["pcm_sha256"] == capture["pcm_sha256"] and details["frame_count"] == capture["frame_count"] and details["rate"] == capture["rate"], "Coach original WAV differs")
        begin, end = responses[request_id], response_ends[request_id]
        fail(begin["status"] == end["status"] == 200 and raw["headers_received_ns"] <= raw["body_complete_ns"] <= begin["monotonic_ns"] <= end["response_end_ns"] <= end["monotonic_ns"], "HTTP response/deadline/cancel ordering invalid")
        fail(begin["monotonic_ns"]-raw["headers_received_ns"] < (60 if role == "asr" else 30)*1000000000, "response exceeds unchanged default deadline")
        response_body = control.owned_path(root, begin["response_path"]).read_bytes()
        fail(len(response_body) == begin["response_bytes"] and control.digest(response_body) == begin["response_sha256"], "actual response body missing/hash mismatch")
        response = json.loads(response_body)
        content = response["text"] if role == "asr" else response["choices"][0]["message"]["content"]
        fail(content == (label if role != "coach" else '{"kind":"no_card"}'), "response changes unique English label/no_card")
        key = (pair_index, slot, role)
        fail(key not in requests, "duplicate/retried actual role request")
        requests[key] = {"request_id": request_id, "body_complete_ns": raw["body_complete_ns"], "response_begin_ns": begin["monotonic_ns"], "response_end_ns": end["response_end_ns"], "capture": capture}
    for request_id, item in received.items(): attempt("HTTP "+request_id, lambda i=request_id,x=item: http_check(i,x))
    cues = attempt("cues", lambda: unique(http, "pair_cue", "pair_index")) or {}
    drains = attempt("drains", lambda: unique(http, "pair_drained", "pair_index")) or {}
    checkpoint_index = attempt("checkpoint index", lambda: load_json(root, "native-checkpoint-index.json")) or []
    checkpoints = {}
    matrix_configs = []
    for item in checkpoint_index:
        def checkpoint_check(item=item):
            pair_index = control.integer(item["pair_index"], "pair_index", 1)
            fail(pair_index not in checkpoints, "duplicate pair checkpoint")
            path = control.owned_path(root, item["path"])
            fail(control.digest(path.read_bytes()) == item["sha256"], "checkpoint file changed")
            checkpoint = json.loads(path.read_text()); checkpoint_id = control.identifier(item["checkpoint_id"])
            fail(checkpoint.get("schema_version") == 1 and checkpoint.get("run_id") == run_id and control.identifier(checkpoint["checkpoint_id"]) == checkpoint_id and checkpoint.get("queue") == [], "checkpoint identity/undrained queue")
            log = [e for e in app if e["event"] == "checkpoint" and control.identifier(e["checkpoint_id"]) == checkpoint_id]
            fail(len(log) == 1 and all(log[0].get(key) == checkpoint.get(key) for key in ("entries", "queue", "config", "exports")), "checkpoint not matching actual App trace")
            config = checkpoint["config"]
            fail(all(config.get(key) == value and not isinstance(config[key], bool) for key,value in DEFAULTS.items()), "default config/deadline/resource changed")
            fail(config.get("gesture") == operator.get("gesture") and config.get("input_mode") == ready.get("coach_input_mode") and "binding" in config, "one matrix/input mode not retained")
            if matrix_configs: fail(config == matrix_configs[0], "matrix configuration changed across pairs")
            else: matrix_configs.append(config)
            fail(log[0]["monotonic_ns"] >= drains[pair_index]["monotonic_ns"], "checkpoint before HTTP drain")
            checkpoints[pair_index] = checkpoint
        attempt("checkpoint", checkpoint_check)
    doc = attempt("document", lambda: control.owned_path(root, "document-final.txt").read_text())
    previous_order, doc_positions = 0, []
    def pair_check(pair_index):
        nonlocal previous_order
        b = captured[pair_index*7]; t0,t1 = b["trigger"]["os_ns"],b["first_pcm"]["monotonic_ns"]
        rows[pair_index-1].update(history_id=b["history_id"],frame_count=b["frame_count"],pcm_sha256=b["pcm_sha256"])
        cue = cues[pair_index]
        fail(cue["monotonic_ns"] <= t0 <= t1, "B trigger before real 3/3 cue")
        for role,slots,field in (("asr",("P1","P2","A"),"main_request_ids"),("coach",("H1","H2","H3"),"coach_request_ids")):
            selected = [requests[(pair_index,slot,role)] for slot in slots]
            fail(set(cue[field]) == {r["request_id"] for r in selected}, "cue is not 3 actual full request IDs")
            fail(all(r["body_complete_ns"] <= t0 <= t1 < r["response_begin_ns"] for r in selected), "actual HTTP 3/3 intervals do not cover both t0/t1")
        for instant in (t0,t1):
            active_main = [r for (p,s,role),r in requests.items() if role in ("asr","polish") and r["body_complete_ns"] <= instant < r["response_begin_ns"]]
            active_coach = [r for (p,s,role),r in requests.items() if role == "coach" and r["body_complete_ns"] <= instant < r["response_begin_ns"]]
            fail(len(active_main) == len(active_coach) == 3, "actual cross-pair default occupancy is not3/3")
        releases = [e for e in http if e["event"] == "release" and e.get("pair_index") == pair_index]
        first = [e for e in releases if e.get("reason") == "first_pcm"]
        rest = [e for e in releases if e.get("reason") == "operator_b_ready"]
        fail(len(first) == len(rest) == 1 and first[0]["pcm_sequence"] == b["first_pcm"]["sequence"] and first[0]["first_pcm_ns"] == t1 and first[0]["monotonic_ns"] >= t1, "first PCM handshake missing/early")
        proof = rest[0]["proof"]
        fail(proof.get("schema_version") == 1 and proof.get("run_id") == run_id and proof.get("pair_index") == pair_index and control.identifier(proof["history_id"]) == b["history_id"] and proof.get("stage") == "waitingForPredecessor" and proof.get("source") in ("human","cua"), "explicit B queue observation missing")
        low,high = proof["observation_started_ns"],proof["observation_finished_ns"]
        fail(requests[(pair_index,"B","polish")]["response_end_ns"] <= low <= high <= rest[0]["monotonic_ns"], "B queue proof not after actual B completion")
        for slot in ("P2","A"):
            held = requests[(pair_index,slot,"asr")]
            fail(held["body_complete_ns"] <= low <= high < held["response_begin_ns"] and rest[0]["monotonic_ns"] <= held["response_begin_ns"], "A/P2 not held during B-ready proof")
        artifact = control.owned_path(root, proof["artifact_path"])
        fail(artifact.is_file() and control.digest(artifact.read_bytes()) == proof["artifact_sha256"], "B queue observation source missing/changed")
        checkpoint = checkpoints[pair_index]
        entries = {control.identifier(e["id"]):e for e in checkpoint["entries"]}
        exports = {control.identifier(e["history_id"]):e for e in checkpoint["exports"]}
        fail(len(entries) == len(checkpoint["entries"]) and len(exports) == len(checkpoint["exports"]), "duplicate history/export ID")
        for position,slot in enumerate(control.SLOTS,1):
            capture = captured[(pair_index-1)*7+position]; entry = entries[capture["history_id"]]; exported = exports[capture["history_id"]]
            order = control.integer(entry["recordingOrder"], "recordingOrder", 1)
            fail(order > previous_order, "history recording order lost/reused")
            previous_order = order
            label = "Native pair %02d %s." % (pair_index,slot)
            fail(entry["frameCount"] == capture["frame_count"] and entry["sampleRate"] == capture["rate"] and entry["rawTranscription"] == label and entry["polishedText"] == label and entry["disposition"] == "completed" and entry["queueStage"] == "completed" and entry.get("delivery") == "delivered", "public history frames/format/processing/terminal mismatch")
            details,_ = control.wav_details(control.owned_path(root, exported["path"]).read_bytes())
            fail(all(exported.get(key) == details[key] for key in ("frame_count","rate","pcm_sha256","wav_sha256")) and details["pcm_sha256"] == capture["pcm_sha256"] and details["frame_count"] == capture["frame_count"] and details["rate"] == capture["rate"], "public exported WAV does not match source/history/upload")
            for role in control.MODELS: fail((pair_index,slot,role) in requests, "missing real role request")
            fail(doc is not None and doc.count(label) == 1, "document missing/duplicate unique label")
            doc_positions.append(doc.index(label))
        if pair_index > 1: fail(drains[pair_index-1]["monotonic_ns"] < cues[pair_index]["monotonic_ns"], "pair pressure not naturally drained")
    for pair_index in range(1,pairs+1):
        failure_count = len(errors)+len(missing)
        attempt("pair %d" % pair_index, lambda p=pair_index: pair_check(p))
        rows[pair_index-1]["valid"] = len(errors)+len(missing) == failure_count
    if doc_positions != sorted(doc_positions): errors.append("actual document FIFO order mismatch")
    if doc is not None and len(control.LABEL.findall(doc)) != pairs*7: errors.append("document extra/unrecognized control labels")
    latencies = [row["latency_ns"] for row in rows if "latency_ns" in row]
    result["all_attempts"] = rows+extra_rows
    if len(latencies) != pairs or pairs < 30:
        missing.append("at least30 complete pairs from same matrix required; missing attempts retained")
    if latencies:
        ordered = sorted(latencies); rank = math.ceil(len(ordered)*0.95)
        result["diagnostic_only"] = {"observed_latency_count":len(latencies),"nearest_rank":rank,"p95_ms":ordered[rank-1]/1000000,"synthetic_or_unverified":True}
        if ordered[rank-1] > 500000000: errors.append("raw physical trigger→successful PCM nearest-rank P95 exceeds500ms")
    if errors: result["verdict"] = "FAIL"
    elif missing: result["verdict"] = "INCOMPLETE"
    elif fixture: result["verdict"] = "FIXTURE_ONLY"
    elif incomplete: result["verdict"] = "INCOMPLETE"
    else:
        result["verdict"] = "PASS_NATIVE_CELL"; result["native_samples"] = pairs
        result["physical_key_to_pcm_p95_ms"] = result["diagnostic_only"]["p95_ms"]
        result["diagnostic_only"]["synthetic_or_unverified"] = False
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument("--root",required=True)
    args = parser.parse_args(argv)
    result = reduce(Path(args.root))
    root = Path(args.root).resolve()
    control.write_json(root/"native-report.json",result)
    columns = ("pair_index","capture_id","history_id","t0_ns","t1_ns","latency_ns","latency_ms","frame_count","pcm_sha256","trigger_sequence","valid","failure_reason")
    import csv
    with (root/"native-pairs.csv").open("w",newline="",encoding="utf-8") as handle:
        writer=csv.DictWriter(handle,fieldnames=columns); writer.writeheader()
        for row in result["all_attempts"]: writer.writerow({key:row.get(key) for key in columns})
    print(json.dumps(result,ensure_ascii=False,allow_nan=False))
    return 0 if result["verdict"] == "PASS_NATIVE_CELL" else (2 if result["verdict"] == "FIXTURE_ONLY" else 1)


if __name__ == "__main__":
    sys.exit(main())
