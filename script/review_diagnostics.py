#!/usr/bin/env python3
"""Summarise only WhiskerFlow's allowlisted local diagnostics, never transcripts."""
import argparse
import collections
import json
import math
import pathlib
import time


def summarize(rows, now, hours):
    rows = sorted(rows, key=lambda r: float(r.get('timestamp', 0)))
    recent = [r for r in rows if now - hours * 3600 <= float(r.get('timestamp', 0)) <= now]
    counts = collections.Counter(r.get('event') for r in recent)
    durations = [float(r['elapsed_ms']) for r in recent if r.get('event') == 'paste_returned' and 'elapsed_ms' in r]
    issues = []
    if counts['finish_timeout']:
        issues.append({'kind': 'finish_timeout', 'count': counts['finish_timeout']})
    slow = [r for r in recent if r.get('event') == 'paste_returned' and float(r.get('elapsed_ms', 0)) > 2000]
    if slow:
        issues.append({'kind': 'slow_delivery', 'count': len(slow), 'max_ms': max(float(r['elapsed_ms']) for r in slow)})
    if counts['main_thread_stalled']:
        issues.append({'kind': 'main_thread_stalled', 'count': counts['main_thread_stalled'], 'recoveries': counts['main_thread_recovered']})
    failures = [r for r in recent if (r.get('event') == 'state_changed' and r.get('state') == 'failure') or (r.get('event') == 'paste_returned' and r.get('outcome') == 'failed')]
    if failures:
        issues.append({'kind': 'failure_events', 'count': len(failures)})
    latest = {}
    for row in recent:
        if row.get('event') == 'state_changed':
            latest[row.get('launch')] = row
    for row in latest.values():
        age = now - float(row['timestamp'])
        if row.get('state') in ('transcribing', 'delivering') and age > 30:
            issues.append({'kind': 'unfinished_state_needs_process_check', 'state': row['state'], 'age_seconds': round(age), 'pid': row.get('pid')})
    active = {}
    resource = {}
    stall_context = []
    for row in recent:
        launch = row.get('launch')
        key = (launch, row.get('session'))
        event = row.get('event')
        if event == 'stage_started':
            active[key] = row
        elif event == 'stage_finished':
            if active.get(key, {}).get('stage') == row.get('stage'):
                active.pop(key, None)
        elif event == 'finish_returned':
            active.pop(key, None)
        elif event == 'resource_snapshot':
            resource[launch] = row
        elif event == 'main_thread_stalled':
            nearby = resource.get(launch)
            age = float(row['timestamp']) - float(nearby['timestamp']) if nearby else None
            stall_context.append({
                'timestamp': row['timestamp'],
                'build': row.get('build'),
                'launch': launch,
                'active_stages': [{'stage': x.get('stage'), 'session': x.get('session'), 'elapsed_seconds': round(float(row['timestamp']) - float(x['timestamp']), 3)} for k, x in active.items() if k[0] == launch],
                'resource_age_seconds': round(age, 3) if age is not None else None,
                'resources': {k: v for k, v in nearby.items() if k in ('load_1m', 'cpu_count', 'app_cpu_percent', 'system_cpu_percent', 'sample_interval_ms', 'rss_bytes', 'swap_used_bytes', 'swapins_pages', 'swapouts_pages', 'swapins_delta_pages', 'swapouts_delta_pages', 'compressed_pages', 'page_size_bytes', 'thermal_state', 'memory_pressure')} if nearby and age <= 30 else None,
            })
    captures = []
    starts = {}
    for row in recent:
        key = (row.get('launch'), row.get('pid'), row.get('build'), row.get('capture_id'))
        if row.get('event') == 'stack_capture_started':
            starts[key] = row
        elif row.get('event') in ('stack_captured', 'stack_capture_failed'):
            start = starts.get(key)
            recovered = None
            if start:
                recovered = next((r for r in recent if r.get('event') == 'main_thread_recovered'
                    and (r.get('launch'), r.get('pid'), r.get('build')) == key[:3]
                    and float(start['timestamp']) <= float(r['timestamp']) <= float(row['timestamp'])), None)
            captures.append({'capture_id': key[3], 'launch': key[0], 'pid': key[1], 'build': key[2],
                'outcome': row['event'], 'failure_reason': row.get('capture_failure'),
                'elapsed_ms': row.get('elapsed_ms'), 'start_available': start is not None,
                'report_shape': {k: row[k] for k in ('sample_report_bytes', 'sample_thread_headers', 'sample_main_headers', 'sample_symbol_lines') if k in row},
                'recovery_before_capture_completed': True if recovered else (False if start else None),
                'timing_limit': 'Capture completion includes symbolication and writing; it does not identify the exact sampling interval.'})
    finishes = {}
    for build in sorted({r.get('build', 'unknown') for r in recent}):
        values = sorted(float(r['elapsed_ms']) for r in recent if r.get('build', 'unknown') == build and r.get('event') == 'finish_returned' and 'elapsed_ms' in r)
        if values:
            finishes[build] = {'count': len(values), 'max_ms': round(values[-1], 1),
                'p95_ms': round(values[math.ceil(len(values) * .95) - 1], 1)}
    return {
        'text_processing_timing': [{k: r[k] for k in ('timestamp', 'build', 'launch', 'session', 'elapsed_ms', 'worker_elapsed_ms', 'resume_delay_ms') if k in r} for r in recent if r.get('event') == 'stage_finished' and r.get('stage') == 'text_processing' and float(r.get('elapsed_ms', 0)) > 1000],
        'capture_context': captures,
        'finish_ms_by_build': finishes,
        'stall_context': stall_context,
        'resource_samples': counts['resource_snapshot'],
        'window_hours': hours,
        'events': len(recent),
        'event_counts': dict(sorted(counts.items())),
        'builds': sorted({r.get('build', 'unknown') for r in recent}),
        'latest_event_age_seconds': round(now - max(float(r['timestamp']) for r in recent)) if recent else None,
        'paste_ms': {'count': len(durations), 'max': round(max(durations), 1), 'mean': round(sum(durations) / len(durations), 1)} if durations else None,
        'issues': issues,
        'coverage': 'observed_events_only' if recent else 'no_recent_evidence',
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--hours', type=float, default=2)
    parser.add_argument('--directory', type=pathlib.Path, default=pathlib.Path.home() / 'Library/Logs/WhiskerFlow')
    args = parser.parse_args()
    rows = []
    malformed = 0
    for path in sorted(args.directory.glob('diagnostics*.jsonl')):
        with path.open() as source:
            for line in source:
                try:
                    row = json.loads(line)
                    float(row.get('timestamp', 0))
                    rows.append(row)
                except (ValueError, TypeError):
                    malformed += 1
    rows.sort(key=lambda row: float(row.get('timestamp', 0)))
    result = summarize(rows, time.time(), args.hours)
    result['malformed_rows'] = malformed
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
