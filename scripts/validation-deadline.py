#!/usr/bin/env python3
"""One monotonic budget for a validation stage and all of its descendants."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--stage', required=True)
    parser.add_argument('--report')
    parser.add_argument('--seconds', type=float, default=600)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command or not 0 < args.seconds <= 600:
        parser.error('a command and a budget in (0, 600] are required')
    started = time.monotonic()
    deadline = min(started + args.seconds, float(os.environ.get('AEON_VALIDATION_DEADLINE', 'inf')))
    env = dict(os.environ, AEON_VALIDATION_DEADLINE=str(deadline))
    child = None
    timed_out = False
    result = 124
    try:
        if deadline <= started:
            raise subprocess.TimeoutExpired(command, 0)
        child = subprocess.Popen(command, env=env, start_new_session=True)
        result = child.wait(timeout=max(0, deadline - time.monotonic()))
    except subprocess.TimeoutExpired:
        timed_out = True
        if child is not None:
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                pass
            # Kill descendants even when the process-group leader exited on TERM.
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        print(f'TIMEOUT: {args.stage}; work stopped; no retry authorized.', file=sys.stderr, flush=True)
    report = dict(stage=args.stage, command=command, source_sha=os.environ.get('GITHUB_SHA'),
                  elapsed_seconds=round(time.monotonic() - started, 3), budget_seconds=args.seconds,
                  timed_out=timed_out, exit_code=124 if timed_out else result)
    if args.report:
        path = Path(args.report)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report), flush=True)
    return report['exit_code']


if __name__ == '__main__':
    sys.exit(main())
