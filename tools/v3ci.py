"""Distributed build of one derivation closure on GitHub Actions runners.

Subcommands, in the order the build workflow runs them:

  plan      dry-run the target, read the .drv files of everything that is not
            substitutable, estimate build times and list-schedule the DAG over
            N runners (critical path first, a runner prefers the one that
            built a node's heaviest input). Nodes that cannot finish inside
            the job budget are deferred to the next run; nodes that could
            never finish in one job are reported as too big.
  execute   one runner: build its share in plan order, at most --jobs builds
            at a time, and wait for inputs that other runners build until
            their outputs appear in the binary cache (the cachix daemon of
            the job pushes every finished path right away).
  finalize  merge the measured build times, count built, failed and
            remaining nodes, and write the job summary.

Derivations with allowSubstitutes = false (NixOS etc files, units, wrappers)
are never substituted, so they are not scheduled: whoever needs them builds
them in seconds. The scheduler looks through them to the real inputs.

Only the Python standard library is used; nix, nix-store and timeout come
from PATH.
"""

import argparse
import concurrent.futures
import heapq
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

STORE = "/nix/store/"

# Seconds on a 4-vCPU ubuntu-latest runner for a whole pname, used until a
# build was measured; measured times (build-times.json) win. Wrappers
# (gcc-wrapper, firefox) are not here on purpose: they take seconds.
HEURISTICS = {
    **dict.fromkeys(["ungoogled-chromium-unwrapped", "chromium-unwrapped", "electron-unwrapped"], 14 * 3600),
    # Above the budget's reach on paper, but worth one attempt: a timeout is
    # recorded and makes it "too big" from then on.
    "qtwebengine": 5 * 3600,
    **dict.fromkeys(["firefox-unwrapped", "thunderbird-unwrapped", "libreoffice"], 6 * 3600),
    **dict.fromkeys(["webkitgtk", "onnxruntime", "dotnet-vmr", "dotnet-stage0-vmr"], 3 * 3600),
    **dict.fromkeys(["ghc", "llvm", "mlir", "flang", "openvino", "opencv"], 7200),
    **dict.fromkeys(["rustc-unwrapped", "clang", "gcc", "nodejs-slim", "spidermonkey", "qtbase", "openjdk"], 3600),
    **dict.fromkeys(["xgcc", "glibc", "mesa", "qtdeclarative", "boost", "go", "gtk4", "gtk+3", "python3", "zed-editor"], 1800),
    **dict.fromkeys(["perl", "cmake", "binutils", "systemd", "ffmpeg", "ffmpeg-full", "ffmpeg-headless"], 900),
}
DEFAULT_SECONDS = 240
# Compressed NAR bytes per node when nothing is known (median-ish package).
DEFAULT_BYTES = 20 * 2**20

VERSION_RE = re.compile(r"-[0-9][^-]*.*$")


def pname(name):
    return VERSION_RE.sub("", name)


def log(*args):
    print(*args, file=sys.stderr, flush=True)


# --- .drv parsing (ATerm) ---------------------------------------------------

def parse_aterm(text):
    """Parse a Derive(...) ATerm into nested Python lists and strings."""
    pos = 0
    n = len(text)

    def value():
        nonlocal pos
        c = text[pos]
        if c == '"':
            pos += 1
            out = []
            while True:
                j = pos
                while text[j] not in '"\\':
                    j += 1
                out.append(text[pos:j])
                pos = j
                if text[pos] == '"':
                    pos += 1
                    return "".join(out)
                esc = text[pos + 1]
                out.append({"n": "\n", "r": "\r", "t": "\t"}.get(esc, esc))
                pos += 2
        if c in "[(":
            close = "]" if c == "[" else ")"
            pos += 1
            items = []
            while text[pos] != close:
                items.append(value())
                if text[pos] == ",":
                    pos += 1
            pos += 1
            return items
        j = pos
        while j < n and text[j] not in "([":
            j += 1
        pos = j
        return value()

    return value()


def read_drv(path):
    with open(path, encoding="utf-8", errors="surrogateescape") as f:
        outputs, input_drvs, _srcs, _platform, _builder, _args, env = parse_aterm(f.read())
    env = dict(env)
    attrs = env
    if "__json" in env:
        attrs = dict(env)
        attrs.update(json.loads(env["__json"]))
    allow = attrs.get("allowSubstitutes", True)
    trivial = allow in ("", "0", False)
    return {
        "name": env.get("name") or attrs.get("name") or path[len(STORE) + 33:-4],
        "outputs": [o[1] for o in outputs if o[1]],
        "inputs": [d[0] for d in input_drvs],
        "trivial": trivial,
        "fixed": any(o[2] for o in outputs),
    }


# --- nix helpers -------------------------------------------------------------

def dry_run(drv):
    """Return (to_build, to_fetch) store paths of realising drv."""
    proc = subprocess.run(
        ["nix-store", "--realise", "--dry-run", drv],
        capture_output=True, text=True, check=False,
    )
    if proc.returncode != 0:
        log(proc.stderr)
        raise SystemExit("dry run failed")
    build, fetch, section = [], [], None
    for line in proc.stderr.splitlines():
        if "will be built" in line:
            section = build
        elif "will be fetched" in line:
            section = fetch
        elif line.startswith("  " + STORE) and section is not None:
            section.append(line.strip())
        else:
            section = None
    return build, fetch


def narinfo_url(cache, path):
    return f"{cache.rstrip('/')}/{path[len(STORE):len(STORE) + 32]}.narinfo"


# cachix (behind Cloudflare) answers 403 to urllib's default User-Agent.
USER_AGENT = "nixpkgs-v3-ci/1"


def in_cache(cache, path):
    req = urllib.request.Request(narinfo_url(cache, path), method="HEAD", headers={"User-Agent": USER_AGENT})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                return resp.status == 200
        except urllib.error.HTTPError as err:
            if err.code == 404:
                return False
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            pass
        time.sleep(2 * (attempt + 1))
    return False


def cached_many(cache, paths, workers=32):
    paths = list(paths)
    with concurrent.futures.ThreadPoolExecutor(workers) as pool:
        found = pool.map(lambda p: in_cache(cache, p), paths)
        return {p for p, ok in zip(paths, found) if ok}


def path_info(store, paths):
    """narSize and fileSize (compressed) of paths in a binary cache."""
    out = {}
    paths = list(paths)
    for i in range(0, len(paths), 500):
        chunk = paths[i:i + 500]
        proc = subprocess.run(
            ["nix", "path-info", "--json", "--store", store, *chunk],
            capture_output=True, text=True, check=False,
        )
        try:
            data = json.loads(proc.stdout or "{}")
        except json.JSONDecodeError:
            continue
        items = data.items() if isinstance(data, dict) else ((d.get("path"), d) for d in data)
        for path, info in items:
            if info:
                key = path if path.startswith(STORE) else STORE + path
                out[key] = info
    return out


# --- estimates ---------------------------------------------------------------

def estimate(name, times):
    if name in times.get("name", {}):
        return times["name"][name]
    p = pname(name)
    if p in times.get("pname", {}):
        return times["pname"][p]
    return HEURISTICS.get(p, DEFAULT_SECONDS)


def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return default


# --- plan ----------------------------------------------------------------------

def build_graph(to_build, local_only=None):
    """Read every to-build .drv; contract trivial nodes into real edges.

    local_only (a regex on the name) marks cheap intermediates (source
    copies, vendored dependencies) that the cachix push filter skips: like
    trivial nodes they are rebuilt by whoever needs them, never waited for.
    """
    drvs = {d: read_drv(d) for d in to_build}
    if local_only:
        pattern = re.compile(local_only)
        for info in drvs.values():
            if pattern.search(info["name"]):
                info["trivial"] = True
    todo = set(drvs)
    memo = {}

    def real_deps(d):
        if d in memo:
            return memo[d]
        memo[d] = set()  # cycle guard; a derivation graph has none
        deps = set()
        for i in drvs[d]["inputs"]:
            if i not in todo:
                continue
            if drvs[i]["trivial"]:
                deps |= real_deps(i)
            else:
                deps.add(i)
        memo[d] = deps
        return deps

    nodes = {d: info for d, info in drvs.items() if not info["trivial"]}
    for d, info in nodes.items():
        info["deps"] = sorted(real_deps(d))
    return drvs, nodes


def schedule(nodes, machines, budget, delay, size_cap=None):
    children = {d: [] for d in nodes}
    for d, info in nodes.items():
        for dep in info["deps"]:
            children[dep].append(d)

    # Bottom level: longest estimated path from a node to the end.
    order, seen = [], set()
    for root in nodes:
        stack = [(root, False)]
        while stack:
            d, done = stack.pop()
            if done:
                order.append(d)
                continue
            if d in seen:
                continue
            seen.add(d)
            stack.append((d, True))
            stack.extend((c, False) for c in children[d] if c not in seen)
    bottom = {}
    for d in order:
        bottom[d] = nodes[d]["est"] + max((bottom[c] for c in children[d]), default=0)

    missing = {d: len(info["deps"]) for d, info in nodes.items()}
    ready = [(-bottom[d], d) for d, m in missing.items() if m == 0]
    heapq.heapify(ready)
    free = [0.0] * machines
    lists = [[] for _ in range(machines)]
    toobig, deferred = [], []
    pushed = 0
    while ready:
        _, d = heapq.heappop(ready)
        info = nodes[d]
        if info["est"] > budget:
            toobig.append(d)
            continue
        best = None
        heaviest = max(info["deps"], key=lambda x: nodes[x]["est"], default=None)
        for m in range(machines):
            start = free[m]
            for dep in info["deps"]:
                lag = 0 if nodes[dep]["machine"] == m else delay
                start = max(start, nodes[dep]["finish"] + lag)
            prefer = heaviest is not None and nodes[heaviest]["machine"] == m
            key = (start, not prefer, m)
            if best is None or key < best[0]:
                best = (key, m, start)
        _, m, start = best
        if start + info["est"] > budget or (size_cap is not None and pushed + info["bytes"] > size_cap):
            deferred.append(d)
            continue
        pushed += info["bytes"]
        info.update(machine=m, start=start, finish=start + info["est"])
        free[m] = info["finish"]
        lists[m].append(d)
        for c in children[d]:
            missing[c] -= 1
            if missing[c] == 0:
                heapq.heappush(ready, (-bottom[c], c))
    blocked = [d for d, info in nodes.items() if info.get("machine") is None and d not in deferred and d not in toobig]
    return lists, toobig, deferred, blocked, bottom


def cmd_plan(args):
    t0 = time.time()
    to_build, to_fetch = dry_run(args.drv)
    log(f"dry run: {len(to_build)} to build, {len(to_fetch)} to fetch ({time.time() - t0:.0f}s)")
    times = load_json(args.times, {})
    drvs, nodes = build_graph(to_build, args.local_only)
    twin = twin_sizes(args.generic, nodes) if args.generic else {}
    for d, info in nodes.items():
        info["est"] = estimate(info["name"], times)
        info["measured"] = info["name"] in times.get("name", {})
        info["machine"] = None
        nar = times.get("nar", {}).get(info["name"])
        info["bytes"] = int(nar * COMPRESSION) if nar else twin.get(info["name"], DEFAULT_BYTES)
    world_bytes = sum(i["bytes"] for i in nodes.values())
    quota = args.quota_gb * 2**30
    # With the world larger than the cache, LRU eviction would drop paths of
    # this very build while it runs. Build a bounded share once and stop the
    # chain instead of thrashing; the summary says what to change.
    capped = world_bytes > 0.8 * quota
    size_cap = 0.4 * quota if capped else None
    lists, toobig, deferred, blocked, bottom = schedule(nodes, args.machines, args.budget, args.delay, size_cap)

    critical = max(bottom.values(), default=0)
    plan = {
        "target": args.drv,
        "created": int(time.time()),
        "budget": args.budget,
        "cache": args.cache,
        "machines": [{"index": m, "nodes": lst} for m, lst in enumerate(lists) if lst],
        "nodes": {
            d: {k: info.get(k) for k in ("name", "outputs", "deps", "est", "measured", "machine", "finish")}
            for d, info in nodes.items()
        },
        "toobig": toobig,
        "deferred": deferred,
        "blocked": blocked,
        "capped": capped,
        "stats": {
            "to_build": len(to_build),
            "trivial": len(to_build) - len(nodes),
            "real": len(nodes),
            "scheduled": sum(len(lst) for lst in lists),
            "est_cpu_hours_total": round(sum(i["est"] for i in nodes.values()) * 4 / 3600, 1),
            "est_runner_hours_total": round(sum(i["est"] for i in nodes.values()) / 3600, 1),
            "critical_path_hours": round(critical / 3600, 1),
            "to_fetch": len(to_fetch),
            "world_gib": round(world_bytes / 2**30, 1),
            "quota_gib": args.quota_gb,
        },
    }
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(plan, f)
    matrix = [m["index"] for m in plan["machines"]]
    s = plan["stats"]
    lines = [
        f"## Plan for `{os.path.basename(args.drv)}`",
        "",
        f"- not substitutable: {s['to_build']} derivations ({s['trivial']} trivial, {s['real']} real)",
        f"- scheduled this run: {s['scheduled']} on {len(matrix)} runners; deferred {len(deferred)}; "
        f"blocked behind deferred/too big {len(blocked)}",
        f"- estimate for everything left: {s['est_runner_hours_total']} runner-hours "
        f"({s['est_cpu_hours_total']} CPU-hours), critical path {s['critical_path_hours']} h",
    ]
    lines.append(f"- estimated compressed size of everything left: {s['world_gib']} GiB; cache quota {args.quota_gb} GiB")
    if capped:
        lines += [
            "",
            f"> **Cache too small.** The rest of the world (~{s['world_gib']} GiB compressed) does not fit the "
            f"{args.quota_gb} GiB quota; LRU eviction would throw away this build while it runs. This run builds a "
            f"bounded share (up to {0.4 * args.quota_gb:.1f} GiB) and does not re-dispatch. Raise the cachix plan, then set "
            "the repository variable `CACHIX_QUOTA_GB` to its size.",
            "",
        ]
    if toobig:
        lines.append(f"- **too big for one {args.budget / 3600:.1f} h job** (need a fallback):")
        lines += [f"  - `{nodes[d]['name']}` (est. {nodes[d]['est'] / 3600:.1f} h)" for d in toobig]
    top = sorted(nodes.values(), key=lambda i: -i["est"])[:15]
    lines += ["", "| largest estimates | h |", "|---|---|"]
    lines += [f"| `{i['name']}` | {i['est'] / 3600:.2f} |" for i in top]
    summary(args.summary, "\n".join(lines))
    print(json.dumps({"matrix": matrix, "real": s["real"], "scheduled": s["scheduled"], "capped": capped}))


COMPRESSION = 0.35  # zstd NAR / NAR, roughly, for a mixed package set


def twin_sizes(generic_drv, nodes):
    """Compressed size of each node's baseline twin on cache.nixos.org."""
    closure = subprocess.run(["nix-store", "-qR", generic_drv], capture_output=True, text=True, check=True).stdout.split()
    wanted = {i["name"] for i in nodes.values()}
    outs = {}
    for d in closure:
        if d.endswith(".drv"):
            info = read_drv(d)
            if info["name"] in wanted:
                for o in info["outputs"]:
                    outs[o] = info["name"]
    sizes = {}
    for path, info in path_info("https://cache.nixos.org", outs).items():
        name = outs.get(path)
        if name:
            sizes[name] = sizes.get(name, 0) + (info.get("downloadSize") or info.get("fileSize") or 0)
    return sizes


# --- execute -------------------------------------------------------------------

class Runner:
    def __init__(self, args):
        self.args = args
        self.plan = load_json(args.plan, None)
        self.nodes = self.plan["nodes"]
        me = next((m for m in self.plan["machines"] if m["index"] == args.machine), None)
        self.mine = me["nodes"] if me else []
        self.state = {d: "pending" for d in self.mine}
        self.result = {}
        self.remote_ok = set()
        self.deadline = args.deadline
        self.running = {}
        os.makedirs(args.logs, exist_ok=True)

    def outputs_valid(self, d):
        outs = self.nodes[d]["outputs"]
        proc = subprocess.run(["nix-store", "--check-validity", *outs], capture_output=True, check=False)
        return proc.returncode == 0

    def dep_status(self, dep):
        """ok, wait or dead for one input of one of my nodes."""
        if dep in self.state:
            s = self.state[dep]
            return "ok" if s == "built" else ("dead" if s in ("failed", "skipped") else "wait")
        if dep in self.remote_ok:
            return "ok"
        if not self.args.remote:
            # No cache to share through: build it as part of the dependent.
            return "ok"
        return "wait"

    def poll_remote(self):
        waiting = {
            dep
            for d, s in self.state.items() if s == "pending"
            for dep in self.nodes[d]["deps"]
            if dep not in self.state and dep not in self.remote_ok
        }
        if not waiting or not self.args.remote:
            return
        outs = {o: dep for dep in waiting for o in self.nodes[dep]["outputs"]}
        have = cached_many(self.plan["cache"], outs)
        for dep in waiting:
            if all(o in have for o in self.nodes[dep]["outputs"]):
                self.remote_ok.add(dep)

    def launch(self, d):
        name = self.nodes[d]["name"]
        remaining = int(self.deadline - time.time())
        logf = open(os.path.join(self.args.logs, f"{name}.log"), "w", encoding="utf-8")
        cmd = [
            "timeout", "--kill-after=60", str(max(remaining, 60)),
            "nix", "build", "--no-link", "-L", "--keep-going",
            "--max-jobs", "1", "--cores", str(self.args.cores), f"{d}^*",
        ]
        proc = subprocess.Popen(cmd, stdout=logf, stderr=subprocess.STDOUT)
        self.running[d] = (proc, time.time(), logf)
        self.state[d] = "running"
        log(f"[start] {name} (est {self.nodes[d]['est']}s, {remaining}s left)")

    def reap(self):
        for d, (proc, started, logf) in list(self.running.items()):
            if proc.poll() is None:
                continue
            logf.close()
            seconds = round(time.time() - started)
            ok = proc.returncode == 0 and self.outputs_valid(d)
            name = self.nodes[d]["name"]
            self.state[d] = "built" if ok else "failed"
            entry = {"name": name, "status": self.state[d], "seconds": seconds}
            if ok:
                sizes = path_info("auto", self.nodes[d]["outputs"])
                entry["nar"] = sum(i.get("narSize", 0) for i in sizes.values())
            if not ok:
                entry["timeout"] = proc.returncode in (124, 137)
                entry["log"] = tail(os.path.join(self.args.logs, f"{name}.log"), 60)
            self.result[d] = entry
            log(f"[{self.state[d]}] {name} in {seconds}s")
            del self.running[d]

    def step(self):
        """Launch what is ready; return False when nothing can happen any more."""
        progressed = False
        for d in self.mine:
            if self.state[d] != "pending":
                continue
            statuses = [self.dep_status(dep) for dep in self.nodes[d]["deps"]]
            if "dead" in statuses:
                self.state[d] = "skipped"
                self.result[d] = {"name": self.nodes[d]["name"], "status": "skipped", "reason": "input missing"}
                progressed = True
                continue
            left = self.deadline - time.time()
            if "wait" in statuses:
                # Keep waiting while the node could still finish after its
                # input arrives; a late runner is not a failed one.
                need = self.nodes[d]["est"] if self.nodes[d]["measured"] else 300
                if left < need + 300:
                    self.state[d] = "skipped"
                    self.result[d] = {"name": self.nodes[d]["name"], "status": "skipped", "reason": "input not ready in time"}
                    progressed = True
                continue
            if len(self.running) >= self.args.jobs:
                continue
            # A measured build that cannot finish would only burn the rest
            # of the job; a heuristic estimate is worth the try.
            if left < 300 or (self.nodes[d]["measured"] and self.nodes[d]["est"] > left):
                continue
            self.launch(d)
            progressed = True
        return progressed

    def run(self):
        last_poll = 0
        while True:
            self.reap()
            if time.time() - last_poll > 60:
                self.poll_remote()
                last_poll = time.time()
            self.step()
            pending = [d for d, s in self.state.items() if s == "pending"]
            if not self.running and (not pending or self.deadline - time.time() < 300):
                break
            time.sleep(10)
        for d, s in self.state.items():
            if s == "pending":
                self.result[d] = {"name": self.nodes[d]["name"], "status": "skipped", "reason": "out of time"}
        with open(self.args.results, "w", encoding="utf-8") as f:
            json.dump(self.result, f)
        counts = {}
        for r in self.result.values():
            counts[r["status"]] = counts.get(r["status"], 0) + 1
        lines = [f"## Runner {self.args.machine}", "", f"{counts}", ""]
        for r in self.result.values():
            if r["status"] == "failed":
                lines += [f"<details><summary>failed: {r['name']} after {r['seconds']}s"
                          f"{' (timeout)' if r.get('timeout') else ''}</summary>", "", "```",
                          r.get("log", ""), "```", "</details>"]
        summary(self.args.summary, "\n".join(lines))


def tail(path, n):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return "".join(f.readlines()[-n:])
    except OSError:
        return ""


def cmd_execute(args):
    Runner(args).run()


# --- finalize --------------------------------------------------------------------

def cmd_finalize(args):
    plan = load_json(args.plan, {"nodes": {}, "stats": {}})
    times = load_json(args.times, {})
    times.setdefault("name", {})
    times.setdefault("pname", {})
    times.setdefault("nar", {})
    built = failed = skipped = 0
    failures = []
    for path in args.results:
        for _d, r in load_json(path, {}).items():
            if r["status"] == "built":
                built += 1
                times["name"][r["name"]] = r["seconds"]
                times["pname"][pname(r["name"])] = r["seconds"]
                if r.get("nar"):
                    times["nar"][r["name"]] = r["nar"]
            elif r["status"] == "failed":
                failed += 1
                failures.append(r)
                if r.get("timeout"):
                    # A timeout is a lower bound; keep it so the planner
                    # reports the node as too big instead of retrying forever.
                    times["name"][r["name"]] = max(r["seconds"], times["name"].get(r["name"], 0)) * 2
            else:
                skipped += 1
    with open(args.times, "w", encoding="utf-8") as f:
        json.dump(times, f, indent=0, sort_keys=True)
    real = plan.get("stats", {}).get("real", 0)
    remaining = max(real - built, 0)
    status = {"built": built, "failed": failed, "skipped": skipped, "remaining": remaining,
              "capped": bool(plan.get("capped"))}
    lines = [
        "## World build",
        "",
        "| built | failed | skipped | remaining (before re-plan) |",
        "|---|---|---|---|",
        f"| {built} | {failed} | {skipped} | {remaining} |",
    ]
    if failures:
        lines += ["", "Failed:"] + [
            f"- `{r['name']}` after {r['seconds']}s{' (timeout)' if r.get('timeout') else ''}" for r in failures
        ]
    summary(args.summary, "\n".join(lines))
    print(json.dumps(status))


# --- stats (README feasibility numbers) ----------------------------------------------

def cmd_stats(args):
    """Size and time of the to-build set, from the generic twin closure."""
    to_build, _ = dry_run(args.drv)
    v3 = {d: read_drv(d) for d in to_build}
    generic_drvs = subprocess.run(
        ["nix-store", "-qR", args.generic], capture_output=True, text=True, check=True
    ).stdout.split()
    twin = {}
    for d in generic_drvs:
        if d.endswith(".drv"):
            info = read_drv(d)
            twin.setdefault(info["name"], info)
    outs = {}
    for info in v3.values():
        if info["trivial"]:
            continue
        g = twin.get(info["name"])
        if g:
            for o in g["outputs"]:
                outs[o] = info["name"]
    sizes = path_info("https://cache.nixos.org", outs)
    times = load_json(args.times, {})
    per_name = {}
    for path, info in sizes.items():
        n = outs.get(path)
        if n is None:
            continue
        e = per_name.setdefault(n, {"nar": 0, "file": 0})
        e["nar"] += info.get("narSize", 0)
        e["file"] += info.get("downloadSize", info.get("fileSize", 0)) or 0
    real = [i for i in v3.values() if not i["trivial"]]
    no_twin = [i["name"] for i in real if i["name"] not in twin]
    no_size = [i["name"] for i in real if i["name"] in twin and i["name"] not in per_name]
    est = {i["name"]: estimate(i["name"], times) for i in real}
    result = {
        "to_build": len(to_build),
        "real": len(real),
        "trivial": len(to_build) - len(real),
        "nar_bytes": sum(e["nar"] for e in per_name.values()),
        "compressed_bytes": sum(e["file"] for e in per_name.values()),
        "sized": len(per_name),
        "no_twin": len(no_twin),
        "no_size": len(no_size),
        "est_runner_hours": round(sum(est.values()) / 3600, 1),
        "largest_by_nar": sorted(((n, e["nar"]) for n, e in per_name.items()), key=lambda x: -x[1])[:25],
        "largest_by_time": sorted(est.items(), key=lambda x: -x[1])[:25],
        "too_big": sorted(n for n, s in est.items() if s > args.budget),
    }
    json.dump(result, sys.stdout, indent=1)


# --- status (docs/status.md) ---------------------------------------------------------

OUTPUT_RE = re.compile(r"-(bin|dev|lib|out|doc|man|info|debug|static|data|py|terminfo|udev|modules|qml|plugins|devdoc)$")
ARCH_ALIASES = {
    "python": "python3", "gcc-libs": "gcc", "linux-api-headers": "linux-headers",
    "qt6-base": "qtbase", "qt6-declarative": "qtdeclarative", "qt6-webengine": "qtwebengine",
    "nvidia-utils": "nvidia-x11", "java-openjdk": "openjdk", "java21-openjdk": "openjdk",
    "java17-openjdk": "openjdk", "firefox-pure": "firefox", "zlib-ng": "zlib-ng",
}
BINARY = {"nvidia-x11", "nvidia-settings", "helium", "tor-browser", "onlyoffice-desktopeditors", "vscode",
          "steam", "proton-cachyos", "linux-cachyos", "cuda-merged"}


def runtime_pnames(names):
    out = {}
    for n in names:
        p = OUTPUT_RE.sub("", pname(n.strip()))
        if p:
            out.setdefault(p, n.strip())
    return out


def arch_to_nix(name):
    if name in ARCH_ALIASES:
        return ARCH_ALIASES[name]
    if name.startswith("python-"):
        return "python3." + name[len("python-"):]
    if name.startswith("qt6-"):
        return "qt" + name[len("qt6-"):]
    return name


def cmd_status(args):
    parity = load_json(args.parity, {})
    closure = runtime_pnames(open(args.closure, encoding="utf-8"))
    # python3.14-foo -> python3.foo for matching Arch python-foo
    by_key = {}
    for p, full in closure.items():
        by_key[re.sub(r"^python3\.[0-9]+-", "python3.", p)] = (p, full)
    rows, core = [], []
    seen = set()
    for line in open(args.cachyos, encoding="utf-8"):
        repo, name, base, _ver, _packager = (line.rstrip("\n").split("\t") + [""] * 5)[:5]
        if name.startswith("lib32-") or not name:
            continue
        hit = by_key.get(arch_to_nix(name))
        if not hit or hit[0] in seen:
            continue
        seen.add(hit[0])
        (rows if repo == "cachyos-v3" else core).append((repo, name, base or name, hit[0]))

    def verdict(nix, base):
        for key in (nix, base, base.replace("python", "python3")):
            if key in parity.get("fallbacks", {}):
                return "no", "-", "generic: " + parity["fallbacks"][key]
        if nix in BINARY or base in BINARY:
            return "prebuilt binary", "-", "-"
        for key in (nix, base, "python3" if base == "python" else base):
            if key in parity.get("ported", {}):
                return "yes", "ported: " + parity["ported"][key]["what"], "-"
            if key in parity.get("equivalent", {}):
                return "yes", "equivalent: " + parity["equivalent"][key], "-"
            if key in parity.get("notPorted", {}):
                return "yes", "not ported: " + parity["notPorted"][key], "-"
        return "yes", "global flags only", "-"

    lines = [
        "# Package status",
        "",
        "Generated by `nix run .#v3ci -- status` from the CachyOS v3 repository databases",
        "(mirror.cachyos.org, x86_64_v3), the laptop's runtime closure and `lib/parity.nix`.",
        f"Laptop closure: {len(closure)} package names; CachyOS v3 packages in it: "
        f"{len(rows)} CachyOS-specific (cachyos-v3), {len(core)} Arch rebuilds (core-v3, extra-v3).",
        "",
        "Every package of the laptop closure is rebuilt for x86-64-v3 with -march=x86-64-v3 -mtune=generic",
        "(GOAMD64=v3, Rust target-cpu=x86-64-v3) unless it is a generic fallback or a prebuilt binary.",
        "",
        "## CachyOS-specific packages (cachyos-v3)",
        "",
        "| CachyOS package | nixpkgs | v3 rebuilt | CachyOS changes | generic fallback |",
        "|---|---|---|---|---|",
    ]
    for _repo, name, base, nix in sorted(rows, key=lambda r: r[2]):
        v3, ported, fb = verdict(nix, base)
        lines.append(f"| {name} | {nix} | {v3} | {ported} | {fb} |")
    lines += [
        "",
        "## Arch rebuilds (cachyos-core-v3, cachyos-extra-v3)",
        "",
        "CachyOS rebuilds these Arch PKGBUILDs with its v3 flags; here they get the global flags.",
        "",
        "| CachyOS package | nixpkgs | v3 rebuilt | generic fallback |",
        "|---|---|---|---|",
    ]
    for _repo, name, base, nix in sorted(core, key=lambda r: r[1]):
        v3, _ported, fb = verdict(nix, base)
        lines.append(f"| {name} | {nix} | {v3} | {fb} |")
    with open(args.out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    log(f"{len(rows)} cachyos-v3 and {len(core)} core/extra rows written to {args.out}")


def summary(path, text):
    print(text, file=sys.stderr)
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write(text + "\n")


def main():
    ap = argparse.ArgumentParser(prog="v3ci")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("plan")
    p.add_argument("--drv", required=True)
    p.add_argument("--cache", required=True)
    p.add_argument("--machines", type=int, default=16)
    p.add_argument("--budget", type=int, default=5 * 3600)
    p.add_argument("--delay", type=int, default=180, help="push + fetch lag between runners")
    p.add_argument("--times", default="build-times.json")
    p.add_argument("--generic", help="baseline twin toplevel .drv, for size estimates")
    p.add_argument("--quota-gb", type=float, default=5, help="cachix storage of the plan")
    p.add_argument("--local-only", help="regex of names rebuilt where needed, never pushed")
    p.add_argument("--out", default="plan.json")
    p.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY"))
    p.set_defaults(func=cmd_plan)

    e = sub.add_parser("execute")
    e.add_argument("--plan", default="plan.json")
    e.add_argument("--machine", type=int, required=True)
    e.add_argument("--deadline", type=float, required=True, help="epoch seconds")
    e.add_argument("--jobs", type=int, default=2)
    e.add_argument("--cores", type=int, default=4)
    e.add_argument("--remote", action=argparse.BooleanOptionalAction, default=True)
    e.add_argument("--logs", default="logs")
    e.add_argument("--results", default="results.json")
    e.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY"))
    e.set_defaults(func=cmd_execute)

    f = sub.add_parser("finalize")
    f.add_argument("--plan", default="plan.json")
    f.add_argument("--times", default="build-times.json")
    f.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY"))
    f.add_argument("results", nargs="*")
    f.set_defaults(func=cmd_finalize)

    s = sub.add_parser("stats")
    s.add_argument("--drv", required=True)
    s.add_argument("--generic", required=True)
    s.add_argument("--times", default="build-times.json")
    s.add_argument("--budget", type=int, default=5 * 3600)
    s.set_defaults(func=cmd_stats)

    t = sub.add_parser("status")
    t.add_argument("--cachyos", required=True, help="TSV: repo, name, base, version, packager")
    t.add_argument("--closure", required=True, help="store path names of the runtime closure, one per line")
    t.add_argument("--parity", required=True, help="nix eval --json .#lib.parity")
    t.add_argument("--out", default="docs/status.md")
    t.set_defaults(func=cmd_status)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
