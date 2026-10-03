"""工具合同反例。所有 PCM、事件、设备字段均为明确 synthetic fixture；native=0。"""
import concurrent.futures
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
import wave

HERE = Path(__file__).resolve().parent
def module(name, filename):
    spec = importlib.util.spec_from_file_location(name,HERE/filename)
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
control=module("native_control_test","native-control.py")
report=module("native_report_test","native-report.py")


def audio(index):
    pcm=struct.pack("<hhhh",index,-index,index+1,-index-1)
    value=io.BytesIO()
    with wave.open(value,"wb") as writer:
        writer.setnchannels(1);writer.setsampwidth(2);writer.setframerate(48000);writer.writeframes(pcm)
    return pcm,value.getvalue()


def multipart(wav):
    boundary="native-contract-fixed-boundary"
    body=("--"+boundary+'\r\nContent-Disposition: form-data; name="model"\r\n\r\nqd-native-asr\r\n--'+boundary+'\r\nContent-Disposition: form-data; name="file"; filename="segment.wav"\r\nContent-Type: audio/wav\r\n\r\n').encode()+wav+("\r\n--"+boundary+"--\r\n").encode()
    return "multipart/form-data; boundary="+boundary,body


class Fixture:
    def __init__(self,root,pairs=30,latencies=None,live=False):
        self.root,self.pairs,self.live=root,pairs,live
        self.run_id=str(uuid.uuid4());self.sequence={"core":0,"app":0,"http":0};self.ids={}
        self.core=[];self.app=[];self.http=[];self.latencies=latencies or [150000000]*pairs
        self.base=100000000000 if not live else control.monotonic_ns()
        self.numer,self.denom=1,1
        self.calibration=self.base

    def emit(self,lane,event,ns,**fields):
        self.sequence[lane]+=1
        item=dict(schema_version=1,run_id=self.run_id,event=event,sequence=self.sequence[lane],pid=444 if lane!="http" else 555,monotonic_ns=ns)
        item.update(fields);getattr(self,lane).append(item)
        if self.live:
            with (self.root/("native-"+lane+".jsonl")).open("a") as handle: handle.write(json.dumps(item)+"\n")
        return item

    def capture(self,index,start,latency=5000000,finish=True):
        pcm,wav=audio(index);capture_id,history_id=str(uuid.uuid4()),str(uuid.uuid4())
        self.ids[index]=(capture_id,history_id,pcm,wav)
        if self.live: start=min(start,control.monotonic_ns())
        callback=control.monotonic_ns() if self.live else start+1000
        self.emit("core","hotkey",callback if self.live else start,binding="fn",edge="down",accepted=True,is_repeat=False,os_value=start,os_units="nanoseconds_since_boot",os_ns=start,callback_ns=callback)
        started=control.monotonic_ns() if self.live else start+2000
        self.emit("core","capture_start",started,capture_id=capture_id,capture_index=index,rate=48000,channels=2)
        self.emit("app","recording_start",control.monotonic_ns() if self.live else start+3000,history_id=history_id,recording_index=index,main_active=3 if index%7==0 else 0,coach_active=3 if index%7==0 else 0,main_limit=3,coach_limit=3)
        pcm_ns=control.monotonic_ns() if self.live else start+latency
        self.emit("core","pcm",pcm_ns,capture_id=capture_id,chunk_index=0,frames=4,rate=48000,channels=1,input_channels=2,host_ticks=started if self.live else start+1000000,host_time_valid=True,sample_time=0,sample_time_valid=True,converted_ns=pcm_ns-1 if self.live else start+latency-1000,yield_result="enqueued")
        path=self.root/"captures"/(capture_id+".pcm16");path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(pcm)
        if finish:self.finish(index,control.monotonic_ns() if self.live else start+latency+1000000)
        return capture_id,history_id,pcm,wav

    def finish(self,index,ns):
        capture_id,history_id,pcm,wav=self.ids[index]
        self.emit("core","capture_stop",ns,capture_id=capture_id,stop_ns=ns)
        self.emit("core","capture_finished",ns+1000,capture_id=capture_id,capture_index=index,enqueued_frames=4,pcm_sha256=control.digest(pcm),pcm_path="captures/"+capture_id+".pcm16",trace_failed=False)
        self.emit("app","recording_end",ns+2000,history_id=history_id,recording_index=index)

    def request(self,index,role,received,begin,end):
        capture_id,history_id,pcm,wav=self.ids[index];pair,pos=divmod(index-1,7);pair+=1;slot=control.SLOTS[pos]
        label="Native pair %02d %s."%(pair,slot);request_id=str(uuid.uuid4());base="http/requests/"+request_id
        if role=="asr":ctype,body=multipart(wav);path="/v1/audio/transcriptions"
        else:
            ctype="application/json";path="/v1/chat/completions"
            payload={"model":control.MODELS[role],"messages":[{"role":"system","content":"fixture protocol prompt"},{"role":"user","content":label}]}
            if role=="coach":payload["stream"]=False
            body=json.dumps(payload).encode()
        target=self.root/(base+".body");target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(body)
        facts=dict(request_id=request_id,headers_received_ns=received-1000,body_complete_ns=received,path=path,content_type=ctype,body_path=base+".body",body_sha256=control.digest(body),body_bytes=len(body))
        self.emit("http","request_received",received,role="unknown",model="unknown",**facts)
        parsed=dict(facts,role=role,model=control.MODELS[role])
        if role=="asr":
            details,_=control.wav_details(wav);parsed.update(details);parsed["wav_path"]=base+".wav";(self.root/(base+".wav")).write_bytes(wav)
        self.emit("http","request_parsed",received+1000,**parsed)
        self.emit("http","request_mapped",received+2000,request_id=request_id,capture_id=capture_id,capture_index=index,history_id=history_id,pair_index=pair,slot=slot,label=label)
        response={"text":label} if role=="asr" else {"choices":[{"message":{"role":"assistant","content":label if role=="polish" else '{"kind":"no_card"}'}}]}
        response_body=json.dumps(response).encode();response_path="http/responses/"+request_id+".json"
        output=self.root/response_path;output.parent.mkdir(parents=True,exist_ok=True);output.write_bytes(response_body)
        self.emit("http","response_begin",begin,request_id=request_id,status=200,response_path=response_path,response_sha256=control.digest(response_body),response_bytes=len(response_body))
        self.emit("http","response_end",end+1,request_id=request_id,status=200,response_end_ns=end)
        return request_id

    def populate(self):
        core_boot=dict(clock_ticks=self.base,timebase_numer=1,timebase_denom=1,clock_basis="mach_absolute_time",source_sha="b0077c86fe702ef226f04f9b61851759bb29cdcf",carbon_value_seconds=self.base/1000000000,os_calibration_ns=self.base,os_to_mono_offset_ns=0,calibration_before_ns=self.base-1000,calibration_after_ns=self.base+1000,quartz_value_ns=self.base,quartz_before_ns=self.base-1000,quartz_after_ns=self.base+1000,quartz_to_mono_offset_ns=0,quartz_source="synthetic_contract_fixture",process_uptime_seconds=self.base/1000000000,uptime_before_ns=self.base-1000,uptime_after_ns=self.base+1000,calibration_uncertainty_ns=2000,calibration_valid=True)
        self.emit("core","boot",self.base+2000,**core_boot)
        self.emit("app","boot",self.base+2000,source_sha=core_boot["source_sha"],main_limit=3,coach_limit=3,root=str(self.root),local_only=True)
        probe={"python_implementation":"synthetic fixture","platform":"fixture","clock_basis":"non_mach_fixture_only","clock_ticks":self.base,"timebase_numer":1,"timebase_denom":1,"converted_ns":self.base,"clock_before_ns":self.base-1000,"clock_after_ns":self.base+1000,"valid":True}
        self.emit("http","boot",self.base+2000,clock_probe=probe,evidence_origin="synthetic_contract_fixture")
        checkpoint_index=[];document=[];all_entries=[];all_exports=[]
        for pair in range(1,self.pairs+1):
            start=self.base+pair*10000000000;trigger=start+3000000000;t1=trigger+self.latencies[pair-1]
            for pos in range(1,8):
                index=(pair-1)*7+pos
                self.capture(index,trigger if pos==7 else start+pos*100000000,self.latencies[pair-1] if pos==7 else 5000000)
            main_ids=[];coach_ids=[]
            for pos,slot in enumerate(control.SLOTS,1):
                index=(pair-1)*7+pos
                asr_received=start+pos*100000000+10000000 if pos<7 else t1+50000000
                asr_begin=asr_received+1000000 if pos<=3 else (t1+10000000 if slot=="P1" else (t1+300000000 if slot in ("P2","A") else t1+60000000))
                asr_id=self.request(index,"asr",asr_received,asr_begin,asr_begin+1000000)
                if slot in ("P1","P2","A"):main_ids.append(asr_id)
                polish_received=asr_begin+2000000;polish_begin=polish_received+1000000
                self.request(index,"polish",polish_received,polish_begin,polish_begin+1000000)
                coach_received=polish_begin+2000000
                coach_begin=t1+300000000 if pos<=3 else t1+400000000+pos*1000000
                coach_id=self.request(index,"coach",coach_received,coach_begin,coach_begin+1000000)
                if pos<=3:coach_ids.append(coach_id)
                capture_id,history_id,pcm,wav=self.ids[index];label="Native pair %02d %s."%(pair,slot);document.append(label)
                all_entries.append(dict(id=history_id,recordedAt=1000+index,sampleRate=48000,frameCount=4,disposition="completed",recordingOrder=index,rawTranscription=label,polishedText=label,queueStage="completed",delivery="delivered"))
                export_path="exports/"+history_id+".wav";target=self.root/export_path;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(wav)
                details,_=control.wav_details(wav);all_exports.append(dict(history_id=history_id,path=export_path,**details))
            self.emit("http","pair_cue",trigger-100000000,pair_index=pair,main_request_ids=main_ids,coach_request_ids=coach_ids)
            first=next(e for e in self.core if e["event"]=="pcm" and e["capture_id"]==self.ids[pair*7][0])
            self.emit("http","release",t1+1000,pair_index=pair,reason="first_pcm",capture_id=first["capture_id"],pcm_sequence=first["sequence"],first_pcm_ns=t1)
            artifact_path="operator-evidence/queue-%d.txt"%pair;artifact=self.root/artifact_path;artifact.parent.mkdir(parents=True,exist_ok=True);artifact.write_text("synthetic fixture queue observation; not a native screen")
            proof=dict(schema_version=1,run_id=self.run_id,pair_index=pair,history_id=self.ids[pair*7][1],stage="waitingForPredecessor",source="human",observation_started_ns=t1+100000000,observation_finished_ns=t1+110000000,artifact_path=artifact_path,artifact_sha256=control.digest(artifact.read_bytes()))
            self.emit("http","release",t1+120000000,pair_index=pair,reason="operator_b_ready",proof=proof)
            self.emit("http","pair_drained",t1+500000000,pair_index=pair)
            checkpoint_id=str(uuid.uuid4());config=dict(report.DEFAULTS,binding={"fn":{}},gesture="holdToRecord",input_mode="text")
            checkpoint=dict(schema_version=1,run_id=self.run_id,checkpoint_id=checkpoint_id,entries=all_entries[:],queue=[],config=config,exports=all_exports[:])
            path="checkpoints/"+checkpoint_id+".json";control.write_json(self.root/path,checkpoint)
            checkpoint_index.append(dict(pair_index=pair,checkpoint_id=checkpoint_id,path=path,sha256=control.digest((self.root/path).read_bytes())))
            self.emit("app","checkpoint",t1+600000000,checkpoint_id=checkpoint_id,entries=checkpoint["entries"],queue=[],config=config,exports=checkpoint["exports"])
        final=self.base+(self.pairs+1)*10000000000
        close_probe=dict(probe,clock_ticks=final,converted_ns=final,clock_before_ns=final-1000,clock_after_ns=final+1000)
        self.emit("http","server_closed",final,clock_probe=close_probe,failures=[],port=12345)
        # The fixture emits causal events out of lane order; normalize their actual sequence, never their timestamps.
        for lane in ("core","app","http"):
            items=sorted(getattr(self,lane),key=lambda item:item["monotonic_ns"])
            for seq,item in enumerate(items,1):item["sequence"]=seq
            setattr(self,lane,items)
        pcm_sequence={e["capture_id"]:e["sequence"] for e in self.core if e["event"]=="pcm"}
        for e in self.http:
            if e["event"]=="release" and e["reason"]=="first_pcm":e["pcm_sequence"]=pcm_sequence[e["capture_id"]]
        self.flush()
        control.write_json(self.root/"native-ready.json",dict(schema_version=1,run_id=self.run_id,base_url="http://localhost:12345/v1",asr_model=control.MODELS["asr"],polish_model=control.MODELS["polish"],coach_model=control.MODELS["coach"],coach_input_mode="text",pairs=self.pairs,evidence_origin="synthetic_contract_fixture",fake_service_key=control.FAKE_KEY))
        control.write_json(self.root/"operator.json",dict(schema_version=1,run_id=self.run_id,evidence_origin="synthetic_contract_fixture",physical_input=False,source="fixture",os_version="fixture",hardware_model="fixture",architecture="fixture",keyboard="fixture",microphone="fixture",matrix_id="fixture-only",binding="fn",gesture="holdToRecord",document_source="fixture",attestation_source="test_native_contract.py",sleep_or_device_change=False,permissions_authorized_before_sampling=False))
        control.write_json(self.root/"native-checkpoint-index.json",checkpoint_index)
        (self.root/"document-final.txt").write_text("\n".join(document))
        return self

    def flush(self):
        for lane in ("core","app","http"):
            (self.root/("native-"+lane+".jsonl")).write_text("".join(json.dumps(e)+"\n" for e in getattr(self,lane)))


class ReducerContractTests(unittest.TestCase):
    def setUp(self):
        self.directory=tempfile.TemporaryDirectory(prefix="native-reducer-contract-",dir=os.environ.get("NATIVE_KIT_TEST_ROOT"))
        self.root=Path(self.directory.name).resolve()

    def tearDown(self):self.directory.cleanup()

    def fixture(self,latencies=None):return Fixture(self.root,latencies=latencies).populate()

    def test_complete_fixture_validates_algorithm_without_native_pass(self):
        self.fixture();result=report.reduce(self.root)
        self.assertEqual(result["errors"],[]);self.assertEqual(result["verdict"],"FIXTURE_ONLY")
        self.assertEqual(result["native_samples"],0);self.assertEqual(len(result["all_attempts"]),30)
        self.assertEqual(result["diagnostic_only"]["nearest_rank"],29)
        self.assertNotIn("physical_key_to_pcm_p95_ms",result)

    def test_two_slow_pairs_remain_in_p95_and_fail(self):
        self.fixture([150000000]*28+[600000000,600000000]);result=report.reduce(self.root)
        self.assertEqual(len(result["all_attempts"]),30);self.assertEqual(result["diagnostic_only"]["p95_ms"],600)
        self.assertTrue(any("exceeds500ms" in error for error in result["errors"]))

    def test_missing_capture_keeps_attempt_and_fails(self):
        fixture=self.fixture();fixture.core=[e for e in fixture.core if not(e["event"]=="capture_finished" and e["capture_index"]==210)];fixture.flush()
        result=report.reduce(self.root);self.assertEqual(len(result["all_attempts"]),30)
        self.assertTrue(result["errors"]);self.assertNotEqual(result["verdict"],"PASS_NATIVE_CELL")

    def test_changed_source_pcm_bytes_fail_even_with_matching_statuses(self):
        fixture=self.fixture();path=self.root/"captures"/(fixture.ids[210][0]+".pcm16");path.write_bytes(b"\0"*8)
        result=report.reduce(self.root);self.assertTrue(any("source PCM" in error for error in result["errors"]))

    def test_fake_three_pool_metadata_without_real_body_is_rejected(self):
        fixture=self.fixture();request=next(e for e in fixture.http if e["event"]=="request_received")
        (self.root/request["body_path"]).unlink()
        result=report.reduce(self.root);self.assertTrue(any("HTTP" in error for error in result["missing_evidence"]))

    def test_wrong_history_frames_and_document_order_are_rejected(self):
        self.fixture();index=json.loads((self.root/"native-checkpoint-index.json").read_text());path=self.root/index[-1]["path"]
        checkpoint=json.loads(path.read_text());checkpoint["entries"][-1]["frameCount"]=3;control.write_json(path,checkpoint)
        text=(self.root/"document-final.txt").read_text();text=text.replace("Native pair 01 H1.\nNative pair 01 H2.","Native pair 01 H2.\nNative pair 01 H1.")
        (self.root/"document-final.txt").write_text(text)
        result=report.reduce(self.root);self.assertTrue(any("checkpoint" in error for error in result["errors"]))
        self.assertTrue(any("FIFO" in error for error in result["errors"]))

    def test_duplicate_document_fails_despite_completed_history(self):
        self.fixture();path=self.root/"document-final.txt";path.write_text(path.read_text()+"\nNative pair 01 B.")
        result=report.reduce(self.root);self.assertTrue(any("duplicate" in error for error in result["errors"]))

    def test_claimed_native_operator_cannot_upgrade_synthetic_clock_or_unsigned_source(self):
        self.fixture();operator=json.loads((self.root/"operator.json").read_text())
        operator.update(evidence_origin="native_physical",physical_input=True,source="human",os_version="14.7",hardware_model="claimed model",architecture="arm64",document_source="human",permissions_authorized_before_sampling=True)
        control.write_json(self.root/"operator.json",operator);result=report.reduce(self.root)
        self.assertNotEqual(result["verdict"],"PASS_NATIVE_CELL");self.assertEqual(result["native_samples"],0)
        self.assertTrue(any("synthetic Quartz" in reason for reason in result["missing_native_proof"]))
        self.assertTrue(any("sampling package" in reason for reason in result["missing_native_proof"]))

    def test_extra_accepted_down_without_capture_is_not_hidden_by_thirty_successful_pairs(self):
        fixture=self.fixture();when=max(e["monotonic_ns"] for e in fixture.core)+1000000
        fixture.core.append(dict(schema_version=1,run_id=fixture.run_id,event="hotkey",sequence=max(e["sequence"] for e in fixture.core)+1,pid=444,monotonic_ns=when,binding="fn",edge="down",accepted=True,is_repeat=False,os_value=when,os_units="nanoseconds_since_boot",os_ns=when,callback_ns=when))
        fixture.flush();result=report.reduce(self.root)
        self.assertEqual(result["meaningful_start_count"],211)
        self.assertEqual(len(result["all_attempts"]),31)
        self.assertTrue(any("unmatched meaningful" in error for error in result["errors"]))

    def test_independent_nonzero_carbon_offset_is_used_without_fitting_callback_delay(self):
        fixture=self.fixture();offset=-41439
        boot=next(e for e in fixture.core if e["event"]=="boot")
        boot.update(os_calibration_ns=fixture.base-offset,carbon_value_seconds=(fixture.base-offset)/1000000000,os_to_mono_offset_ns=offset)
        for e in fixture.core:
            if e["event"]=="hotkey":e.update(binding="combination",os_units="seconds_since_boot",os_value=(e["os_ns"]-offset)/1000000000)
        for e in fixture.app:
            if e["event"]=="checkpoint":e["config"]["binding"]={"combination":{"_0":{"keyCode":0,"modifiers":{"rawValue":1}}}}
        for item in json.loads((self.root/"native-checkpoint-index.json").read_text()):
            checkpoint=json.loads((self.root/item["path"]).read_text());checkpoint["config"]["binding"]={"combination":{"_0":{"keyCode":0,"modifiers":{"rawValue":1}}}}
            control.write_json(self.root/item["path"],checkpoint);item["sha256"]=control.digest((self.root/item["path"]).read_bytes())
        index=[]
        for e in fixture.app:
            if e["event"]=="checkpoint":
                path="checkpoints/"+e["checkpoint_id"]+".json";index.append(dict(pair_index=len(index)+1,checkpoint_id=e["checkpoint_id"],path=path,sha256=control.digest((self.root/path).read_bytes())))
        control.write_json(self.root/"native-checkpoint-index.json",index)
        operator=json.loads((self.root/"operator.json").read_text());operator["binding"]="combination";control.write_json(self.root/"operator.json",operator)
        fixture.flush();result=report.reduce(self.root)
        self.assertEqual(result["errors"],[]);self.assertEqual(result["verdict"],"FIXTURE_ONLY");self.assertEqual(result["native_samples"],0)

    def test_build_argv_keeps_release_arm64_jobs2_and_conditional_flag(self):
        argv=control.build_command(HERE.parents[1],self.root)
        self.assertEqual(argv,["swift","build","-c","release","--arch","arm64","--jobs","2","--scratch-path",str(self.root/"build"),"-Xswiftc","-DNATIVE_ACCEPTANCE"])
        control.prepare_root(str(self.root))
        developer,verify,scope=control.signing_commands(HERE.parents[1],self.root/"candidate.app","B3882D7FBC455D5A8977445ED5D1470EEABC468D")
        self.assertIn("--timestamp",developer);self.assertEqual(developer[developer.index("--options")+1],"runtime")
        self.assertEqual(verify[2],"signed");self.assertEqual(scope,"developer_id")
        self.assertEqual(control.signing_commands(HERE.parents[1],self.root/"candidate.app","-")[2],"adhoc_fixture_only")
        existing=self.root/"app/Queued Dictation.app";existing.mkdir(parents=True)
        with self.assertRaisesRegex(control.NativeError,"existing App"):
            control.package(type("Args",(),dict(repo=str(HERE.parents[1]),root=str(self.root),sign_identity=None))())


class RealLoopbackContractTests(unittest.TestCase):
    def test_full_real_loopback_holds3_plus3_and_observer_race_before_first_pcm(self):
        directory=tempfile.TemporaryDirectory(prefix="native-loopback-contract-",dir=os.environ.get("NATIVE_KIT_TEST_ROOT"))
        parent=Path(directory.name).resolve();root=parent/"run";log=(parent/"server.log").open("w")
        process=subprocess.Popen([sys.executable,str(HERE/"native-control.py"),"serve","--root",str(root),"--pairs","1","--fixture"],stdout=log,stderr=subprocess.STDOUT)
        executor=concurrent.futures.ThreadPoolExecutor(max_workers=7)
        def wait(predicate,label):
            end=time.monotonic()+5
            while time.monotonic()<end:
                value=predicate()
                if value:return value
                if process.poll() is not None:raise AssertionError("server exited: "+(parent/"server.log").read_text())
                time.sleep(0.01)
            raise AssertionError("bounded wait failed: "+label+"; "+(parent/"server.log").read_text())
        def post(role,index):
            label="Native pair 01 %s."%control.SLOTS[index-1]
            if role=="asr":ctype,body=multipart(fixture.ids[index][3]);path="/audio/transcriptions"
            else:
                ctype="application/json";payload=dict(model=control.MODELS[role],messages=[dict(role="user",content=label)])
                if role=="coach":payload["stream"]=False
                body=json.dumps(payload).encode();path="/chat/completions"
            request=control.urllib.request.Request(ready["base_url"]+path,data=body,headers={"Content-Type":ctype,"Authorization":"Bearer "+control.FAKE_KEY})
            with control.urllib.request.urlopen(request,timeout=5) as response:return json.load(response)
        try:
            wait(lambda:(root/"native-ready.json").is_file(),"ready")
            ready=json.loads((root/"native-ready.json").read_text());fixture=Fixture(root,pairs=1,live=True);fixture.run_id=ready["run_id"]
            held_coach=[]
            for index in (1,2,3):
                # First full body arrives before capture_finished: the controller must wait, never FIFO-guess.
                fixture.capture(index,control.monotonic_ns()-20000000,finish=False)
                future=executor.submit(post,"asr",index)
                wait(lambda:sum(e.get("event")=="request_received" for e in [json.loads(l) for l in (root/"native-http.jsonl").read_text().splitlines()]) >= (index-1)*3+1,"received")
                self.assertFalse(future.done())
                fixture.finish(index,control.monotonic_ns());self.assertIn("Native pair",future.result(timeout=5)["text"])
                post("polish",index);held_coach.append(executor.submit(post,"coach",index))
                wait(lambda:len(control.admin(root)["requests"])>=index*3,"coach registered")
            for index in (4,5,6):fixture.capture(index,control.monotonic_ns()-20000000)
            reordered={index:executor.submit(post,"asr",index) for index in (6,4,5)}
            main=[reordered[index] for index in (4,5,6)]
            wait(lambda:control.admin(root)["pairs"].get("1",{}).get("cue_ns"),"real3/3 cue")
            self.assertTrue(all(not f.done() for f in main+held_coach))
            fixture.capture(7,control.monotonic_ns(),latency=5000000)
            main[0].result(timeout=5);post("polish",4)
            post("asr",7);post("polish",7)
            self.assertFalse(main[1].done());self.assertFalse(main[2].done())
            wait(lambda:any(r.get("slot")=="B" and r.get("role")=="polish" and r.get("response_end_ns") for r in control.admin(root)["requests"]),"server actual B response_end")
            b_id=fixture.ids[7][1];artifact=root/"operator-evidence/queue.txt";artifact.parent.mkdir();artifact.write_text("fixture only, no real queue UI")
            observed=control.monotonic_ns()
            proof=dict(schema_version=1,run_id=ready["run_id"],pair_index=1,history_id=b_id,stage="waitingForPredecessor",source="human",observation_started_ns=observed,observation_finished_ns=observed,artifact_path="operator-evidence/queue.txt",artifact_sha256=control.digest(artifact.read_bytes()))
            control.admin(root,"release-rest",proof)
            for index,future in zip((5,6),main[1:]):future.result(timeout=5);post("polish",index)
            for future in held_coach:future.result(timeout=5)
            for index in (4,5,6,7):self.assertEqual(post("coach",index)["choices"][0]["message"]["content"],'{"kind":"no_card"}')
            wait(lambda:control.admin(root)["pairs"]["1"]["drained"],"21 actual posts drain")
            control.admin(root,"stop",{});self.assertEqual(process.wait(timeout=5),0)
            http=[json.loads(l) for l in (root/"native-http.jsonl").read_text().splitlines()]
            received=[e for e in http if e["event"]=="request_received"]
            self.assertEqual(len(received),21)
            self.assertFalse(any(e["event"]=="control_failure" for e in http))
            cue=next(e for e in http if e["event"]=="pair_cue")
            self.assertEqual(len(cue["main_request_ids"]),3);self.assertEqual(len(cue["coach_request_ids"]),3)
            first_receive=received[0]["body_complete_ns"];finished=next(e for e in fixture.core if e["event"]=="capture_finished")
            mapped=next(e for e in http if e["event"]=="request_mapped")
            self.assertLess(first_receive,finished["monotonic_ns"]);self.assertLessEqual(finished["monotonic_ns"],mapped["monotonic_ns"])
            self.assertEqual(ready["evidence_origin"],"synthetic_contract_fixture")
        finally:
            if process.poll() is None:
                try:control.admin(root,"stop",{})
                except Exception:process.terminate()
                try:process.wait(timeout=5)
                except subprocess.TimeoutExpired:process.kill();process.wait(timeout=5)
            executor.shutdown(wait=True);log.close()
            if os.environ.get("NATIVE_KIT_KEEP_EVIDENCE"):
                destination=Path(os.environ["NATIVE_KIT_KEEP_EVIDENCE"])/"actual-loopback"
                shutil.copytree(parent,destination)
            directory.cleanup()


if __name__=="__main__":unittest.main()
