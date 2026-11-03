"""Explicit selected media -> existing ASR/alignment/Evidence/Topic review.

All machine output remains REVIEW_REQUIRED. No semantic decisions are made.
"""
from __future__ import annotations

import argparse
from contextlib import ExitStack, redirect_stdout
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from seminartext_modules import human_review_workflow as review
from seminartext_modules import batch_topic_review as batch
from seminartext_modules import evidence_foundation as foundation
from seminartext_modules import media_alignment as alignment
from seminartext_modules import asr_completion
from seminartext_modules.reviewed_knowledge_admission import persist_revision

ROOT = Path(__file__).resolve().parents[1]
ARTIFACT = 'seminartext.media_to_review_manifest'
STATE = 'seminartext.media_to_review_state'
VERSION = '1.0.0'
NAME = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]*$')
MEDIA = {'.wav', '.mp3', '.m4a', '.mp4', '.mov', '.mkv'}


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(path):
    return alignment.sha(path)


def load(path):
    return json.loads(Path(path).read_bytes())


def manifest(path):
    path = Path(path).absolute()
    require(path.is_file() and not path.is_symlink(), 'manifest unavailable')
    data = load(path)
    require(set(data) == {'artifact_type', 'schema_version', 'entries'}, 'unsupported manifest fields')
    require(data['artifact_type'] == ARTIFACT and data['schema_version'] == VERSION, 'unsupported manifest contract')
    require(isinstance(data['entries'], list) and data['entries'], 'manifest entries required')
    expected = {'id', 'project', 'source_id', 'media'}
    seen, sources, entries = set(), set(), []
    for row in data['entries']:
        require(isinstance(row, dict) and set(row) == expected, 'unsupported entry fields')
        require(all(isinstance(row[k], str) and row[k] for k in expected), 'empty manifest field')
        require(NAME.fullmatch(row['id']) and row['id'] not in seen, 'invalid or duplicate entry id')
        require(NAME.fullmatch(row['source_id']), 'invalid source id')
        project, media = Path(row['project']), Path(row['media'])
        require(project.is_absolute() and project.is_dir() and not project.is_symlink(), 'project unavailable')
        require(media.is_absolute() and media.is_file() and not media.is_symlink() and media.suffix.lower() in MEDIA, 'unsupported or unavailable media')
        source_key = (str(project.resolve()), row['source_id'])
        require(source_key not in sources, 'duplicate selected source')
        seen.add(row['id']); sources.add(source_key)
        entries.append({**row, 'project': str(project.resolve()), 'media': str(media.resolve()), 'media_sha256': digest(media)})
    return path.resolve(), entries


def selected_sources(entries):
    for entry in entries:
        project = Path(entry['project'])
        source, _ = foundation.source_record(project, entry['source_id'])
        require(source.get('type') == 'local', 'only explicitly registered local media supported')
        require(foundation.media_path(project, source, None) == Path(entry['media']), 'selected media differs from registered source')


def prerequisites():
    return {'whisper_cli': shutil.which('whisper-cli') is not None,
            'ffmpeg': shutil.which('ffmpeg') is not None, 'ffprobe': shutil.which('ffprobe') is not None,
            'whisperx_3_8_6': True, 'alignment': alignment.discover()}


def write_state(directory, state):
    directory = Path(directory); directory.mkdir(parents=True, exist_ok=True)
    return batch._write_state(directory, state)


def latest(directory):
    _, state = batch._snapshots(directory)
    require(state.get('artifact_type') == STATE and state.get('schema_version') == VERSION, 'invalid intake state')
    return state


def _current(state):
    path, entries = manifest(state['manifest'])
    require(digest(path) == state['manifest_sha256'], 'manifest changed after preparation')
    require([{k:e[k] for k in entries[0]} for e in state['entries']] == entries, 'selected media changed')
    selected_sources(entries)
    for project, expected in state['registries'].items():
        require(digest(Path(project)/'sources.json') == expected, 'source registry changed')
    for entry in state['entries']:
        for stage,receipt in entry.get('receipts', {}).items():
            # State retains exact stage receipt content; output bytes are checked below.
            for path, expected in receipt['hashes'].items():
                require(Path(path).is_file() and digest(path) == expected, 'completed artifact changed: '+path)
    return entries


def prepare(directory, source_manifest):
    source_manifest, entries = manifest(source_manifest)
    selected_sources(entries)
    with batch.lock(directory):
        if list(Path(directory).glob('state-*.json')):
            state = latest(directory); _current(state)
            require(state['manifest'] == str(source_manifest), 'different prepared manifest')
            return state
        state = {'artifact_type': STATE, 'schema_version': VERSION, 'manifest': str(source_manifest),
                 'manifest_sha256': digest(source_manifest), 'status': 'PENDING',
                 'registries': {e['project']:digest(Path(e['project'])/'sources.json') for e in entries},
                 'entries': [{**entry, 'status': 'PENDING', 'receipts': {}, 'attempt': 0} for entry in entries]}
        return write_state(directory, state)


def _receipt(paths, **extra):
    return dict(hashes={str(Path(p).resolve()):digest(p) for p in paths}, **extra)


def _save_receipt(directory, entry, stage, receipt):
    path = Path(directory)/'entries'/entry['id']/f'{stage}.json'
    persist_revision(path, receipt)
    entry['receipts'][stage] = receipt
    return receipt


def _retained(directory, entry, stage):
    path = Path(directory)/'entries'/entry['id']/f'{stage}.json'
    if not path.exists():
        return None
    receipt = load(path)
    require(stage not in entry.get('receipts',{}) or receipt == entry['receipts'][stage], 'stage receipt changed')
    for p, expected in receipt['hashes'].items():
        require(Path(p).is_file() and digest(p) == expected, 'retained artifact changed')
    entry['receipts'][stage] = receipt
    return receipt


def transcribe(entry, work):
    project = Path(entry['project'])
    env = {**os.environ, 'SEMINARTEXT_HEADLESS':'1', 'PYTHONDONTWRITEBYTECODE':'1'}
    with (work/'asr.log').open('wb') as log:
        result = subprocess.run([str(ROOT/'seminartext'), 'project-transcribe', str(project), '--only', entry['source_id'], '--no-open'],
                                env=env, stdout=log, stderr=subprocess.STDOUT, timeout=900)
    require(result.returncode == 0, 'ASR_EXECUTION_FAILURE: see '+str(work/'asr.log'))
    output = project/'transcript'/entry['source_id']
    paths = [output/'transcript.txt', output/'transcript.srt']
    require(all(p.is_file() for p in paths), 'ASR completion lacks transcript/SRT')
    completion = output/asr_completion.IDENTITY_NAME
    identity = load(completion)
    configuration = identity['configuration']
    for key in ('whisper_model','vad_model','whisper_runtime','producer'):
        record = configuration[key]
        require(digest(record['path']) == record['sha256'], 'ASR runtime/model identity changed')
        paths.append(Path(record['path']))
    paths.append(completion)
    return _receipt(paths, configuration_env=_asr_environment(), completion=str(completion))


def _asr_environment():
    names = ['PATH', 'SEMINARTEXT_MODEL','SEMINARTEXT_VAD_MODEL','SEMINARTEXT_CHUNK_SECONDS','SEMINARTEXT_WHISPER_THREADS','SEMINARTEXT_PYTHON']
    return {**{key:os.environ.get(key) for key in names}, 'core_executable':str(Path(sys.executable).resolve()), 'core_sha256':digest(sys.executable), 'core_version':sys.version}


def _asr(directory, state, entry):
    retained = _retained(directory, entry, 'asr')
    if retained:
        require(retained.get('configuration_env') == _asr_environment(), 'ASR configuration environment changed')
        identity = load(retained['completion'])
        selected = shutil.which('whisper-cli')
        configuration = identity['configuration']
        if configuration:
            require(selected and Path(selected).resolve() == Path(configuration['whisper_runtime']['path']).resolve(), 'ASR runtime selection changed')
        ok, reason = asr_completion.verify_completion(entry['project'],entry['source_id'],identity['source'],identity['configuration'])
        require(ok, 'retained ASR completion invalid: '+reason)
        return retained
    work = Path(directory)/'entries'/entry['id']; work.mkdir(parents=True, exist_ok=True)
    marker = work/'asr-attempt.json'
    # Existing project-transcribe verifies its accepted completion binding before reuse.
    # On an interrupted attempt it owns recovery; do not bypass that contract.
    if marker.exists():
        completion=Path(entry['project'])/'transcript'/entry['source_id']/asr_completion.IDENTITY_NAME
        require(completion.is_file() or entry['attempt']>0,'interrupted ASR: explicit retry required')
    else:
        persist_revision(marker, {'source_sha256':entry['media_sha256']})
    receipt = transcribe(entry, work)
    return _save_receipt(directory, entry, 'asr', receipt)


def _validate_raw(raw, media, segments, identity):
    require(raw.get('artifact_type')=='issue_38_whisperx_existing_transcript_alignment' and
            raw.get('schema_version')==1 and raw.get('invocation_role')=='alignment_only_no_asr',
            'unsupported historical alignment producer contract')
    require(raw.get('input',{}).get('audio_sha256')==digest(media) and
            raw.get('input',{}).get('segments_sha256')==digest(segments),'alignment raw input identity changed')
    environment=raw.get('environment',{})
    expected=identity['runtime']
    require(environment.get('python')==expected['python'] and
            all(environment.get(name)==expected['packages'][name] for name in ('whisperx','torch','torchaudio','transformers')),
            'alignment raw runtime identity changed')
    require(len(raw.get('runs',[]))==1,'alignment raw must contain exactly one native run')
    run=raw['runs'][0]
    canonical=json.dumps(run['result'],ensure_ascii=False,sort_keys=True,separators=(',',':')).encode('utf-8')
    require(run.get('canonical_result_sha256')==hashlib.sha256(canonical).hexdigest(),'alignment raw native result hash changed')


def _align(directory, state, entry, runtime):
    retained = _retained(directory, entry, 'alignment')
    if retained:
        require(retained['identity'] == runtime, 'alignment runtime/configuration changed')
        return retained
    work = Path(directory)/'entries'/entry['id']/f"alignment-{entry['attempt']}"
    work.mkdir(parents=True, exist_ok=True)
    srt = Path(entry['project'])/'transcript'/entry['source_id']/'transcript.srt'
    cues = alignment.parse_srt(srt)
    segments = work/'segments.json'; persist_revision(segments, {'segments':cues})
    # A committed, identity-matching raw result survives a receipt-publication crash.
    compatible=[]
    for candidate in sorted(work.parent.glob('alignment-*/raw.json')):
        parent=candidate.parent
        marker_path=parent/'attempt.json'
        if not marker_path.exists():
            continue
        marker_value=load(marker_path)
        if marker_value != {'identity':runtime,'segments_sha256':digest(segments),'media_sha256':entry['media_sha256']}:
            continue
        try:
            payload=load(candidate)
            _validate_raw(payload,entry['media'],parent/'segments.json',runtime)
        except (ValueError,OSError,KeyError):
            continue
        compatible.append(candidate)
    require(len(compatible)<=1,'ambiguous committed alignment results')
    if compatible:
        work=compatible[0].parent; segments=work/'segments.json'
    raw = work/'raw.json'
    marker = work/'attempt.json'
    if not raw.exists():
        require(not marker.exists(), 'interrupted alignment: explicit retry required')
        persist_revision(marker, {'identity':runtime, 'segments_sha256':digest(segments), 'media_sha256':entry['media_sha256']})
        alignment.produce(Path(entry['media']), segments, raw, runtime, work/'producer.log')
    require(load(marker) == {'identity':runtime, 'segments_sha256':digest(segments), 'media_sha256':entry['media_sha256']}, 'retained alignment binding changed')
    raw_payload=load(raw)
    _validate_raw(raw_payload,entry['media'],segments,runtime)
    payload = alignment.project_output(raw_payload, cues, runtime, entry['media'], srt)
    projected = work/'alignment.json'; persist_revision(projected, payload)
    text = work/'transcript.txt'
    text_value = srt.with_name('transcript.txt').read_text(encoding='utf-8')
    if not text.exists():
        text.write_text(text_value, encoding='utf-8')
    require(text.read_text() == text_value, 'retained transcript projection changed')
    return _save_receipt(directory, entry, 'alignment', _receipt([segments, raw, projected, text], identity=runtime,
                         alignment_json=str(projected), text_file=str(text)))


def _evidence(directory, state, entry):
    retained = _retained(directory, entry, 'evidence')
    if retained:
        return retained
    aligned = entry['receipts']['alignment']
    project = Path(entry['project'])
    method = 'project_media_review:'+hashlib.sha256(review.canonical_bytes({k:entry[k] for k in ('project','source_id','media_sha256')})).hexdigest()
    # Recover the immutable revision even if interrupted after its commit.
    revisions = list((project/'evidence/transcript_revisions').glob('transcript_revision_*.json'))
    matches = [load(p) for p in revisions if load(p).get('transcript_provenance',{}).get('method') == method]
    require(len(matches) <= 1, 'ambiguous retained transcript revision')
    with redirect_stdout(io.StringIO()):
        if matches:
            revision_id = matches[0]['revision_id']
            require(matches[0]['canonical_text'] == Path(aligned['text_file']).read_text(), 'retained transcript changed')
        else:
            stream = io.StringIO()
            with redirect_stdout(stream):
                foundation.promote_transcript(argparse.Namespace(project=str(project), source_id=entry['source_id'], text_file=aligned['text_file'],
                    state='review_required', reviewer=None, parent_revision_id=None, verification_state='machine_unverified', verified_range=[], generation_method=method))
            revision_id = json.loads(stream.getvalue())['revision_id']
        foundation.align_project(argparse.Namespace(project=str(project), source_id=entry['source_id'], revision_id=revision_id,
                                 media=entry['media'], alignment_json=aligned['alignment_json']))
    source_id = foundation.stable_id(entry['source_id'], 'source')
    path = project/'evidence/sources'/source_id/'revisions'/revision_id/'canonical_bundle.json'
    return _save_receipt(directory, entry, 'evidence', _receipt([path, project/'evidence/transcript_revisions'/f'{revision_id}.json'],
                         revision_id=revision_id, source_id=source_id))


def run(directory, retry=None):
    directory = Path(directory).absolute()
    with batch.lock(directory), ExitStack() as locks:
        state = latest(directory); entries = _current(state)
        for project in sorted(state['registries']):
            locks.enter_context(batch.lock(Path(project)/'evidence/media_review_lock'))
        try:
            available = prerequisites()
            if not all(available.get(k) for k in ('whisper_cli','ffmpeg','whisperx_3_8_6')):
                state['prerequisites'] = available; state['status'] = 'ALIGNMENT_UNAVAILABLE'
                for entry in state['entries']: entry['status'] = 'ALIGNMENT_UNAVAILABLE'
                return write_state(directory, state)
            if state.get('status') == 'REVIEW_REQUIRED':
                for entry in state['entries']:
                    _asr(directory,state,entry)
                return status(directory)
            runtime = available['alignment']
            changed_runtime = state.get('runtime') and state['runtime'] != runtime
            require(not changed_runtime or (retry and all('alignment' not in e['receipts'] for e in state['entries'])), 'alignment runtime/configuration changed; new intake required')
            state['runtime'] = runtime
            if retry:
                entry = next((e for e in state['entries'] if e['id'] == retry), None)
                require(entry is not None and entry['status'] == 'FAILED', 'retry requires an explicitly failed entry')
                entry['status'] = 'PENDING'; entry['attempt'] += 1; entry.pop('failure',None)
                state = write_state(directory, state)
            for entry in state['entries']:
                if entry['status'] in {'FAILED','REVIEW_REQUIRED'}:
                    continue
                try:
                    _asr(directory, state, entry)
                    entry['status'] = 'ASR_COMPLETE'; write_state(directory, state)
                    _align(directory, state, entry, runtime)
                    entry['status'] = 'ALIGNMENT_COMPLETE'; write_state(directory, state)
                    _evidence(directory, state, entry)
                    entry['status'] = 'EVIDENCE_COMPLETE'; write_state(directory, state)
                except (ValueError, OSError, subprocess.SubprocessError) as exc:
                    entry['status'] = 'FAILED'; entry['failure'] = {'code':getattr(exc,'code','EXECUTION_FAILURE'), 'message':str(exc)}
                    write_state(directory, state)
            require(all('evidence' in e['receipts'] for e in state['entries']), 'one or more entries failed; inspect and explicit retry required')
            # Compose every selected source before freezing any Topic batch binding.
            for project in state['registries']:
                foundation.write_project_aggregate(Path(project))
            selected = [e for e in state['entries'] if e['status']=='EVIDENCE_COMPLETE']
            require(selected,'one or more entries failed; explicit retry required')
            attempt = max(e['attempt'] for e in selected)
            selection_key=hashlib.sha256(review.canonical_bytes([(e['id'],e['attempt']) for e in selected])).hexdigest()[:12]
            suffix = '' if attempt == 0 else f'-retry-{attempt}-{selection_key}'
            topic_manifest = directory/f'topic-manifest{suffix}.json'
            values = [{'id':e['id'], 'project':e['project'], 'source':e['media'],
                       'source_id':e['receipts']['evidence']['source_id'], 'revision_id':e['receipts']['evidence']['revision_id'],
                       'run_directory':e['id']} for e in selected]
            persist_revision(topic_manifest, {'artifact_type':batch.MANIFEST_ARTIFACT,'schema_version':batch.VERSION,'entries':values})
            review_dir = directory/f'topic-review{suffix}'
            batch.prepare(review_dir, topic_manifest)
            result, _ = batch.run(review_dir)
            for entry, child in zip(selected,result['entries']):
                require(entry['id']==child['id'],'Topic result entry identity differs')
                entry['topic_batch']=str(review_dir)
                entry['topic_manifest']=str(topic_manifest)
                entry['topic_manifest_sha256']=digest(topic_manifest)
                entry['status']=child['status']
                if child['status']=='FAILED':
                    entry['failure']={'code':'TOPIC_EXECUTION_FAILURE','message':child['result']['error']}
            state['topic_review'] = str(review_dir)
            state['topic_manifest_sha256'] = digest(topic_manifest)
            write_state(directory,state)
            require(all(e['status']=='REVIEW_REQUIRED' for e in state['entries']), 'Topic batch failed; retained response is not silently retried')
            state['status'] = 'REVIEW_REQUIRED'
            return write_state(directory, state)
        except alignment.Unavailable as exc:
            state['status'] = exc.code; state['failure'] = str(exc)
            return write_state(directory,state)
        except (ValueError,OSError,subprocess.SubprocessError) as exc:
            state['status'] = 'FAILED'; state['failure'] = str(exc)
            write_state(directory,state)
            raise


def status(directory):
    state = latest(directory); _current(state)
    for entry in state['entries']:
        for stage,receipt in entry.get('receipts',{}).items():
            path=Path(directory)/'entries'/entry['id']/f'{stage}.json'
            require(path.is_file() and load(path)==receipt,'stage receipt changed')
        if 'asr' in entry.get('receipts',{}):
            require(entry['receipts']['asr'].get('configuration_env')==_asr_environment(),'ASR configuration environment changed')
    if state.get('runtime'):
        require(alignment.discover() == state['runtime'], 'alignment runtime/configuration changed')
    if state.get('status') == 'REVIEW_REQUIRED':
        for entry in state['entries']:
            topic_manifest=entry.get('topic_manifest',str(Path(directory)/'topic-manifest.json'))
            require(digest(topic_manifest)==entry.get('topic_manifest_sha256',state['topic_manifest_sha256']),'Topic manifest changed')
        for topic_batch in {e.get('topic_batch',state['topic_review']) for e in state['entries']}:
            batch.status(topic_batch)
    return state


def execute(args):
    if args.command == 'prepare':
        state = prepare(args.directory,args.manifest)
    elif args.command in {'run','resume','retry'}:
        state = run(args.directory, getattr(args,'entry',None))
    else:
        state = status(args.directory)
    if args.command == 'inspect':
        print('# Обработка медиа\n\n'+state.get('status','PENDING')+' '+state.get('failure','')+'\n\n'+'\n'.join(f"- {e['id']}: {e['status']} {e.get('failure',{}).get('message','')}" for e in state['entries']))
    else:
        print(json.dumps(state, ensure_ascii=False))
    return 0 if state.get('status') in {'PENDING','REVIEW_REQUIRED'} else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__); subs = parser.add_subparsers(dest='command',required=True)
    for command in ('prepare','run','resume','status','inspect','retry'):
        sub = subs.add_parser(command); sub.add_argument('directory',type=Path)
        if command == 'prepare': sub.add_argument('--manifest',required=True,type=Path)
        if command == 'retry': sub.add_argument('--entry',required=True)
    try:
        raise SystemExit(execute(parser.parse_args()))
    except (ValueError,OSError,KeyError,TypeError,json.JSONDecodeError,subprocess.SubprocessError) as exc:
        print(json.dumps({'status':'INVALID_OR_UNAVAILABLE','error':str(exc)},ensure_ascii=False),file=sys.stderr)
        raise SystemExit(1)


if __name__ == '__main__':
    main()
