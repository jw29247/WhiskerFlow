#!/usr/bin/env python3
"""Persist content-free reliability evidence across log rotation; no app mutations."""
import argparse
import datetime
import json
import math
import pathlib
import time
from zoneinfo import ZoneInfo


def build_identity(value):
    return value.strip() if isinstance(value, str) and value.strip() else None


def assess_build(state, build, builds, missing_sessions, missing_faults):
    selected = [s for s in state['sessions'].values()
                if build is not None and build_identity(s.get('build')) == build]
    completed = [s for s in selected if s.get('finish_ms') is not None
                 and s.get('paste_outcome') in ('verified', 'unverified') and 'samples' in s]
    faults = [f for f in state['faults'].values()
              if build is not None and isinstance(f, dict) and build_identity(f.get('build')) == build]
    days = sorted({s['day'] for s in completed})
    normal = sorted(s['finish_ms'] for s in completed if s['samples'] <= 960000)
    p95 = normal[max(0, math.ceil(len(normal) * .95) - 1)] if normal else None
    slow = [s for s in completed if s['finish_ms'] > max(5000, s['samples'] / 16000 * 100)]
    if missing_sessions or missing_faults:
        coverage = 'missing_build_identity'
    elif build is None and len(builds) > 1:
        coverage = 'ambiguous_builds'
    elif build not in builds:
        coverage = 'no_evidence'
    else:
        coverage = 'build_identified'
    passing = (coverage == 'build_identified' and len(completed) >= 50 and len(days) >= 3
               and not faults and not slow and p95 is not None and p95 <= 2000)
    return {'build': build, 'coverage': coverage, 'passing': passing,
            'completed_dictations': len(completed), 'active_days': days,
            'normal_dictation_finish_p95_ms': p95, 'slow_completions': len(slow),
            'fault_count': len(faults), 'missing_build_sessions': missing_sessions,
            'missing_build_faults': missing_faults,
            'unverified_deliveries': sum(s.get('paste_outcome') == 'unverified' for s in completed),
            'note': 'This is a runtime stability gate, not proof of transcript accuracy or verified insertion in every destination.'}


def assess(state, build=None):
    """Assess one identified build; retain separate summaries for other builds."""
    session_builds = [build_identity(s.get('build')) for s in state['sessions'].values()]
    fault_builds = [build_identity(f.get('build')) if isinstance(f, dict) else None
                    for f in state['faults'].values()]
    builds = sorted({b for b in session_builds + fault_builds if b is not None})
    selected = build_identity(build) or build_identity(state.get('target_build'))
    if selected is None and len(builds) == 1:
        selected = builds[0]
    missing_sessions = session_builds.count(None)
    missing_faults = fault_builds.count(None)
    result = assess_build(state, selected, builds, missing_sessions, missing_faults)
    result['builds'] = builds
    result['by_build'] = {b: assess_build(state, b, builds, missing_sessions, missing_faults)
                          for b in builds}
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--state', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parent.parent / '.codex/reliability-state.json')
    parser.add_argument('--directory', type=pathlib.Path, default=pathlib.Path.home() / 'Library/Logs/WhiskerFlow')
    parser.add_argument('--build', help='Assess this exact diagnostic build ID; otherwise use the saved selection or the sole observed build.')
    parser.add_argument('--reset', help='Start a fresh window after a relevant fix; supply its commit/build and reason.')
    args = parser.parse_args()
    if args.build is not None and build_identity(args.build) is None:
        parser.error('--build must contain a build ID')
    state = json.loads(args.state.read_text()) if args.state.exists() else None
    if state is None or args.reset:
        history = state.get('previous_windows', []) if state else []
        if state: history.append({'since': state['since'], 'reason': state['reason'], 'result': assess(state)})
        state = {'since': time.time(), 'reason': args.reset or 'Begin accepted stability gate', 'sessions': {}, 'faults': {}, 'previous_windows': history[-20:]}
    state['schema_version'] = 2
    if args.build is not None:
        state['target_build'] = build_identity(args.build)
    now = time.time()
    # Legacy measurements may be newer than the log rows still retained.
    # Preserve them until an event newer than the last ledger update arrives.
    migration_floor = state.get('updated_at', now)
    for entry in state['sessions'].values():
        observed = entry.setdefault('event_timestamps', {})
        for event, field in (('decode_returned', 'samples'), ('finish_returned', 'finish_ms'),
                             ('paste_returned', 'paste_outcome')):
            if field in entry:
                observed.setdefault(event, migration_floor)
    rows = []
    for path in sorted(args.directory.glob('diagnostics*.jsonl')):
        for line in path.open():
            try:
                row = json.loads(line)
                stamp = float(row.get('timestamp', 0))
            except (ValueError, TypeError, AttributeError):
                continue
            if state['since'] <= stamp <= now:
                rows.append(row)
    for row in sorted(rows, key=lambda r: float(r['timestamp'])):
        stamp = float(row['timestamp'])
        event = row.get('event')
        build = build_identity(row.get('build'))
        key = row.get('launch', '') + ':' + row.get('session', '')
        if row.get('session'):
            entry = state['sessions'].setdefault(key, {'day': datetime.datetime.fromtimestamp(stamp, ZoneInfo('Europe/London')).date().isoformat()})
            if build is not None:
                previous = build_identity(entry.get('build'))
                if entry.get('build_conflict') or (previous is not None and previous != build):
                    entry['build'] = None
                    entry['build_conflict'] = True
                else:
                    entry['build'] = build
            observed = entry.setdefault('event_timestamps', {})
            if stamp >= observed.get(event, -math.inf):
                if event == 'decode_returned': entry['samples'] = int(row['samples'])
                elif event == 'finish_returned': entry['finish_ms'] = float(row['elapsed_ms'])
                elif event == 'paste_returned': entry['paste_outcome'] = row.get('outcome')
                if event in ('decode_returned', 'finish_returned', 'paste_returned'):
                    observed[event] = stamp
        if event in ('main_thread_stalled', 'finish_timeout', 'stack_capture_failed') or (event == 'state_changed' and row.get('state') == 'failure') or (event == 'paste_returned' and row.get('outcome') in ('failed', 'copied')):
            state['faults'][row.get('launch', '') + ':' + str(stamp)] = {'event': event, 'build': build}
    state['updated_at'] = now
    state['result'] = assess(state)
    args.state.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.state.with_suffix('.tmp')
    temporary.write_text(json.dumps(state, indent=2) + '\n')
    temporary.replace(args.state)
    print(json.dumps({'since': state['since'], **state['result']}, indent=2))


if __name__ == '__main__': main()
