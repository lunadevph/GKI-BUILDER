"""Verify every reusable-workflow call passes only inputs the callee declares."""
import glob, re, sys
import yaml

root = ".github/workflows"
files = sorted(glob.glob(root + "/*.yml") + glob.glob(root + "/*.yaml"))

docs = {}
for f in files:
    with open(f, encoding="utf-8") as fh:
        try:
            docs[f] = yaml.safe_load(fh)
        except Exception as e:
            print("PARSE ERROR %s: %s" % (f, e))
            sys.exit(1)


def declared_inputs(doc):
    """Inputs declared on workflow_call (or workflow_dispatch)."""
    on = doc.get("on") or doc.get(True) or {}
    names = set()
    if isinstance(on, dict):
        for trig in ("workflow_call", "workflow_dispatch"):
            t = on.get(trig)
            if isinstance(t, dict) and isinstance(t.get("inputs"), dict):
                names |= set(t["inputs"].keys())
    return names


def walk_jobs(doc):
    jobs = doc.get("jobs") or {}
    if not isinstance(jobs, dict):
        return
    for jname, j in jobs.items():
        if not isinstance(j, dict):
            continue
        yield jname, j


errors = 0
for f, doc in docs.items():
    for jname, j in walk_jobs(doc):
        uses = j.get("uses")
        if not isinstance(uses, str) or not uses.startswith("./"):
            continue
        callee = uses[2:]
        if not callee.endswith((".yml", ".yaml")):
            callee += ".yml"
        callee = root + "/" + callee.split("/")[-1] if "/" not in callee else callee
        # normalise to a repo-relative path
        cand = uses[2:]
        target = None
        for g in files:
            if g.replace("\\", "/").endswith(cand.lstrip("./")):
                target = g
                break
        if target is None:
            print("UNRESOLVED  %s:%s -> %s" % (f, jname, uses))
            errors += 1
            continue
        cdoc = docs[target]
        allowed = declared_inputs(cdoc)
        passed = set((j.get("with") or {}).keys())
        extra = passed - allowed
        # secrets is passed via `secrets: inherit`, not `with`
        if extra:
            errors += 1
            print("MISMATCH    %s:%s -> %s" % (f, jname, target))
            for e in sorted(extra):
                print("             undeclared input: %s" % e)
        else:
            print("ok          %s:%s -> %s (%d inputs)" % (f, jname, target.split("/")[-1], len(passed)))

print()
print("errors:", errors)
sys.exit(1 if errors else 0)