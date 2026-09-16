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
PHASES = ('warmup', 'idle_before', 'short_upload', 'long_upload', 'chunked_upload', 'idle_after')
BUDGET_FILE = ROOT / 'scripts/ci-memory/budgets.json'
FIXTURES = {'short': 60, 'long': 600, 'chunked': 10800}
EXPECTED_UPLOADS = 4 * (1 + 1 + 19)  # Warm-up plus three cycles; three-hour audio has 19 overlapping parts.


def load_budgets():
    limits = json.loads(BUDGET_FILE.read_text())
    if set(limits) != {'idle_peak_mib', 'active_peak_mib', 'idle_growth_mib', 'bundle_mib'}:
        raise ValueError('Unexpected memory budget keys')
    for value in limits.values():
        memory.positive(str(value))
    return limits


def check_budgets(summary, bundle_bytes, limits):
    failures = memory.check_limits(summary, limits['idle_peak_mib'], limits['active_peak_mib'], limits['idle_growth_mib'])
    if bundle_bytes > limits['bundle_mib'] * memory.MIB:
        failures.append(f"Packaged app exceeds {limits['bundle_mib']:g} MiB file-byte limit")
    return failures


class FixtureServer(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        try:
            if self.path != '/transcriptions' or self.headers.get('Authorization') != 'Bearer benchmark-fixture-key':
                raise ValueError('Unexpected endpoint or credential')
            remaining = total = int(self.headers['Content-Length'])
            # Direct WAV headers and AVAudioFile's padded headers differ; allow
            # container/multipart overhead but require an expected PCM duration.
            if not any(seconds * 32000 < total < seconds * 32000 + 12_000 for seconds in (36, 60, 600)):
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
            body = b'{"text":" Sotto benchmark fixture. ","language":"en","words":[{"word":"Sotto","start":10,"end":10.3},{"word":"benchmark","start":10.3,"end":10.7},{"word":"fixture.","start":10.7,"end":11}]}'
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
    for name in ('report.json', 'report.md', 'samples.json'):
        (output / name).unlink(missing_ok=True)
    try:
        run(output)
    except Exception as error:
        if not (output / 'report.json').exists():
            write_failure(output, error)
        raise


def write_failure(output, error):
    report = dict(protocol_version=2, incomplete=True, failures=[str(error)],
                  commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip())
    markdown = f"# CI resource benchmark\n\n**FAIL: {error}**\n\nThe workload is incomplete; partial samples are diagnostic data, not a baseline.\n"
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    (output / 'report.md').write_text(markdown)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as stream:
            stream.write(markdown)


def run(output):
    limits = load_budgets()
    binary = output / 'core-benchmark'
    subprocess.run(['swiftc', '-O', '-whole-module-optimization', '-swift-version', '6', '-parse-as-library',
                    '-module-name', 'SottoCore', *map(str, sorted((ROOT / 'Sources/SottoCore').glob('*.swift'))),
                    str(ROOT / 'scripts/ci-memory/Runner.swift'), '-o', str(binary)], check=True)
    samples = []
    with tempfile.TemporaryDirectory(prefix='sotto-ci-benchmark-') as temporary:
        fixture = Path(temporary)
        fixtures = {}
        for name, seconds in FIXTURES.items():
            path = fixture / (name + '.wav')
            with wave.open(str(path), 'wb') as audio:
                audio.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
                for _ in range(seconds):
                    audio.writeframesraw(bytes(32000))
            with path.open('rb') as stream:
                digest = hashlib.sha256()
                while block := stream.read(1_048_576):
                    digest.update(block)
            fixtures[name] = dict(seconds=seconds, bytes=path.stat().st_size, sha256=digest.hexdigest())
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
            deadline = time.monotonic() + 480
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
            if server.errors or len(server.completed) != EXPECTED_UPLOADS:
                raise RuntimeError(f'Fixture server failed: {server.errors}; completed {len(server.completed)}/{EXPECTED_UPLOADS}')
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
            server.shutdown()
            server.server_close()
            (output / 'samples.json').write_text(json.dumps(samples) + '\n')
    summary = memory.summarize(samples, PHASES)
    bundle = ROOT / '.build/ci/Sotto.app'
    if not bundle.is_dir():
        raise RuntimeError('Packaged .build/ci/Sotto.app is required for the bundle-size check')
    bundle_bytes = sum(p.stat().st_size for p in bundle.rglob('*') if p.is_file())
    failures = check_budgets(summary, bundle_bytes, limits)
    report = dict(protocol_version=2, workload='optimized production core with deterministic loopback HTTP fixture; not the menu-bar app',
                  commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                  dirty=bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True).strip()),
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
              'Protocol v2: one warm-up of all workloads, then three cycles each of 60-second, 600-second, and three-hour deterministic PCM WAV fixtures. The three-hour recording uses 19 overlapping uploads, exercising decoding, boundary reconciliation, multipart construction, and archive completion. All 84 uploads must complete.',
              'Five-second idle windows before/after; 20 ms sampling. Fixture server: 2 ms per 64 KiB read + 250 ms response delay. Server/sampler excluded. No microphone, Keychain, clipboard, UI, Groq service, or real transcription inference.',
              f"Checked-in budgets: idle {limits['idle_peak_mib']} MiB; active {limits['active_peak_mib']} MiB; retained idle growth {limits['idle_growth_mib']} MiB; packaged app {limits['bundle_mib']} MiB. Memory and size fail CI; CPU is reported, not gated on noisy shared runners.",
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
