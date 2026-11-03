"""Source-checkout adapter: existing Topic Engine -> existing Topic review v1."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import time
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from seminartext_modules import human_review_workflow as review
from seminartext_modules import seminartext_topics as engine
from seminartext_modules.owned_tmp import OwnedWorkspace
from seminartext_modules.reviewed_knowledge_admission import persist_revision

MODEL = "gemma3:4b"
ENGINE_HASH = "d8a14e83b877024c3e016a33e594af17d512741a77735ff3d8c7d1262628c8db"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(value):
    return hashlib.sha256(value).hexdigest()


def json_bytes(value):
    return review.canonical_bytes(value)


def read(path):
    return json.loads(Path(path).read_bytes())


def write(path, value):
    persist_revision(path, value)


def context(project, source_id, revision_id, source):
    bundle, evidence_hash = review.load_evidence(project)
    src = next((s for s in bundle['sources'] if s['id'] == source_id), None)
    revision = next((r for r in bundle['transcript_revisions'] if r['id'] == revision_id), None)
    require(src and src['kind'] in {'video', 'audio'}, 'audio/video source required')
    require(revision and revision['source_id'] == source_id, 'source/revision mismatch')
    with source.open('rb') as stream:
        source_hash = hashlib.file_digest(stream, 'sha256').hexdigest()
    require(source_hash == src['content_sha256'], 'source bytes changed')
    words = sorted((w for w in bundle['words'] if w['transcript_revision_id'] == revision_id), key=lambda w: w['sequence'])
    require(words and all(w['start_seconds'] is not None and w['end_seconds'] is not None for w in words),
            'exact timed Words required; cue-only/unaligned input unsupported')
    require(digest(Path(engine.__file__).read_bytes()) == ENGINE_HASH, 'engine implementation differs from governed identity')
    binding = dict(project=str(project.resolve()), source=str(source.resolve()), source_id=source_id,
                   revision_id=revision_id, evidence_sha256=evidence_hash, source_sha256=source_hash,
                   engine_sha256=ENGINE_HASH, contract='seminartext.topic_drafts:1.0.0', detail='auto')
    # Preserve the existing engine's cue granularity, with exact Word endpoints.
    # This is an input view, never persisted as BenchmarkSegments.
    binding['input_view'] = 'EXACT_CUE_WORD_PARTITION_V1'
    def clock(seconds):
        ms = round(seconds * 1000)
        return f'{ms//3600000:02}:{ms//60000%60:02}:{ms//1000%60:02},{ms%1000:03}'
    cues = sorted((c for c in bundle['cues'] if c['transcript_revision_id'] == revision_id), key=lambda c:c['sequence'])
    items, covered = [], []
    for cue in cues:
        selected = [i for i,w in enumerate(words) if w['char_start'] >= cue['char_start'] and w['char_end'] <= cue['char_end']]
        require(selected and words[selected[0]]['char_start'] == cue['char_start'] and
                words[selected[-1]]['char_end'] == cue['char_end'], 'cue cannot map exactly to Word endpoints')
        covered.extend(selected)
        items.append(dict(id=len(items)+1, start=clock(words[selected[0]]['start_seconds']),
                          end=clock(words[selected[-1]]['end_seconds']), text=revision['canonical_text'][cue['char_start']:cue['char_end']],
                          word_start=selected[0], word_end=selected[-1]))
    require(covered == list(range(len(words))), 'cues must partition the selected timed Words exactly')
    return bundle, words, items, binding


def generate(items, run):
    deadline = time.monotonic()+295
    write(run/'attempt.json', dict(model=MODEL, inference_may_have_started=True))
    tags = read_url('http://127.0.0.1:11434/api/tags')
    model = next((m for m in tags['models'] if m['name'] == MODEL), None)
    require(model and model.get('digest'), 'existing gemma3:4b unavailable; no download attempted')
    original = urllib.request.urlopen
    calls, errors = [], []

    def capture(request, timeout=900):
        payload = json.loads(request.data)
        try:
            require(time.monotonic() < deadline, 'generation budget exhausted')
            with original(request, timeout=min(timeout, max(1, deadline-time.monotonic()))) as response:
                raw = response.read()
            entry = dict(request=payload, response_utf8=raw.decode('utf-8'))
            calls.append(entry)
            write(run/f'call_{len(calls):04}.json', entry)
            outer = json.loads(raw)
            content = json.loads(outer['message']['content'])
            from jsonschema import Draft202012Validator
            Draft202012Validator(payload['format']).validate(content)
            if 'boundaries' in content:
                require(len(content['boundaries']) == len(set(content['boundaries'])), 'duplicate boundaries')
            return io.BytesIO(raw)
        except Exception as exc:
            errors.append(str(exc))
            raise

    urllib.request.urlopen = capture
    try:
        rows, fallbacks = [], []
        for window in engine.make_windows(items):
            boundaries = engine.analyze_window_boundaries(window, detail='auto', model=MODEL)
            require(not errors, 'producer failed; boundary fallback discarded: '+str(errors))
            require(boundaries and boundaries[0] == window[0]['id'], 'incomplete boundaries')
            for i, start in enumerate(boundaries):
                end = boundaries[i+1]-1 if i+1 < len(boundaries) else window[-1]['id']
                part = [item for item in window if start <= item['id'] <= end]
                try:
                    rows.append(engine.run_ollama_topic_label(MODEL, engine.topic_range_prompt(part), start, end))
                except Exception as exc:
                    # Existing engine fallback: a visible review warning, never
                    # a successful model-derived semantic assertion.
                    message = str(exc)
                    fallbacks.append(dict(start_id=start, end_id=end, error=message))
                    rows.append(dict(start_id=start, title='Тема требует ручной проверки', summary='',
                                     evidence_start_id=start, evidence_end_id=end,
                                     qa_status='fallback', qa_attempt='2stage-fallback'))
        require(rows and calls and not errors, 'empty/failed producer output')
        require(read_url('http://127.0.0.1:11434/api/tags', opener=original)['models'] == tags['models'],
                'model inventory changed during generation')
        return dict(model=MODEL, model_digest=model['digest'], rows=rows, fallbacks=fallbacks,
                    calls={f'call_{i+1:04}.json': digest(json_bytes(c)) for i, c in enumerate(calls)})
    finally:
        urllib.request.urlopen = original


def read_url(url, opener=None):
    with (opener or urllib.request.urlopen)(url, timeout=3) as response:
        return json.load(response)


def drafts_for(bundle, words, binding, response, items):
    key = digest(json_bytes(dict(binding=binding, response=response)))
    seminar_id = 'seminar_'+digest(bundle['project']['id'].encode())
    topics, evidence = [], []
    expected = 1
    for number, row in enumerate(response['rows']):
        start, end = row['start_id'], row['evidence_end_id']
        require(type(start) is int and type(end) is int and start == expected and start <= end <= len(items),
                'unknown, duplicate, overlapping or incomplete source range')
        require(row['qa_status'] in {'ok','fallback'} and engine.title_is_good(row['title']) and engine.summary_is_good(row['summary']),
                'malformed label cannot become a review draft')
        ref = dict(source_id=binding['source_id'], transcript_revision_id=binding['revision_id'],
                   word_start_id=words[items[start-1]['word_start']]['id'], word_end_id=words[items[end-1]['word_end']]['id'])
        eid = f'evidence_{key}_{number}'
        evidence.append(dict(id=eid, claim='Machine-proposed Topic range; semantic review required.', **ref))
        topics.append(dict(id=f'topic_{key}_{number}', seminar_id=seminar_id, topic_set_id='topic_set_'+key,
                           sequence=number, proposed_title=row['title'], proposed_summary=row['summary'],
                           evidence_refs=[eid], semantic_origin='machine_assisted', lifecycle_status='REVIEW_REQUIRED', **ref))
        expected = end+1
    require(topics and expected == len(items)+1, 'empty or incomplete producer coverage')
    return dict(schema_version='1.0.0', artifact_type='seminartext.topic_drafts', artifact_id='drafts_'+key,
                project={k:bundle['project'][k] for k in ('id','title')}, seminar=dict(id=seminar_id, title=bundle['project']['title']),
                generator=dict(id='legacy_ollama_gemma_runtime', version='1.0.0', configuration_sha256=digest(json_bytes(dict(binding=binding, model=response['model'], model_digest=response['model_digest'])))),
                topics=topics, evidence=evidence)


@contextmanager
def lock(run):
    require(not any(p.is_symlink() for p in (run, *run.parents)), 'symlink output unsupported')
    run.mkdir(parents=True, exist_ok=True)
    fd = os.open(run/'.lock', os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX|fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)


def execute(args):
    run = args.run.absolute()
    if args.command == 'generate':
        project, source = args.project.resolve(), args.source.resolve()
        bundle, words, items, binding = context(project, args.source_id, args.revision_id, source)
    else:
        binding = read(run/'binding.json')
        project, source = Path(binding['project']), Path(binding['source'])
        bundle, words, items, current = context(project, binding['source_id'], binding['revision_id'], source)
        require(current == binding, 'stale input binding')
    with lock(run):
        write(run/'binding.json', binding)
        if args.command == 'generate' and not (run/'response.json').exists():
            require(not (run/'attempt.json').exists(), 'interrupted/failed generation: use a new explicit run directory; inference is never silently repeated')
            def expired(*_):
                raise TimeoutError('source generation budget exhausted (300s)')
            old = signal.signal(signal.SIGALRM, expired)
            signal.alarm(300)
            try:
                response = generate(items, run)
                write(run/'response.json', response)
            except Exception as exc:
                write(run/'failure.json', dict(status='FAILED', error=str(exc)))
                raise
            finally:
                signal.alarm(0)
                signal.signal(signal.SIGALRM, old)
        if not (run/'response.json').exists() and (run/'failure.json').exists():
            raise ValueError('FAILED: '+read(run/'failure.json')['error'])
        require((run/'response.json').exists(), 'INTERRUPTED/INCOMPLETE: no committed producer response')
        response = read(run/'response.json')
        for name, expected in response['calls'].items():
            require(Path(name).name == name and name.startswith('call_'), 'invalid call locator')
            require(digest((run/name).read_bytes()) == expected, 'stored response call hash changed')
        drafts = drafts_for(bundle, words, binding, response, items)
        if args.command in {'generate', 'replay'}:
            write(run/'drafts.json', drafts)
            with OwnedWorkspace() as tmp:
                prepared = tmp/'review'
                review.prepare(project, run/'drafts.json', prepared)
                for path in prepared.iterdir():
                    destination = run/path.name
                    payload = path.read_bytes()
                    if destination.exists():
                        require(destination.read_bytes() == payload, 'immutable review artifact changed')
                    else:
                        with tempfile.NamedTemporaryFile(dir=run) as staged:
                            staged.write(payload); staged.flush(); os.fsync(staged.fileno())
                            os.link(staged.name, destination)
            # Recheck current inputs before publishing success.
            require(context(project, binding['source_id'], binding['revision_id'], source)[3] == binding, 'inputs changed during generation')
            write(run/'receipt.json', dict(binding=binding, hashes={p.name:digest(p.read_bytes()) for p in run.iterdir()
                  if p.name in {'response.json','drafts.json','review_package.json','REVIEW.md','review_decisions.template.json'}}))
        receipt = read(run/'receipt.json')
        require(receipt['binding'] == binding, 'receipt binding changed')
        require(set(receipt['hashes']) == {'response.json','drafts.json','review_package.json','REVIEW.md','review_decisions.template.json'},
                'incomplete receipt')
        for name, expected in receipt['hashes'].items():
            require(Path(name).name == name and digest((run/name).read_bytes()) == expected, 'committed artifact changed')
        require(read(run/'drafts.json') == drafts, 'stored draft differs from producer response')
        review.load_package(project, run/'review_package.json')
        if args.command == 'inspect':
            print((run/'REVIEW.md').read_text(), end='')
        else:
            print(json.dumps(dict(status='REVIEW_REQUIRED', topics=len(drafts['topics']), decisions=0,
                                  fallback_count=len(response.get('fallbacks', [])),
                                  package=str(run/'review_package.json'), model_digest=response['model_digest'])))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subs = parser.add_subparsers(dest='command', required=True)
    for name in ['generate','replay','status','inspect']:
        sub = subs.add_parser(name)
        sub.add_argument('run', type=Path)
        if name == 'generate':
            sub.add_argument('project', type=Path)
            for flag in ['source-id','revision-id','source']:
                sub.add_argument('--'+flag, required=True, type=Path if flag == 'source' else str)
    try:
        execute(parser.parse_args())
    except (ValueError, OSError, KeyError, TypeError) as exc:
        print(json.dumps(dict(status='INVALID_OR_UNAVAILABLE', error=str(exc))), file=sys.stderr)
        raise SystemExit(1)


if __name__ == '__main__':
    main()
