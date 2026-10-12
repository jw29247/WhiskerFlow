#!/usr/bin/env python3
"""Persist content-free reliability evidence across log rotation; no app mutations."""
import argparse
import datetime
import json
import math
import pathlib
import time
from zoneinfo import ZoneInfo


def assess(state):
    completed = [s for s in state['sessions'].values() if s.get('finish_ms') is not None and s.get('paste_outcome') in ('verified', 'unverified') and 'samples' in s]
    days = sorted({s['day'] for s in completed})
    normal = sorted(s['finish_ms'] for s in completed if s['samples'] <= 960000)
    p95 = normal[max(0, math.ceil(len(normal) * .95) - 1)] if normal else None
    slow = [s for s in completed if s['finish_ms'] > max(5000, s['samples'] / 16000 * 100)]
    passing = len(completed) >= 50 and len(days) >= 3 and not state['faults'] and not slow and p95 is not None and p95 <= 2000
    return {'passing': passing, 'completed_dictations': len(completed), 'active_days': days,
            'normal_dictation_finish_p95_ms': p95, 'slow_completions': len(slow),
            'fault_count': len(state['faults']),
            'unverified_deliveries': sum(s.get('paste_outcome') == 'unverified' for s in completed),
            'note': 'This is a runtime stability gate, not proof of transcript accuracy or verified insertion in every destination.'}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--state', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parent.parent / '.codex/reliability-state.json')
    parser.add_argument('--reset', help='Start a fresh window after a relevant fix; supply its commit/build and reason.')
    args = parser.parse_args()
    state = json.loads(args.state.read_text()) if args.state.exists() else None
    if state is None or args.reset:
        history = state.get('previous_windows', []) if state else []
        if state: history.append({'since': state['since'], 'reason': state['reason'], 'result': assess(state)})
        state = {'since': time.time(), 'reason': args.reset or 'Begin accepted stability gate', 'sessions': {}, 'faults': {}, 'previous_windows': history[-20:]}
    for path in (pathlib.Path.home() / 'Library/Logs/WhiskerFlow').glob('diagnostics*.jsonl'):
        for line in path.open():
            try: row = json.loads(line)
            except ValueError: continue
            stamp = float(row.get('timestamp', 0))
            if stamp < state['since']: continue
            event = row.get('event')
            key = row.get('launch', '') + ':' + row.get('session', '')
            if row.get('session'):
                entry = state['sessions'].setdefault(key, {'day': datetime.datetime.fromtimestamp(stamp, ZoneInfo('Europe/London')).date().isoformat()})
                if event == 'decode_returned': entry['samples'] = int(row['samples'])
                if event == 'finish_returned': entry['finish_ms'] = float(row['elapsed_ms'])
                if event == 'paste_returned': entry['paste_outcome'] = row.get('outcome')
            if event in ('main_thread_stalled', 'finish_timeout', 'stack_capture_failed') or (event == 'state_changed' and row.get('state') == 'failure') or (event == 'paste_returned' and row.get('outcome') in ('failed', 'copied')):
                state['faults'][row.get('launch', '') + ':' + str(stamp)] = event
    state['updated_at'] = time.time()
    state['result'] = assess(state)
    args.state.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.state.with_suffix('.tmp')
    temporary.write_text(json.dumps(state, indent=2) + '\n')
    temporary.replace(args.state)
    print(json.dumps({'since': state['since'], **state['result']}, indent=2))


if __name__ == '__main__': main()
