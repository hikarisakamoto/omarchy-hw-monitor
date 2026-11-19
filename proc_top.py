#!/usr/bin/python3
"""Top-N processes by RSS memory or CPU, optionally grouped per application.

Usage: proc_top.py [--top N] [--sort ram|cpu] [--group]
Output: {"groupedBy": "none"|"scope"|"comm", "procs": [{"pid": 1234,
  "name": "firefox", "count": 12, "cpu": 12.3, "rssKib": 1234567,
  "memPct": 5.3}]}
Pipeline: collect -> group -> sum -> sort -> cut. CPU is normalised to the
whole system (100% = all cores), measured across two reads ~400 ms apart.
Grouping: systemd identity from the deepest token (scope/service; containers
such as app-graphical.slice skipped; cleaned-up pretty name); fallback to an
equal comm; sep-prefix merge ("orca" absorbs "orca-ide"). Without an
identity: single processes or per-comm. No child expansion.
Errors: {} on stdout, one line on stderr, exit 0 (refuse-softly).
Stdlib only, no network, no writes.
"""

import json
import os
import re
import sys
import time

TOP_DEFAULT = 6
TOP_MIN = 3
TOP_MAX = 12
PID_CAP = 4096
NAME_MAX = 48
SNAP_GAP_S = 0.4
SORTS = ("ram", "cpu")

# App identity from the cgroup (measured on a Hyprland/systemd host, not assumed):
# - deepest token ending in .scope/.service (e.g. app-Hyprland-zen\x2dbin-
#   XXXX.scope, app-orca-3236.scope, orca-daemon-UUID.scope, *.service in app.slice)
# - containers are skipped: app-graphical.slice, app-dbus-*, app-glib-*, units
#   with '@' (sessions, e.g. wayland-wm@*.service): grouping them would merge
#   the whole desktop.
# - pretty: unescape \\xNN, drop `app-`, drop a leading `Hyprland-` (launcher),
#   drop a `-hex{4,}` suffix, keep the last dotted segment, then sanitize_name.
CONTAINER_EXACT = ("app-graphical.slice",)
CONTAINER_PREFIX = ("app-dbus-", "app-glib-")
# Never an identity: generic systemd containers left over after stripping.
GENERIC_BASES = ("app", "user", "system", "init", "session")


def unescape_unit(text: str) -> str:
    def sub(match):
        try:
            return chr(int(match.group(1), 16))
        except ValueError:
            return "?"
    return re.sub(r"\\x([0-9a-fA-F]{2})", sub, text)


def app_identity(cgline: str) -> str:
    if not cgline:
        return ""
    for seg in reversed(cgline.strip().split("/")):
        if "@" in seg:
            continue
        if seg in CONTAINER_EXACT or seg.startswith(CONTAINER_PREFIX):
            continue
        # Only tokens that carry an identity: an app- prefix or a scope/service
        # unit. `app.slice`/`user.slice`/`session.slice` neither start with
        # app- nor are scope/service, so they are dropped here.
        if not (seg.startswith("app-") or seg.endswith((".scope", ".service"))):
            continue
        if seg.endswith(".scope") or seg.endswith(".service"):
            base = seg.rsplit(".", 1)[0]
        elif seg.endswith(".slice"):
            base = seg[:-len(".slice")]
        else:
            continue
        base = unescape_unit(base)
        if base.startswith("app-"):
            base = base[len("app-"):]
        if base.startswith("Hyprland-"):
            base = base[len("Hyprland-"):]
        base = re.sub(r"(-[0-9a-fA-F]{4,})+$", "", base)
        if "." in base:
            base = base.split(".")[-1]
        if base in GENERIC_BASES:
            continue
        pretty = sanitize_name(base)
        if pretty and pretty != "?":
            return pretty
    return ""

# Spaces and parens are legitimate in real names (e.g. "Isolated Web Co").
NAME_OK = set(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    "._+:@/ -()")


def sanitize_name(raw: object) -> str:
    text = str(raw or "").strip().replace("\n", " ").replace("\t", " ")
    out = "".join(c if c in NAME_OK else "\u00b7" for c in text)
    out = " ".join(out.split())
    if len(out) > NAME_MAX:
        out = out[:NAME_MAX]
    return out if out else "?"


def read_mem_total_kib() -> int:
    try:
        with open("/proc/meminfo", "r", encoding="utf-8",
                  errors="replace") as fh:
            for line in fh:
                if line.startswith("MemTotal:"):
                    return int(line.split()[1])
    except OSError:
        pass
    return 0


def read_sys_total() -> int:
    try:
        with open("/proc/stat", "r", encoding="utf-8",
                  errors="replace") as fh:
            parts = fh.readline().split()
        if len(parts) >= 5 and parts[0] == "cpu":
            return sum(int(p) for p in parts[1:9])
    except (OSError, ValueError):
        pass
    return 0


def read_cgroup_first(pid: int) -> str:
    try:
        with open("/proc/%d/cgroup" % pid, "r", encoding="utf-8",
                  errors="replace") as fh:
            return fh.readline().strip()
    except OSError:
        return ""


def list_pids() -> list[int]:
    """Numeric /proc entries, at most PID_CAP of them."""
    try:
        entries = os.listdir("/proc")
    except OSError:
        return []
    return [int(e) for e in entries if e.isdigit()][:PID_CAP]


def read_stat(pid: int) -> tuple[str, int, int]:
    """(comm, utime+stime ticks, rss_pages) from /proc/<pid>/stat.

    comm is the parenthesised field and may itself contain ")", so the line
    is split at the last one. Raises OSError, ValueError or IndexError when
    the pid is gone or the line is malformed.
    """
    with open("/proc/%d/stat" % pid, "r", encoding="utf-8",
              errors="replace") as fh:
        stat = fh.read()
    head, rest = stat.rsplit(")", 1)
    tail = rest.split()
    return head.partition("(")[2], int(tail[11]) + int(tail[12]), int(tail[21])


def cpu_ticks() -> dict[int, int]:
    """First pass: {pid: utime+stime}; only the CPU time is needed from it."""
    ticks = {}
    for pid in list_pids():
        try:
            ticks[pid] = read_stat(pid)[1]
        except (OSError, ValueError, IndexError):
            continue
    return ticks


def sample_procs(ticks_a: dict[int, int], sys_delta: int, page_kib: int,
                 group: bool) -> list[dict]:
    """Second pass: one record per pid present in both passes.

    cpu is the pid's share of all CPU time spent between the passes (not yet
    clamped: make_row clamps the final figure); ident is the systemd app
    identity, read only when grouping.
    """
    procs = []
    for pid in list_pids():
        old = ticks_a.get(pid)
        if old is None:
            continue
        try:
            comm, ticks, rss_pages = read_stat(pid)
        except (OSError, ValueError, IndexError):
            continue
        dproc = ticks - old
        cpu = 100.0 * dproc / sys_delta if sys_delta > 0 and dproc >= 0 else 0.0
        procs.append({
            "pid": pid,
            "comm": sanitize_name(comm),
            "ident": app_identity(read_cgroup_first(pid)) if group else "",
            "cpu": cpu,
            "rssKib": rss_pages * page_kib,
        })
    return procs


def merge_key(name: str) -> str:
    return name.lower()


def mergeable(shorter: str, longer: str) -> bool:
    if shorter == longer:
        return True
    return any(longer.startswith(shorter + sep) for sep in ("-", "_", "."))


def group_by_app(procs: list[dict]) -> list[tuple[str, list[dict]]]:
    """Bucket processes per application: [(display name, members)].

    Bucket by key (systemd identity when present, else comm), then sep-prefix
    merge: "orca" absorbs "orca-ide", with no false merges on alphanumeric
    extensions ("pi" does not absorb "pipewire").
    """
    buckets = {}
    for p in procs:
        label = p["ident"] if p["ident"] else p["comm"]
        buckets.setdefault(merge_key(label), []).append((label, p))
    canon = {}
    for key in sorted(buckets, key=len):
        target = None
        for done in canon:
            if mergeable(done, key):
                target = done
                break
        if target is None:
            target = key
        buckets[target].extend(buckets[key] if target != key else [])
        ident_labels = [lab for lab, m in buckets[target] if m["ident"]]
        canon[target] = ident_labels[0] if ident_labels else buckets[target][0][0]
    return [(canon[key], [p for _lab, p in members])
            for key, members in buckets.items() if key in canon]


def make_row(name: str, members: list[dict], mem_total: int) -> dict:
    """The output row for a group of processes; a lone process is a group of
    one and keeps its own comm, so the panel shows it as "comm (pid)".

    pid is the member with the largest RSS; cpu and rssKib are sums, clamped
    and rounded here because a sum can overshoot 100% on read skew.
    """
    lead = max(members, key=lambda p: p["rssKib"])
    rss_kib = int(sum(p["rssKib"] for p in members))
    cpu = max(0.0, min(100.0, sum(p["cpu"] for p in members)))
    mem_pct = 100.0 * rss_kib / mem_total if mem_total > 0 else 0.0
    return {
        "pid": lead["pid"],
        "name": name if len(members) > 1 else lead["comm"],
        "count": len(members),
        "cpu": round(cpu, 1),
        "rssKib": rss_kib,
        "memPct": round(max(0.0, min(100.0, mem_pct)), 1),
    }


def build_rows(procs: list[dict], mem_total: int,
               group: bool) -> tuple[list[dict], str]:
    """Rows in sample order plus the groupedBy value for the JSON."""
    if not group:
        return [make_row(p["comm"], [p], mem_total) for p in procs], "none"
    # "scope" as soon as any process has a systemd identity; the others still
    # fall back to their comm individually.
    grouped_by = "scope" if any(p["ident"] for p in procs) else "comm"
    return ([make_row(name, members, mem_total)
             for name, members in group_by_app(procs)], grouped_by)


def main(argv: list[str]) -> None:
    top_n = TOP_DEFAULT
    sort = "ram"
    group = False
    i = 1
    while i < len(argv):
        if argv[i] == "--top" and i + 1 < len(argv):
            try:
                top_n = int(argv[i + 1])
            except ValueError:
                top_n = TOP_DEFAULT
            i += 2
        elif argv[i] == "--sort" and i + 1 < len(argv):
            cand = argv[i + 1].strip().lower()
            sort = cand if cand in SORTS else "ram"
            i += 2
        elif argv[i] == "--group":
            group = True
            i += 1
        else:
            i += 1
    top_n = max(TOP_MIN, min(TOP_MAX, top_n))

    try:
        page_kib = os.sysconf("SC_PAGE_SIZE") // 1024
    except (OSError, ValueError):
        page_kib = 4
    mem_total = read_mem_total_kib()

    sys_a = read_sys_total()
    ticks_a = cpu_ticks()
    time.sleep(SNAP_GAP_S)
    sys_b = read_sys_total()
    procs = sample_procs(ticks_a, sys_b - sys_a, page_kib, group)

    rows, grouped_by = build_rows(procs, mem_total, group)
    key = (lambda r: r["rssKib"]) if sort == "ram" else (lambda r: r["cpu"])
    rows.sort(key=key, reverse=True)
    sys.stdout.write(json.dumps({"groupedBy": grouped_by,
                                 "procs": rows[:top_n]},
                                ensure_ascii=True) + "\n")


if __name__ == "__main__":
    try:
        main(sys.argv)
    except BrokenPipeError:
        pass
    except Exception as exc:  # refuse-softly: never a noisy traceback
        sys.stderr.write("proc_top: %s\n" % exc)
        sys.stdout.write("{}\n")
