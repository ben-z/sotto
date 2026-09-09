#!/usr/bin/env python3
"""Deterministic optimized-core benchmark. No microphone, Keychain, or external API."""
import argparse
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import platform
import selectors
import subprocess
import sys
import tempfile
import threading
import time
import wave

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('memory', ROOT / 'scripts/benchmark-memory.py')
memory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(memory)
PHASES = ('warmup', 'idle_before', 'short_upload', 'long_upload', 'idle_after')


class FixtureServer(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        try:
            if self.path != '/transcriptions' or self.headers.get('Authorization') != 'Bearer benchmark-fixture-key':
                raise ValueError('Unexpected endpoint or credential')
            remaining = total = int(self.headers['Content-Length'])
            if not (1_920_044 < total < 1_922_044 or 19_200_044 < total < 19_202_044):
                raise ValueError(f'Unexpected multipart size: {total}')
            prefix = bytearray()
            while remaining:
                chunk = self.rfile.read(min(65536, remaining))
                if not chunk:
                    raise ValueError('Incomplete upload')
                if len(prefix) < 1024:
                    prefix.extend(chunk[:1024 - len(prefix)])
                remaining -= len(chunk)
                time.sleep(0.002)  # Fixed receiver pacing, not real network latency.
            if b'whisper-large-v3-turbo' not in prefix or b'RIFF' not in prefix:
                raise ValueError('Missing production multipart fields or WAV header')
            time.sleep(0.25)
            body = b'{"text":" Sotto benchmark fixture. ","language":"en"}'
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            self.server.completed.append(total)
        except Exception as error:
            self.server.errors.append(str(error))
            self.send_error(500, 'Invalid benchmark request')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'work/ci-performance')
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        raise RuntimeError('macOS runner required')
    args.output.mkdir(parents=True, exist_ok=True)
    output = args.output.resolve()
    binary = output / 'core-benchmark'
    subprocess.run(['swiftc', '-O', '-whole-module-optimization', '-swift-version', '6', '-parse-as-library',
                    '-module-name', 'SottoCore', *map(str, sorted((ROOT / 'Sources/SottoCore').glob('*.swift'))),
                    str(ROOT / 'scripts/ci-memory/Runner.swift'), '-o', str(binary)], check=True)
    samples = []
    with tempfile.TemporaryDirectory(prefix='sotto-ci-benchmark-') as temporary:
        fixture = Path(temporary)
        fixtures = {}
        for name, seconds in [('short', 60), ('long', 600)]:
            path = fixture / (name + '.wav')
            with wave.open(str(path), 'wb') as audio:
                audio.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
                for _ in range(seconds):
                    audio.writeframesraw(bytes(32000))
            fixtures[name] = dict(seconds=seconds, bytes=path.stat().st_size,
                                  sha256=hashlib.sha256(path.read_bytes()).hexdigest())
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), FixtureServer)
        server.completed, server.errors = [], []
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        process = subprocess.Popen([str(binary), str(fixture), f'http://127.0.0.1:{server.server_port}/transcriptions'],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            sampler = memory.Sampler(process.pid, binary)
            selector = selectors.DefaultSelector()
            selector.register(process.stdout, selectors.EVENT_READ)
            phase, cycle = None, 0
            deadline = time.monotonic() + 120
            while process.poll() is None:
                if time.monotonic() > deadline:
                    raise RuntimeError('Benchmark host timed out')
                if selector.select(timeout=0.02):
                    line = process.stdout.readline()
                    if line:
                        event = json.loads(line)
                        phase, cycle = event['phase'], event['cycle']
                        if phase not in PHASES:
                            raise RuntimeError(f'Unknown phase: {phase}')
                        print(f'{phase} (cycle {cycle})', flush=True)
                if phase:
                    try:
                        samples.append(dict(sampler.read(), phase=phase, cycle=cycle))
                    except RuntimeError:
                        if process.poll() is None:
                            raise
            if process.returncode != 0:
                raise RuntimeError('Benchmark host failed: ' + process.stderr.read())
            if server.errors or len(server.completed) != 8:
                raise RuntimeError(f'Fixture server failed: {server.errors}; completed {len(server.completed)}/8')
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
            server.shutdown()
            server.server_close()
            (output / 'samples.json').write_text(json.dumps(samples) + '\n')
    summary = memory.summarize(samples, PHASES)
    failures = memory.check_limits(summary, 96, 128, 24)
    limits = dict(idle_peak_mib=96, active_peak_mib=128, idle_growth_mib=24, bundle_mib=2)
    bundle = ROOT / '.build/ci/Sotto.app'
    if not bundle.is_dir():
        raise RuntimeError('Packaged .build/ci/Sotto.app is required for the bundle-size check')
    bundle_bytes = sum(p.stat().st_size for p in bundle.rglob('*') if p.is_file())
    if bundle_bytes > limits['bundle_mib'] * memory.MIB:
        failures.append('Packaged app exceeds 2 MiB file-byte limit')
    report = dict(workload='optimized production core with deterministic loopback HTTP fixture; not the menu-bar app',
                  commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                  runner=os.environ.get('RUNNER_NAME', 'local'), architecture=platform.machine(), macos=platform.mac_ver()[0],
                  image=os.environ.get('ImageVersion', 'local'),
                  swift=subprocess.check_output(['swiftc', '--version'], text=True, stderr=subprocess.STDOUT).strip(),
                  fixtures=fixtures, summary=summary, limits=limits, failures=failures, bundle_bytes=bundle_bytes,
                  run_url=(f"https://github.com/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}"
                           if 'GITHUB_RUN_ID' in os.environ else None))
    lines = ['# CI resource benchmark', '', report['workload'], '',
             f"Commit `{report['commit']}` · {report['architecture']} · macOS {report['macos']} · image `{report['image']}`", '',
             '| Phase | Footprint median / peak (MiB) | Peak RSS (MiB) | CPU (% one core) |',
             '| --- | ---: | ---: | ---: |']
    for phase, row in summary.items():
        lines.append(f"| {phase} | {row['footprint_median_mib']:.1f} / {row['footprint_peak_mib']:.1f} | {row['rss_peak_mib']:.1f} | {row['cpu_percent']:.2f} |")
    lines += ['', f'Packaged native app: {bundle_bytes:,} file bytes.',
              'One short/long warm-up pair, then three cycles each of 60-second (1,920,044-byte) and 600-second (19,200,044-byte) deterministic silent PCM WAV fixtures, through real multipart construction, file upload, response parsing, and archive completion.',
              'Five-second idle windows before/after; 20 ms sampling. Fixture server: 2 ms per 64 KiB read + 250 ms response delay. Server/sampler excluded. No microphone, Keychain, clipboard, UI, Groq service, or real transcription inference.',
              'Limits: idle 96 MiB; active 128 MiB; retained idle growth 24 MiB; packaged app 2 MiB. Memory and size fail CI; CPU is reported, not gated on noisy shared runners.',
              '**' + ('FAIL: ' + '; '.join(failures) if failures else 'PASS') + '**', '']
    markdown = '\n'.join(lines)
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    (output / 'report.md').write_text(markdown)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as stream:
            stream.write(markdown)
    print(markdown)
    if failures:
        raise RuntimeError('; '.join(failures))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        sys.exit(f'CI resource benchmark failed: {error}')
