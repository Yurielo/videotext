"""Thin offline/runtime and I/O adapter for the accepted Issue #38 producer.

The historical producer remains byte-identical. Its model loader is bound to
an already validated local snapshot; no alignment or token timing algorithm is
implemented here.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import re
import runpy
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PRODUCER = ROOT / 'analysis/word_alignment_decision/run_whisperx_existing_text.py'
MODEL = 'jonatasgrosman/wav2vec2-large-xlsr-53-russian'
REVISION = '2329100508896c6d9b157019803ab5601e6f3406'
WEIGHTS = 'd1cdb1a7921de7d363f967a9b0101a713602e109dba62b6f3f9ae2e0b2df0c1c'


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


class Unavailable(ValueError):
    def __init__(self, code, message):
        self.code = code
        super().__init__(message)


def offline_environment():
    return {**os.environ, 'HF_HUB_OFFLINE': '1', 'TRANSFORMERS_OFFLINE': '1',
            'HF_HUB_DISABLE_TELEMETRY': '1', 'PYTHONDONTWRITEBYTECODE': '1',
            'OMP_NUM_THREADS': '2', 'MKL_NUM_THREADS': '2', 'TOKENIZERS_PARALLELISM': 'false'}


def discover():
    executable = Path(os.environ.get('SEMINARTEXT_ALIGNMENT_PYTHON', str(Path.home()/'.seminartext-alignment-venv/bin/python'))).expanduser().absolute()
    if not executable.is_file():
        raise Unavailable('ALIGNMENT_RUNTIME_ABSENT', str(executable))
    code = '''import importlib.metadata as m,sys,json,platform
names=json.loads(sys.argv[1]);print(json.dumps(dict(python=platform.python_version(),implementation=platform.python_implementation(),platform=platform.platform(),executable=sys.executable,real_executable=__import__('os').path.realpath(sys.executable),packages={n:m.version(n) for n in names})))'''
    pins = dict(line.strip().split('==') for line in (ROOT/'requirements-alignment.txt').read_text().splitlines() if '==' in line and not line.startswith('#'))
    result = subprocess.run([str(executable), '-I', '-B', '-c', code, json.dumps(list(pins))], capture_output=True, text=True, timeout=30, env=offline_environment())
    try:
        identity = json.loads(result.stdout)
        if result.returncode or identity['python'] != '3.13.15' or identity['implementation'] != 'CPython' or identity['packages'] != pins:
            raise ValueError('accepted alignment profile mismatch')
    except (ValueError, KeyError) as exc:
        raise Unavailable('ALIGNMENT_RUNTIME_INCOMPATIBLE', result.stderr or str(exc)) from exc
    # Resolve only the approved revision, never refs/main or a mutable tag.
    hub = Path(os.environ.get('HF_HUB_CACHE', str(Path(os.environ.get('HF_HOME', str(Path.home()/'.cache/huggingface')))/'hub')))
    snapshot = hub/'models--jonatasgrosman--wav2vec2-large-xlsr-53-russian'/'snapshots'/REVISION
    files = ['config.json', 'preprocessor_config.json', 'special_tokens_map.json', 'vocab.json', 'pytorch_model.bin']
    if not all((snapshot/name).is_file() for name in files):
        raise Unavailable('ALIGNMENT_MODEL_CACHE_ABSENT', str(snapshot))
    hashes = {name: sha(snapshot/name) for name in files}
    if hashes['pytorch_model.bin'] != WEIGHTS:
        raise Unavailable('ALIGNMENT_MODEL_IDENTITY_MISMATCH', 'accepted weights digest differs')
    # WhisperX otherwise tries nltk.download at inference time. Check without importing it.
    check = subprocess.run([str(executable), '-I', '-B', '-c', "import nltk; nltk.data.find('tokenizers/punkt_tab/russian/'); print('OK')"], capture_output=True, text=True, env=offline_environment(), timeout=30)
    if check.returncode:
        raise Unavailable('ALIGNMENT_RUNTIME_INCOMPATIBLE', 'cached Russian NLTK punkt_tab required; no download attempted')
    return dict(interpreter=str(executable), runtime=identity, model=MODEL, model_revision=REVISION,
                model_sha256=WEIGHTS, snapshot=str(snapshot), model_files=hashes,
                producer_sha256=sha(PRODUCER), adapter_sha256=sha(__file__),
                profile_sha256=sha(ROOT/'dependencies/dependency_profiles.json'),
                lock_sha256=sha(ROOT/'dependencies/locks/alignment-py3.13.lock'))


def parse_srt(path):
    """Preserve original cue text/ranges; normalize only physical line separators."""
    cues = []
    def clock(value):
        h, m, s = value.strip().replace(',', '.').split(':')
        return int(h)*3600+int(m)*60+float(s)
    for block in re.split(r'\r?\n\s*\r?\n', Path(path).read_text(encoding='utf-8').strip()):
        lines = block.splitlines()
        index = next((i for i, line in enumerate(lines) if '-->' in line), None)
        if index is None:
            raise ValueError('SRT cue has no native time range')
        left, right = lines[index].split('-->')
        text = '\n'.join(line.strip() for line in lines[index+1:])
        start, end = clock(left), clock(right)
        if not text or end <= start or start < 0:
            raise ValueError('invalid SRT cue')
        cues.append(dict(start=start, end=end, text=text))
    if not cues:
        raise ValueError('SRT has no cues')
    return cues


def produce(media, segments, output, identity, log):
    command = [identity['interpreter'], '-B', str(Path(__file__).resolve()), 'worker',
               '--snapshot', identity['snapshot'], '--audio', str(media), '--segments', str(segments), '--output', str(output)]
    with Path(log).open('wb') as stream:
        result = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT,
                                env=offline_environment(), timeout=600)
    if result.returncode:
        failure = Path(str(output)+'.failure.json')
        value = json.loads(failure.read_bytes()) if failure.exists() else dict(code='ALIGNMENT_EXECUTION_FAILURE', message=f'producer exit {result.returncode}')
        raise Unavailable(value['code'], value['message'])


def project_output(raw, cues, identity, media, srt):
    result = raw['runs'][0]['result']
    transcript = Path(srt).with_name('transcript.txt')
    text = transcript.read_text(encoding='utf-8')
    tokens = [t.group() for t in re.finditer(r'\S+', text)]
    native = result.get('word_segments', [])
    if result.get('segments'):
        projected = []
        for segment in result['segments']:
            source_tokens = re.findall(r'\S+',segment['text'])
            segment_words = segment.get('words',[])
            if not segment_words:
                projected.extend(dict(word=token) for token in source_tokens)
            else:
                if [w['word'] for w in segment_words] != source_tokens:
                    raise ValueError('native segment words do not match their exact source text')
                projected.extend(segment_words)
        native = projected
    if [item.get('word') for item in native] != tokens:
        raise ValueError('producer words do not exactly preserve source SRT tokens')
    words = []
    for sequence, item in enumerate(native):
        start, end = item.get('start'), item.get('end')
        if isinstance(start, (int, float)) and isinstance(end, (int, float)) and end > start:
            words.append(dict(sequence=sequence, **{k:item[k] for k in ('word', 'start', 'end', 'score') if k in item}))
        else:
            words.append(dict(sequence=sequence, word=item['word'], alignment_status='unaligned'))
    return dict(words=words, cues=cues, aligner='whisperx', aligner_version='3.8.6',
                model=MODEL, model_revision=REVISION, model_sha256=WEIGHTS,
                config=dict(role='alignment_only_no_asr', runtime=identity,
                            media_sha256=sha(media), srt_sha256=sha(srt),
                            raw_sha256=hashlib.sha256(json.dumps(raw,sort_keys=True).encode()).hexdigest()))


def worker(args):
    # This process alone imports heavy packages. The producer's actual call is reused.
    try:
        import whisperx
        import nltk
        nltk.data.find('tokenizers/punkt_tab/russian/')
        def no_download(*a, **kw):
            raise RuntimeError('offline adapter forbids NLTK downloads')
        nltk.download = no_download
        original = whisperx.load_align_model
        def cached_loader(*a, **kw):
            try:
                return original(language_code='ru', device='cpu', model_name=args.snapshot, model_cache_only=True)
            except Exception as exc:
                Path(str(args.output)+'.failure.json').write_text(json.dumps(dict(code='ALIGNMENT_MODEL_LOAD_FAILURE', message=str(exc))))
                raise
        whisperx.load_align_model = cached_loader
        sys.argv = [str(PRODUCER), '--audio', args.audio, '--segments', args.segments, '--output', args.output, '--runs', '1']
        runpy.run_path(str(PRODUCER), run_name='__main__')
    except SystemExit as exc:
        if exc.code:
            raise
    except Exception as exc:
        failure = Path(str(args.output)+'.failure.json')
        if not failure.exists():
            failure.write_text(json.dumps(dict(code='ALIGNMENT_EXECUTION_FAILURE', message=str(exc))))
        raise


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['worker'])
    for flag in ['snapshot', 'audio', 'segments', 'output']:
        parser.add_argument('--'+flag, required=True)
    worker(parser.parse_args())
