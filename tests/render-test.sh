#!/usr/bin/env bash
# Render checks for this chart. Needs helm and python3 with PyYAML.
#
#   tests/render-test.sh                         lint, Camoufox env, annotations, CRD schema
#   OPERATOR_CRD=<operator>/deploy/crd.yaml tests/render-test.sh
#                                                also: the chart's CRDs equal the operator's
#
# The CRDs here are copied from livellm-browser-operator's deploy/crd.yaml;
# nothing syncs them, so run with OPERATOR_CRD before pushing a CRD change.
# Exits non-zero on any failure.
set -euo pipefail

CHART="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAIL=0
ok()   { printf 'ok    %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; FAIL=1; }
skip() { printf 'SKIP  %s\n' "$*"; }

# 1. helm lint
if helm lint "$CHART" >"$WORK/lint.txt" 2>&1; then ok "helm lint"; else cat "$WORK/lint.txt"; bad "helm lint"; fi

# 2. Annotation shape. The helper uses each annotation verbatim as the image
#    tag, so a bare "1.0.0" would render kamasalyamov/livellm-browser:1.0.0
#    (the Chrome image) as the Camoufox default; an empty one renders nothing.
python3 - "$CHART/Chart.yaml" >"$WORK/ann.txt" <<'PY' || FAIL=1
import re, sys, yaml
ann = (yaml.safe_load(open(sys.argv[1])) or {}).get("annotations") or {}
rules = {
    "camoufoxVersion":    r"^(dev-)?camoufox-[0-9]+\.[0-9]+\.[0-9]+$",
    "camoufoxApiVersion": r"^(dev-)?camoufox-api-[0-9]+\.[0-9]+\.[0-9]+$",
}
rc = 0
for key, rx in rules.items():
    if key not in ann:
        print(f"ok    annotation {key} absent (no Camoufox default rendered)")
    elif isinstance(ann[key], str) and re.match(rx, ann[key]):
        print(f"ok    annotation {key}={ann[key]}")
    else:
        print(f"FAIL  annotation {key}={ann[key]!r} does not match {rx}")
        rc = 1
sys.exit(rc)
PY
cat "$WORK/ann.txt"

# 3. Camoufox env is additive. Render the Deployment from copies of the chart
#    with no / one / both camoufox annotations; the render without them must
#    carry no Camoufox env, and each annotation adds exactly its two env pairs
#    and nothing else.
variant() { # name, camoufoxVersion or -, camoufoxApiVersion or -
  local dir="$WORK/$1"
  mkdir -p "$dir"
  cp -r "$CHART/Chart.yaml" "$CHART/values.yaml" "$CHART/templates" "$dir/"
  python3 - "$dir/Chart.yaml" "$2" "$3" <<'PY'
import sys, yaml
path, cv, av = sys.argv[1:4]
c = yaml.safe_load(open(path))
ann = c.setdefault("annotations", {}) or {}
c["annotations"] = ann
for k, v in (("camoufoxVersion", cv), ("camoufoxApiVersion", av)):
    ann.pop(k, None)
    if v != "-":
        ann[k] = v
yaml.safe_dump(c, open(path, "w"), sort_keys=False)
PY
  helm template t "$dir" --namespace livellm-operator --show-only templates/deployment.yaml >"$WORK/$1.yaml"
}
variant none - -
variant both dev-camoufox-9.8.7 dev-camoufox-api-9.8.7
variant browser dev-camoufox-9.8.7 -
variant api - dev-camoufox-api-9.8.7

if grep -qi camoufox "$WORK/none.yaml"; then bad "Deployment without annotations mentions camoufox"; else ok "Deployment without annotations has no Camoufox env"; fi

PP="$(python3 -c "import yaml;print(yaml.safe_load(open('$CHART/values.yaml'))['camoufox']['image']['pullPolicy'])")"
REPO="$(python3 -c "import yaml;print(yaml.safe_load(open('$CHART/values.yaml'))['camoufox']['image']['repository'])")"
pairs() { # NAME value
  printf '            - name: %s\n              value: "%s"\n' "$1" "$2"
}
expect_added() { # variant, expected-added-lines-file
  local got="$WORK/$1.added"
  # Lines only in the variant; nothing may be removed or changed.
  if diff "$WORK/none.yaml" "$WORK/$1.yaml" | grep -q '^<'; then bad "$1: lines removed or changed vs no annotations"; return; fi
  diff "$WORK/none.yaml" "$WORK/$1.yaml" | sed -n 's/^> //p' >"$got" || true
  if diff -u "$2" "$got" >"$WORK/$1.diff"; then ok "$1: adds exactly $(($(wc -l <"$2") / 2)) env pairs"; else cat "$WORK/$1.diff"; bad "$1: unexpected added lines"; fi
}
{ pairs DEFAULT_CAMOUFOX_IMAGE "$REPO:dev-camoufox-9.8.7"; pairs DEFAULT_CAMOUFOX_PULL_POLICY "$PP"; } >"$WORK/exp-browser"
{ pairs DEFAULT_CAMOUFOX_API_IMAGE "$REPO:dev-camoufox-api-9.8.7"; pairs DEFAULT_CAMOUFOX_API_PULL_POLICY "$PP"; } >"$WORK/exp-api"
cat "$WORK/exp-browser" "$WORK/exp-api" >"$WORK/exp-both"
expect_added browser "$WORK/exp-browser"
expect_added api "$WORK/exp-api"
expect_added both "$WORK/exp-both"

# 4. CRD schema: spec.engine on both CRDs, enum exactly [chrome, camoufox],
#    optional, no default (absent means chrome; the platform stores it only
#    for camoufox).
helm template t "$CHART" --namespace livellm-operator --set installCRDs=true \
  --show-only templates/crd-browsers.yaml --show-only templates/crd-controllers.yaml >"$WORK/crds.yaml"
python3 - "$WORK/crds.yaml" <<'PY' || FAIL=1
import sys, yaml
docs = {d["metadata"]["name"]: d for d in yaml.safe_load_all(open(sys.argv[1])) if d}
rc = 0
for name in ("browsers.livellm.io", "controllers.livellm.io"):
    if name not in docs:
        print(f"FAIL  CRD {name} not rendered"); rc = 1; continue
    for v in docs[name]["spec"]["versions"]:
        spec = v["schema"]["openAPIV3Schema"]["properties"]["spec"]
        eng = spec.get("properties", {}).get("engine")
        where = f"{name} {v['name']} spec.engine"
        if eng is None:
            print(f"FAIL  {where} missing"); rc = 1; continue
        errs = []
        if eng.get("type") != "string": errs.append(f"type {eng.get('type')!r}")
        if eng.get("enum") != ["chrome", "camoufox"]: errs.append(f"enum {eng.get('enum')!r}")
        if "default" in eng: errs.append(f"default {eng['default']!r}")
        if "engine" in (spec.get("required") or []): errs.append("required")
        if errs:
            print(f"FAIL  {where}: " + ", ".join(errs)); rc = 1
        else:
            print(f"ok    {where}: optional enum [chrome, camoufox], no default")
sys.exit(rc)
PY

# 5. CRD parity with the operator (opt-in: the operator lives in another repo).
if [ -n "${OPERATOR_CRD:-}" ]; then
  python3 - "$WORK/crds.yaml" "$OPERATOR_CRD" <<'PY' || FAIL=1
import json, sys, yaml
def load(p):
    return {d["metadata"]["name"]: d for d in yaml.safe_load_all(open(p)) if d}
chart, op = load(sys.argv[1]), load(sys.argv[2])
rc = 0
if set(chart) != set(op):
    print(f"FAIL  CRD names differ: chart {sorted(chart)} operator {sorted(op)}"); rc = 1
for name in sorted(set(chart) & set(op)):
    if chart[name] == op[name]:
        print(f"ok    CRD {name} equals the operator's")
    else:
        a = json.dumps(chart[name], indent=1, sort_keys=True).splitlines()
        b = json.dumps(op[name], indent=1, sort_keys=True).splitlines()
        import difflib
        print("\n".join(list(difflib.unified_diff(b, a, "operator", "chart", lineterm=""))[:60]))
        print(f"FAIL  CRD {name} differs from {sys.argv[2]}"); rc = 1
sys.exit(rc)
PY
else
  skip "CRD parity with the operator: set OPERATOR_CRD=<livellm-browser-operator>/deploy/crd.yaml"
fi

if [ "$FAIL" -ne 0 ]; then echo "render-test: FAILED"; exit 1; fi
echo "render-test: passed"
