#!/usr/bin/env python3
"""Sample a running macOS candidate without reading app data or process arguments."""
import argparse
import datetime
import json
import re
import shutil
import subprocess
import time


def command(*arguments):
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=15)
    return result.stdout.strip() if result.returncode == 0 else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", required=True, type=int)
    parser.add_argument("--output", required=True)
    parser.add_argument("--seconds", type=int, default=1800)
    args = parser.parse_args()
    started = time.monotonic()
    with open(args.output, "w", buffering=1) as output:
        output.write(json.dumps({"kind": "host", "model": command("sysctl", "-n", "hw.model"),
                                 "memoryBytes": command("sysctl", "-n", "hw.memsize"),
                                 "cores": command("sysctl", "-n", "hw.logicalcpu"),
                                 "os": command("sw_vers", "-productVersion"), "pid": args.pid}) + "\n")
        sample = 0
        while time.monotonic() - started < args.seconds:
            row = command("ps", "-p", str(args.pid), "-o", "rss=,%cpu=")
            record = {"kind": "sample", "at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                      "elapsedSeconds": round(time.monotonic() - started, 2),
                      "diskFreeBytes": shutil.disk_usage("/").free}
            if not row:
                record["processExited"] = True
                output.write(json.dumps(record) + "\n")
                break
            rss, cpu = row.split()
            record.update(rssBytes=int(rss) * 1024, cpuPercent=float(cpu))
            if sample % 5 == 0:
                record["swap"] = command("sysctl", "-n", "vm.swapusage")
                record["pressureLevel"] = command("sysctl", "-n", "kern.memorystatus_vm_pressure_level")
                summary = command("vmmap", "-summary", str(args.pid)) or ""
                for label, key in [("Physical footprint", "physicalFootprint"),
                                   ("Physical footprint (peak)", "peakPhysicalFootprint")]:
                    match = re.search(r"^" + re.escape(label) + r":\s*(.+)$", summary, re.MULTILINE)
                    if match:
                        record[key] = match.group(1)
            output.write(json.dumps(record) + "\n")
            sample += 1
            time.sleep(2)


if __name__ == "__main__":
    main()
