#!/usr/bin/env python3
"""Measure the real, running macOS app. Records microphone audio and calls Groq."""
import argparse
import ctypes
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import signal
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
SUPPORT = Path.home() / 'Library/Application Support/Sotto'
MIB = 1024 * 1024
PHASES = ('idle_before', 'recording', 'transcribing', 'idle_after')


class Usage(ctypes.Structure):
    # macOS SDK sys/resource.h, rusage_info_v0 (RUSAGE_INFO_V0 = 0).
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64) for name in (
            'user_time', 'system_time', 'pkg_idle_wkups', 'interrupt_wkups',
            'pageins', 'wired_size', 'resident_size', 'phys_footprint',
            'proc_start_abstime', 'proc_exit_abstime')]


class Timebase(ctypes.Structure):
    _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]


class Sampler:
    def __init__(self, pid, binary):
        self.pid = pid
        self.lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        system = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
        timebase = Timebase()
        system.mach_timebase_info.argtypes = [ctypes.POINTER(Timebase)]
        if system.mach_timebase_info(ctypes.byref(timebase)) != 0 or not timebase.denom:
            raise RuntimeError('Cannot obtain the macOS CPU timer timebase.')
        # rusage_info CPU counters use Mach ticks, not nanoseconds on Apple Silicon.
        self.seconds_per_tick = timebase.numer / timebase.denom / 1e9
        self.lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        path = ctypes.create_string_buffer(4096)
        if self.lib.proc_pidpath(pid, path, len(path)) <= 0:
            raise RuntimeError('Cannot inspect target PID; is Sotto running?')
        if Path(os.fsdecode(path.value)).resolve() != binary.resolve():
            raise RuntimeError('PID does not belong to the specified Sotto app.')
        self.started = self.read()['process_start']

    def read(self):
        usage = Usage()
        if self.lib.proc_pid_rusage(self.pid, 0, ctypes.byref(usage)) != 0:
            raise RuntimeError(f'Cannot sample PID {self.pid}: {os.strerror(ctypes.get_errno())}')
        if hasattr(self, 'started') and usage.proc_start_abstime != self.started:
            raise RuntimeError('Target PID was reused; refusing to measure or signal it.')
        return dict(time=time.monotonic(), footprint_bytes=usage.phys_footprint,
                    rss_bytes=usage.resident_size,
                    cpu_seconds=(usage.user_time + usage.system_time) * self.seconds_per_tick,
                    process_start=usage.proc_start_abstime)

    def send(self, number):
        self.read()  # Check process identity immediately before signalling.
        os.kill(self.pid, number)


def summarize(samples, phases=PHASES):
    result = {}
    for phase in phases:
        rows = [row for row in samples if row['phase'] == phase]
        if len(rows) < 2:
            raise RuntimeError(f'Insufficient {phase} samples; no valid benchmark. Increase workload or sample faster.')
        # Sum adjacent intervals only: never count time between separate cycles.
        pairs = [(a, b) for a, b in zip(samples, samples[1:])
                 if a['phase'] == b['phase'] == phase and a['cycle'] == b['cycle']]
        elapsed = sum(b['time'] - a['time'] for a, b in pairs)
        if elapsed <= 0:
            raise RuntimeError(f'Insufficient contiguous {phase} samples.')
        cpu = sum(b['cpu_seconds'] - a['cpu_seconds'] for a, b in pairs)
        result[phase] = dict(samples=len(rows), sampled_seconds=elapsed,
                            footprint_median_mib=statistics.median(r['footprint_bytes'] for r in rows) / MIB,
                            footprint_peak_mib=max(r['footprint_bytes'] for r in rows) / MIB,
                            rss_peak_mib=max(r['rss_bytes'] for r in rows) / MIB,
                            cpu_percent=100 * cpu / elapsed)
    return result


def check_limits(summary, idle_limit, active_limit, growth_limit):
    failures = []
    for phase, values in summary.items():
        limit = idle_limit if phase.startswith('idle') else active_limit
        if values['footprint_peak_mib'] > limit:
            failures.append(f'{phase}: peak physical footprint exceeds {limit:g} MiB')
    growth = summary['idle_after']['footprint_median_mib'] - summary['idle_before']['footprint_median_mib']
    if growth > growth_limit:
        failures.append(f'Post-cycle idle growth {growth:.1f} MiB exceeds {growth_limit:g} MiB')
    return failures


def markdown(report):
    lines = ['# Sotto memory benchmark', '', f"Measured {report['date']} · {report['hardware']} · macOS {report['macos']}",
             f"Version {report['version']} · source {report['revision']} · executable SHA-256 `{report['binary_sha256']}`", '',
             '| Phase | Physical footprint median / peak (MiB) | Peak RSS (MiB) | CPU (% of one core) | Samples |',
             '| --- | ---: | ---: | ---: | ---: |']
    for phase, row in report['summary'].items():
        lines.append(f"| {phase.replace('_', ' ')} | {row['footprint_median_mib']:.1f} / {row['footprint_peak_mib']:.1f} | {row['rss_peak_mib']:.1f} | {row['cpu_percent']:.2f} | {row['samples']} |")
    lines += ['', f"App bundle file bytes: {report['bundle_bytes']:,}. Model: `{report['model']}`. Language: `{report['language']}`.",
              f"{len(report['recordings'])} microphone recordings; durations (s): " + ', '.join(f"{r['duration_seconds']:.1f}" for r in report['recordings']) + '.',
              'Audio sizes (bytes): ' + ', '.join(str(r['audio_bytes']) for r in report['recordings']) + '.',
              f"Sampling interval: {report['interval_seconds']:g} s. Idle windows: {report['idle_seconds']:g} s before and after cycles. Auto-paste disabled; protocol requires Settings closed (not automatically checked).",
              '', '**' + ('FAIL: ' + '; '.join(report['failures']) if report['failures'] else 'PASS: configured memory limits met.') + '**',
              f"Limits: idle peak {report['limits']['idle_mib']:g} MiB; active peak {report['limits']['active_mib']:g} MiB; median idle growth {report['limits']['growth_mib']:g} MiB.",
              '', 'Physical footprint is macOS process memory accounting; RSS includes resident shared pages. CPU is process CPU-time delta divided by sampled wall time (100% = one core). The sampler and OS services are excluded. Peaks are sampled, not guaranteed instantaneous maxima. This measures a warmed running app and live microphone/Groq workload, not startup, transcription accuracy, or a maximum-length file. Results vary by hardware, input, and network.', '']
    return '\n'.join(lines)


def positive(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError('must be finite and positive')
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--app', type=Path, default=ROOT / '.build/Sotto.app')
    parser.add_argument('--output', type=Path, default=ROOT / 'work/performance' / datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'))
    parser.add_argument('--cycles', type=int, default=3)
    parser.add_argument('--idle-seconds', type=positive, default=20)
    parser.add_argument('--record-seconds', type=positive, default=15)
    parser.add_argument('--interval', type=positive, default=0.02)
    parser.add_argument('--timeout', type=positive, default=200)
    parser.add_argument('--max-idle-mib', type=positive, default=128)
    parser.add_argument('--max-active-mib', type=positive, default=192)
    parser.add_argument('--max-growth-mib', type=positive, default=32)
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        raise RuntimeError('This benchmark requires macOS and a running Sotto.app.')
    if args.pid <= 0 or args.cycles < 1:
        parser.error('PID and cycles must be positive')
    if args.interval >= min(args.idle_seconds, args.record_seconds) / 2:
        parser.error('Sample interval must allow multiple samples per phase')
    config = json.loads((SUPPORT / 'config.json').read_text())
    if config['paste']:
        raise RuntimeError('Turn auto-paste off in Sotto Settings and Save before benchmarking, to prevent typing test audio into another app.')
    if args.record_seconds + 2 >= config['maxRecordingSeconds']:
        raise RuntimeError('Recording duration must be at least two seconds below the configured limit.')
    archive = Path(config['recordingsDirectory']).expanduser()
    if not archive.is_dir():
        raise RuntimeError('Configured recording directory is missing.')
    binary = args.app / 'Contents/MacOS/sotto'
    sampler = Sampler(args.pid, binary)
    binary_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
    samples, recordings = [], []

    def state():
        status = json.loads((SUPPORT / 'status.json').read_text())
        if status['state'] == 'error':
            raise RuntimeError('Sotto reported an error. Open Settings for details; no successful benchmark will be published.')
        return status['state']

    def sample(phase, cycle):
        samples.append(dict(sampler.read(), phase=phase, cycle=cycle))
        time.sleep(args.interval)

    def window(phase, expected, seconds, cycle):
        print(f'{phase}: {seconds:g}s', flush=True)
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if state() != expected:
                raise RuntimeError(f'Expected {expected} during {phase}; app state changed unexpectedly.')
            sample(phase, cycle)

    if state() != 'idle':
        raise RuntimeError('Sotto must be idle before benchmarking.')
    args.output.mkdir(parents=True, exist_ok=True)
    # Never leave a previous success report looking like the current run.
    for name in ('report.json', 'report.md', 'failure.txt'):
        (args.output / name).unlink(missing_ok=True)
    controlled = False
    try:
        window('idle_before', 'idle', args.idle_seconds, 0)
        for cycle in range(1, args.cycles + 1):
            before = set(archive.glob('*.json'))
            print(f'Cycle {cycle}/{args.cycles}: recording microphone audio for Groq.', flush=True)
            sampler.send(signal.SIGUSR1)
            controlled = True
            deadline = time.monotonic() + 20
            while state() != 'recording':
                if time.monotonic() >= deadline:
                    raise RuntimeError('Recording did not start within 20s. Resolve Keychain/microphone prompts and retry.')
                sample('preparing', cycle)
            window('recording', 'recording', args.record_seconds, cycle)
            sampler.send(signal.SIGUSR1)
            deadline = time.monotonic() + args.timeout
            while True:
                current = state()
                if current == 'idle':
                    break
                if current not in ('recording', 'transcribing'):
                    raise RuntimeError(f'Unexpected app state: {current}')
                if time.monotonic() >= deadline:
                    raise RuntimeError('Transcription timed out; no successful benchmark will be published.')
                sample(current, cycle)
            controlled = False
            if sum(r['phase'] == 'transcribing' and r['cycle'] == cycle for r in samples) < 2:
                raise RuntimeError('Transcription was too short to sample reliably; retry with longer audio or a shorter interval.')
            new = [p for p in set(archive.glob('*.json')) - before if not p.name.endswith('.response.json')]
            if len(new) != 1:
                raise RuntimeError('Expected one new recording metadata file; another recording may have interfered.')
            record = json.loads(new[0].read_text())
            if record['status'] != 'complete' or record.get('error'):
                raise RuntimeError('Recording did not complete successfully. Inspect retained archive diagnostics.')
            recordings.append(dict(duration_seconds=record['durationSeconds'], audio_bytes=record['audioBytes']))
        window('idle_after', 'idle', args.idle_seconds, args.cycles + 1)
        if hashlib.sha256(binary.read_bytes()).hexdigest() != binary_hash:
            raise RuntimeError('App binary changed during measurement; benchmark invalid.')
        if json.loads((SUPPORT / 'config.json').read_text()) != config:
            raise RuntimeError('Configuration changed during measurement; benchmark invalid.')
        summary = summarize(samples)
        failures = check_limits(summary, args.max_idle_mib, args.max_active_mib, args.max_growth_mib)
        info = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())
        revision = subprocess.check_output(['git', 'rev-parse', '--short', 'HEAD'], cwd=ROOT, text=True).strip()
        if subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT):
            revision += ' (working tree modified)'
        report = dict(date=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                      hardware=subprocess.check_output(['sysctl', '-n', 'hw.model'], text=True).strip() + ' / ' + platform.machine(),
                      macos=platform.mac_ver()[0], version=info['CFBundleShortVersionString'], revision=revision,
                      binary_sha256=binary_hash,
                      bundle_bytes=sum(p.stat().st_size for p in args.app.rglob('*') if p.is_file()),
                      model=config['model'], language=config.get('language'), recordings=recordings,
                      interval_seconds=args.interval, idle_seconds=args.idle_seconds, summary=summary, failures=failures,
                      limits=dict(idle_mib=args.max_idle_mib, active_mib=args.max_active_mib, growth_mib=args.max_growth_mib))
        (args.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        (args.output / 'report.md').write_text(markdown(report))
        if failures:
            raise RuntimeError('; '.join(failures))
        print(markdown(report))
    except BaseException as error:
        (args.output / 'failure.txt').write_text(str(error) + '\n')
        raise
    finally:
        (args.output / 'samples.json').write_text(json.dumps(samples) + '\n')
        if controlled:
            sampler.send(signal.SIGUSR2)  # Cancel only the attempt this script started; retain audio.


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        sys.exit(f'Benchmark failed: {error}')
