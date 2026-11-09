"""Timebox a preparation command; interrupt only the child started by this invocation."""
import argparse
import signal
import subprocess
import sys


def run(command, seconds):
    child = subprocess.Popen(command)
    try:
        return child.wait(timeout=seconds if seconds else None)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        print("Preparation interrupted/timeboxed; no test will start and no reuse receipt will be issued.", flush=True)
        child.send_signal(signal.SIGINT)
        try:
            child.wait(timeout=30)
        except subprocess.TimeoutExpired:
            print(f"Child {child.pid} has not exited. Inspect its exact descendants before more work; no force-kill attempted.", flush=True)
        return 124


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=600, help="Preparation cutoff; 0 requires explicit authorization for monitored completion")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or command[:2] != ["xcodebuild", "build-for-testing"] or args.seconds < 0:
        parser.error("Expected a nonnegative timebox and xcodebuild build-for-testing command")
    return run(command, args.seconds)


if __name__ == "__main__":
    sys.exit(main())
