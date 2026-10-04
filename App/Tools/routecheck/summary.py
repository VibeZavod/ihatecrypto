#!/usr/bin/env python3
import json, sys, collections, statistics
rows = {}
for path in sys.argv[1:]:
    for l in open(path):
        if l.strip():
            r = json.loads(l); rows[(path, r["id"])] = r
rows = list(rows.values())
by = collections.defaultdict(lambda: [0, 0])
lang = collections.defaultdict(lambda: [0, 0])
for r in rows:
    by[r["kind"]][0] += r["ok"]; by[r["kind"]][1] += 1
    lang[r["lang"]][0] += r["ok"]; lang[r["lang"]][1] += 1
ok = sum(r["ok"] for r in rows)
secs = [r["out"]["seconds"] for r in rows if "seconds" in r.get("out", {})]
print(f"{ok}/{len(rows)} ok ({100*ok/max(len(rows),1):.1f}%), median {statistics.median(secs) if secs else 0:.1f} s")
print("by language:", {k: f"{v[0]}/{v[1]}" for k, v in sorted(lang.items())})
print("weakest kinds:", ", ".join(f"{k} {v[0]}/{v[1]}" for k, v in sorted(by.items(), key=lambda x: x[1][0] / x[1][1]) if v[0] < v[1]))
errs = collections.Counter(r["why"][0].split(":")[0] for r in rows if not r["ok"])
print("failure types:", dict(errs))
