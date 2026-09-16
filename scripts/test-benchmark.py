#!/usr/bin/env python3
"""Offline checks of memory accounting and failure behavior; no Groq requests."""
import importlib.util
import os
from pathlib import Path
import subprocess
import signal
import unittest
import time
import tempfile
import json
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('benchmark', Path(__file__).with_name('benchmark-memory.py'))
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)
ci_spec = importlib.util.spec_from_file_location('ci_benchmark', Path(__file__).with_name('benchmark-ci.py'))
ci = importlib.util.module_from_spec(ci_spec)
ci_spec.loader.exec_module(ci)


def fixture():
    samples = []
    for cycle in (1, 2):
        for phase in benchmark.PHASES:
            for offset in (0, 1):
                samples.append(dict(phase=phase, cycle=cycle, time=cycle * 100 + offset,
                                    cpu_seconds=cycle * 10 + offset * 0.25,
                                    footprint_bytes=(40 + offset * 20) * benchmark.MIB,
                                    rss_bytes=90 * benchmark.MIB))
    return samples


class BenchmarkTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.process = subprocess.Popen(['/bin/sleep', '30'])

    @classmethod
    def tearDownClass(cls):
        cls.process.terminate()
        cls.process.wait(timeout=5)

    def test_summary_excludes_gaps_between_cycles(self):
        result = benchmark.summarize(fixture())
        for phase in benchmark.PHASES:
            self.assertEqual(result[phase]['sampled_seconds'], 2)
            self.assertEqual(result[phase]['cpu_percent'], 25)
            self.assertEqual(result[phase]['footprint_median_mib'], 50)
            self.assertEqual(result[phase]['footprint_peak_mib'], 60)
            self.assertEqual(result[phase]['rss_peak_mib'], 90)

    def test_missing_transcription_is_failure(self):
        with self.assertRaisesRegex(RuntimeError, 'transcribing'):
            benchmark.summarize([s for s in fixture() if s['phase'] != 'transcribing'])

    def test_disconnected_samples_are_not_a_valid_phase(self):
        with self.assertRaisesRegex(RuntimeError, 'contiguous'):
            benchmark.summarize([s for s in fixture() if s['time'] % 100 == 0])

    def test_limits_fail_independently(self):
        summary = benchmark.summarize(fixture())
        self.assertEqual(benchmark.check_limits(summary, 128, 192, 32), [])
        self.assertEqual(len(benchmark.check_limits(summary, 59, 192, 32)), 2)
        self.assertEqual(len(benchmark.check_limits(summary, 128, 59, 32)), 2)
        summary['idle_after']['footprint_median_mib'] = 90
        self.assertIn('idle growth', benchmark.check_limits(summary, 128, 192, 32)[0])

    def test_ci_budgets_reject_memory_and_bundle_regressions(self):
        limits = ci.load_budgets()
        summary = {phase: dict(footprint_peak_mib=12, footprint_median_mib=10) for phase in ci.PHASES}
        self.assertEqual(ci.check_budgets(summary, 1_000_000, limits), [])
        for phase in ci.PHASES:
            threshold = limits['idle_peak_mib'] if phase.startswith('idle') else limits['active_peak_mib']
            summary[phase]['footprint_peak_mib'] = threshold + 1
            self.assertTrue(ci.check_budgets(summary, 1_000_000, limits), phase)
            summary[phase]['footprint_peak_mib'] = 12
        summary['idle_after']['footprint_median_mib'] = 11 + limits['idle_growth_mib']
        self.assertTrue(ci.check_budgets(summary, 1_000_000, limits))
        summary['idle_after']['footprint_median_mib'] = 10
        self.assertTrue(ci.check_budgets(summary, (limits['bundle_mib'] + 1) * benchmark.MIB, limits))

    def test_missing_chunked_phase_is_failure(self):
        with self.assertRaisesRegex(RuntimeError, 'chunked_upload'):
            ci.memory.summarize([dict(row, phase='chunked_upload') for row in fixture()][:1], ('chunked_upload',))

    def test_incomplete_workload_retains_failure_report(self):
        with tempfile.TemporaryDirectory() as root, patch.dict(os.environ, {}, clear=True):
            output = Path(root)
            ci.write_failure(output, RuntimeError('Benchmark host timed out'))
            report = json.loads((output / 'report.json').read_text())
            self.assertTrue(report['incomplete'])
            self.assertEqual(report['failures'], ['Benchmark host timed out'])
            self.assertIn('not a baseline', (output / 'report.md').read_text())

    def test_dense_response_fixture_covers_contiguous_recording(self):
        self.assertEqual(len(ci.RESPONSE_CASES), 20)
        self.assertEqual(ci.EXPECTED_UPLOADS, 80)
        first = json.loads(ci.response_payload(600, 0))
        second = json.loads(ci.response_payload(600, 600))
        tail = json.loads(ci.response_payload(600, 10200))
        self.assertEqual(len(first['words']), 3600)
        self.assertEqual(first['words'][-1]['word'], 'word3599')
        self.assertEqual(second['words'][0]['word'], 'word3600')
        self.assertEqual(tail['words'][-1]['word'], 'word64799')
        self.assertEqual(first['text'].strip(), ' '.join(w['word'] for w in first['words']))

    def test_invalid_numbers_fail(self):
        for value in ('0', '-1', 'nan', 'inf'):
            with self.assertRaises(benchmark.argparse.ArgumentTypeError):
                benchmark.positive(value)

    def test_native_sampler_reports_real_process_memory(self):
        sampler = benchmark.Sampler(self.process.pid, Path('/bin/sleep'))
        measurement = sampler.read()
        self.assertGreater(measurement['footprint_bytes'], 0)
        self.assertGreater(measurement['rss_bytes'], 0)
        self.assertGreater(measurement['process_start'], 0)
        self.assertGreaterEqual(measurement['cpu_seconds'], 0)

    def test_cpu_time_matches_kernel_wait_accounting(self):
        process = subprocess.Popen(['/bin/bash', '-c', 'while :; do :; done'])
        try:
            time.sleep(0.25)
            os.kill(process.pid, signal.SIGSTOP)
            _, stopped = os.waitpid(process.pid, os.WUNTRACED)
            self.assertTrue(os.WIFSTOPPED(stopped))
            sampled = benchmark.Sampler(process.pid, Path('/bin/bash')).read()['cpu_seconds']
        finally:
            process.kill()  # Stopped process cannot accrue CPU between sample and wait4.
            _, status, usage = os.wait4(process.pid, 0)
            process.returncode = os.waitstatus_to_exitcode(status)
        actual = usage.ru_utime + usage.ru_stime
        self.assertGreater(actual, 0.03)
        self.assertAlmostEqual(sampled, actual, delta=0.02)

    def test_wrong_process_is_rejected_before_signalling(self):
        with self.assertRaisesRegex(RuntimeError, 'does not belong'):
            benchmark.Sampler(os.getpid(), Path('/not-sotto'))

    def test_reused_pid_is_rejected(self):
        sampler = benchmark.Sampler(self.process.pid, Path('/bin/sleep'))
        sampler.started += 1
        with self.assertRaisesRegex(RuntimeError, 'reused'):
            sampler.read()


if __name__ == '__main__':
    unittest.main()
