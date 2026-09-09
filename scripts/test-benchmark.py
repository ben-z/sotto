#!/usr/bin/env python3
"""Offline checks of memory accounting and failure behavior; no Groq requests."""
import importlib.util
import os
from pathlib import Path
import subprocess
import unittest
import time

spec = importlib.util.spec_from_file_location('benchmark', Path(__file__).with_name('benchmark-memory.py'))
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)


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
            sampled = benchmark.Sampler(process.pid, Path('/bin/bash')).read()['cpu_seconds']
        finally:
            process.terminate()
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
