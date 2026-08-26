"""Validates the GitOps tree under clusters/ without needing kustomize or a cluster.

Checks:
  1. every YAML file parses,
  2. every path listed in a kustomization.yaml exists,
  3. every non-kustomization document has apiVersion/kind/metadata.name,
  4. the two directories the Flux config reconciles are present.
"""
import sys
import pathlib
import yaml

root = pathlib.Path(sys.argv[1]).resolve()
errors = []
docs = 0
files = 0

for path in sorted(root.rglob("*.yaml")):
    files += 1
    rel = path.relative_to(root)
    try:
        loaded = [d for d in yaml.safe_load_all(path.read_text(encoding="utf-8")) if d]
    except yaml.YAMLError as exc:
        errors.append(f"{rel}: YAML parse error: {exc}")
        continue

    for doc in loaded:
        docs += 1
        if not isinstance(doc, dict):
            errors.append(f"{rel}: document is not a mapping")
            continue
        if doc.get("kind") == "Kustomization" and "kustomize.config" in str(doc.get("apiVersion", "")):
            for entry in doc.get("resources", []):
                target = (path.parent / entry).resolve()
                if not target.exists():
                    errors.append(f"{rel}: resources entry '{entry}' does not exist")
                elif target.is_dir() and not (target / "kustomization.yaml").exists():
                    errors.append(f"{rel}: directory '{entry}' has no kustomization.yaml")
            continue
        for field in ("apiVersion", "kind"):
            if not doc.get(field):
                errors.append(f"{rel}: document missing {field}")
        if not (doc.get("metadata") or {}).get("name"):
            errors.append(f"{rel}: document missing metadata.name")

for cluster_dir in root.iterdir():
    if not cluster_dir.is_dir():
        continue
    for required in ("infrastructure", "apps"):
        sub = cluster_dir / required
        if not (sub / "kustomization.yaml").exists():
            errors.append(
                f"{cluster_dir.name}: missing {required}/kustomization.yaml, "
                "which infra/modules/flux/flux.bicep reconciles"
            )

print(f"scanned {files} files, {docs} documents")
if errors:
    print("FAILED")
    for e in errors:
        print("  -", e)
    sys.exit(1)
print("OK: gitops tree is structurally valid")
