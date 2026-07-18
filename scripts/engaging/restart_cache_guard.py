#!/usr/bin/env python3
"""Monitor a simulation cgroup and optionally release closed restart-file cache."""

import argparse
import csv
import datetime as dt
import os
import re
import signal
import sys
import time
from pathlib import Path


RESTART_PATTERN = re.compile(r"^jutul_(\d+)\.jld2$")
CSV_FIELDS = [
    "timestamp_utc",
    "elapsed_seconds",
    "process_alive",
    "pid_vm_rss_bytes",
    "pid_vm_hwm_bytes",
    "pid_vm_size_bytes",
    "pid_vm_peak_bytes",
    "pid_threads",
    "cgroup_usage_bytes",
    "cgroup_peak_bytes",
    "cgroup_limit_bytes",
    "cgroup_rss_bytes",
    "cgroup_cache_bytes",
    "cgroup_dirty_bytes",
    "cgroup_writeback_bytes",
    "cgroup_inactive_file_bytes",
    "cgroup_active_file_bytes",
    "restart_file_count",
    "restart_total_bytes",
    "evicted_file_count",
    "evicted_bytes",
    "eviction_errors",
    "last_evicted_step",
]


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Record process/cgroup memory and optionally call fsync plus "
            "POSIX_FADV_DONTNEED on completed Jutul restart files."
        )
    )
    parser.add_argument("--pid", type=int, required=True, help="Julia process ID")
    parser.add_argument("--restart-dir", type=Path, required=True)
    parser.add_argument("--log", type=Path, required=True, help="Output CSV path")
    parser.add_argument("--mode", choices=("monitor", "evict"), required=True)
    parser.add_argument("--interval", type=float, default=15.0)
    args = parser.parse_args()
    if args.pid <= 0:
        parser.error("--pid must be positive")
    if args.interval <= 0:
        parser.error("--interval must be positive")
    if args.mode == "evict" and not all(
        hasattr(os, name) for name in ("posix_fadvise", "POSIX_FADV_DONTNEED")
    ):
        parser.error("evict mode requires os.posix_fadvise and POSIX_FADV_DONTNEED")
    return args


def process_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return Path(f"/proc/{pid}").exists()


def read_key_values(path, separator=None):
    values = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (FileNotFoundError, PermissionError, ProcessLookupError):
        return values
    for line in lines:
        if separator is None:
            parts = line.split(None, 1)
        else:
            parts = line.split(separator, 1)
        if len(parts) == 2:
            values[parts[0].strip()] = parts[1].strip()
    return values


def integer_value(value):
    if value is None or value == "":
        return ""
    try:
        return int(value)
    except ValueError:
        return value


def read_process_status(pid):
    raw = read_key_values(Path(f"/proc/{pid}/status"), separator=":")

    def kibibytes(name):
        value = raw.get(name)
        if value is None:
            return ""
        fields = value.split()
        try:
            amount = int(fields[0])
        except (IndexError, ValueError):
            return ""
        return amount * 1024

    return {
        "pid_vm_rss_bytes": kibibytes("VmRSS"),
        "pid_vm_hwm_bytes": kibibytes("VmHWM"),
        "pid_vm_size_bytes": kibibytes("VmSize"),
        "pid_vm_peak_bytes": kibibytes("VmPeak"),
        "pid_threads": integer_value(raw.get("Threads")),
    }


def find_memory_cgroup(pid):
    entries = Path(f"/proc/{pid}/cgroup").read_text(encoding="utf-8").splitlines()
    unified_path = None
    memory_path = None
    for entry in entries:
        hierarchy, controllers, relative = entry.split(":", 2)
        if hierarchy == "0" and controllers == "":
            unified_path = relative
        if "memory" in controllers.split(","):
            memory_path = relative
    if memory_path is not None:
        return "v1", Path("/sys/fs/cgroup/memory") / memory_path.lstrip("/")
    if unified_path is not None:
        return "v2", Path("/sys/fs/cgroup") / unified_path.lstrip("/")
    raise RuntimeError(f"No memory cgroup found for PID {pid}")


def wait_for_memory_cgroup(pid, timeout=60.0):
    deadline = time.monotonic() + timeout
    last_error = None
    while time.monotonic() < deadline:
        try:
            return find_memory_cgroup(pid)
        except (FileNotFoundError, PermissionError, RuntimeError, ValueError) as error:
            last_error = error
            if not process_alive(pid):
                break
            time.sleep(0.2)
    raise RuntimeError(f"Could not resolve memory cgroup for PID {pid}: {last_error}")


def read_integer_file(path):
    try:
        return integer_value(path.read_text(encoding="utf-8").strip())
    except (FileNotFoundError, PermissionError):
        return ""


def read_cgroup_memory(version, root):
    if version == "v1":
        stats = read_key_values(root / "memory.stat")
        return {
            "cgroup_usage_bytes": read_integer_file(root / "memory.usage_in_bytes"),
            "cgroup_peak_bytes": read_integer_file(root / "memory.max_usage_in_bytes"),
            "cgroup_limit_bytes": read_integer_file(root / "memory.limit_in_bytes"),
            "cgroup_rss_bytes": integer_value(stats.get("rss")),
            "cgroup_cache_bytes": integer_value(stats.get("cache")),
            "cgroup_dirty_bytes": integer_value(stats.get("dirty")),
            "cgroup_writeback_bytes": integer_value(stats.get("writeback")),
            "cgroup_inactive_file_bytes": integer_value(stats.get("inactive_file")),
            "cgroup_active_file_bytes": integer_value(stats.get("active_file")),
        }

    stats = read_key_values(root / "memory.stat")
    limit = read_integer_file(root / "memory.max")
    return {
        "cgroup_usage_bytes": read_integer_file(root / "memory.current"),
        "cgroup_peak_bytes": read_integer_file(root / "memory.peak"),
        "cgroup_limit_bytes": limit,
        "cgroup_rss_bytes": integer_value(stats.get("anon")),
        "cgroup_cache_bytes": integer_value(stats.get("file")),
        "cgroup_dirty_bytes": integer_value(stats.get("file_dirty")),
        "cgroup_writeback_bytes": integer_value(stats.get("file_writeback")),
        "cgroup_inactive_file_bytes": integer_value(stats.get("inactive_file")),
        "cgroup_active_file_bytes": integer_value(stats.get("active_file")),
    }


def restart_files(restart_dir):
    files = []
    try:
        candidates = restart_dir.iterdir()
    except FileNotFoundError:
        return files
    for path in candidates:
        match = RESTART_PATTERN.match(path.name)
        if match is None or path.is_symlink():
            continue
        try:
            stat = path.stat()
        except FileNotFoundError:
            continue
        if path.is_file():
            files.append((int(match.group(1)), path, stat))
    files.sort(key=lambda item: item[0])
    return files


def release_file_cache(path):
    descriptor = os.open(path, os.O_RDWR)
    try:
        os.fsync(descriptor)
        os.posix_fadvise(descriptor, 0, 0, os.POSIX_FADV_DONTNEED)
    finally:
        os.close(descriptor)


def main():
    args = parse_args()
    args.log.parent.mkdir(parents=True, exist_ok=True)
    cgroup_version, cgroup_root = wait_for_memory_cgroup(args.pid)
    started = time.monotonic()
    processed = {}
    evicted_count = 0
    evicted_bytes = 0
    eviction_errors = 0
    last_evicted_step = ""

    with args.log.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=CSV_FIELDS)
        writer.writeheader()
        stream.flush()

        while True:
            alive = process_alive(args.pid)
            files = restart_files(args.restart_dir)

            if args.mode == "evict" and files:
                highest_step = files[-1][0]
                for step, path, stat in files:
                    # Jutul writes restarts in order. While it is alive, the
                    # highest numbered file may still be open; earlier files
                    # are complete and can be flushed and released safely.
                    if alive and step == highest_step:
                        continue
                    signature = (stat.st_size, stat.st_mtime_ns)
                    if processed.get(path) == signature:
                        continue
                    try:
                        release_file_cache(path)
                    except OSError as error:
                        eviction_errors += 1
                        print(
                            f"cache release failed for {path}: {error}",
                            file=sys.stderr,
                            flush=True,
                        )
                        continue
                    processed[path] = signature
                    evicted_count += 1
                    evicted_bytes += stat.st_size
                    last_evicted_step = step

            process_status = read_process_status(args.pid) if alive else {
                "pid_vm_rss_bytes": "",
                "pid_vm_hwm_bytes": "",
                "pid_vm_size_bytes": "",
                "pid_vm_peak_bytes": "",
                "pid_threads": "",
            }
            row = {
                "timestamp_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
                "elapsed_seconds": f"{time.monotonic() - started:.3f}",
                "process_alive": int(alive),
                **process_status,
                **read_cgroup_memory(cgroup_version, cgroup_root),
                "restart_file_count": len(files),
                "restart_total_bytes": sum(item[2].st_size for item in files),
                "evicted_file_count": evicted_count,
                "evicted_bytes": evicted_bytes,
                "eviction_errors": eviction_errors,
                "last_evicted_step": last_evicted_step,
            }
            writer.writerow(row)
            stream.flush()

            if not alive:
                break
            time.sleep(args.interval)

    return 2 if eviction_errors else 0


if __name__ == "__main__":
    # Keep ordinary termination quiet when Slurm cancels the simulation.
    signal.signal(signal.SIGTERM, lambda _signum, _frame: sys.exit(143))
    raise SystemExit(main())
