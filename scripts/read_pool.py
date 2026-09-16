"""Project live Azure state into the `pool` and `sku_access` inputs ape-placement wants.

Two separate reads, because they are two separate gates:

  pool        Microsoft.Compute/locations/{region}/usages -- what quota exists.
              This is also the fan-out read a rebalance needs per member
              subscription. `available` is deliberately left unset: there is no
              quota group behind a plain subscription, and the module must treat
              that as unproven rather than unlimited.

  sku_access  Microsoft.Compute/skus -- what this subscription may deploy.
              Emitted raw, published zones and restricted zones side by side,
              because the subtraction between them is decision logic and belongs
              in the module where it is tested.
"""

import json
import pathlib
import re
import shutil
import subprocess
import sys

KNOWLEDGE_DIR = pathlib.Path(__file__).resolve().parent.parent / "knowledge"
KNOWLEDGE = KNOWLEDGE_DIR / "vm-series-lifecycle.yaml"

# Name prefixes for the classes capability data cannot express.
# Mirrors knowledge/vm-series-classes.yaml; see that file for why each exists.
CLASS_OVERRIDES = [
    ("burstable", r"^standardB"),
    ("storage_optimized", r"^standardL"),
    ("hpc", r"^standardH"),
    ("confidential", r"^standard(DC|EC)"),
]

REGIONAL_TOTALS = {"cores", "lowprioritycores", "virtualmachines", "virtualmachinescalesets"}


def _az(url: str) -> str:
    # On Windows `az` is az.cmd, which CreateProcess will not resolve from a
    # bare name.
    az = shutil.which("az")
    if az is None:
        sys.exit("az CLI not found on PATH")
    out = subprocess.run(
        [az, "rest", "--method", "get", "--url", url, "-o", "json"],
        capture_output=True, text=True, check=True,
    )
    return out.stdout


def read(subscription: str, region: str) -> dict:
    url = (
        f"https://management.azure.com/subscriptions/{subscription}"
        f"/providers/Microsoft.Compute/locations/{region}/usages?api-version=2021-07-01"
    )
    return json.loads(_az(url))


def project(payload: dict) -> dict:
    families, regional = {}, {"limit": 0, "used": 0}
    for item in payload.get("value", []):
        name = (item.get("name") or {}).get("value")
        limit = item.get("limit")
        if not name or not isinstance(limit, (int, float)):
            continue
        used = int(item.get("currentValue") or 0)
        if name.lower() == "cores":
            regional = {"limit": int(limit), "used": used}
        elif name.lower().endswith("family") and limit > 0:
            # The usages response mixes vCPU families in with counters that are
            # not families at all -- UltraSSDDiskSizeInGB, availabilitySets,
            # disk counts. Only the vCPU families are placement candidates, and
            # the others outrank them on headroom if let through.
            #
            # Families reporting a limit of zero are omitted: absent is not the
            # same as unavailable, and a zero-limit family is not a candidate.
            families[name] = {"limit": int(limit), "used": used}
    return {
        "regional_cores_limit": regional["limit"],
        "regional_cores_used": regional["used"],
        "families": families,
    }


def growth_restricted():
    """Families frozen by the July 2026 capacity growth restrictions.

    Read from knowledge/ rather than duplicated here, so the list has one
    home. Scanned rather than YAML-parsed to keep this script
    dependency-free; the block is a flat list of family names and nothing
    else in it looks like one.
    """
    text = KNOWLEDGE.read_text(encoding="utf-8")
    block = text.split("growth_restricted_families:", 1)[1]
    block = block.split("unmatched_note:", 1)[0]
    return set(re.findall(r"\bstandard\w*Family\b", block))


def classify(family: str, ratios: list, has_gpu: bool):
    """Workload class for a family: overrides, then GPU, then memory ratio."""
    for name, pattern in CLASS_OVERRIDES:
        if re.match(pattern, family, re.IGNORECASE):
            return name
    if has_gpu:
        return "gpu"
    if not ratios:
        return None
    ratios = sorted(ratios)
    median = ratios[len(ratios) // 2]
    if median < 3:
        return "compute_optimized"
    if median <= 6:
        return "general_purpose"
    return "memory_optimized"


def read_skus(subscription: str, region: str) -> dict:
    url = (
        f"https://management.azure.com/subscriptions/{subscription}"
        f"/providers/Microsoft.Compute/skus?api-version=2021-07-01"
        f"&$filter=location eq '{region}'"
    )
    return json.loads(_az(url))


def project_skus(payload: dict) -> dict:
    """Group VM SKUs by family, keeping published and restricted zones apart."""
    families: dict = {}
    for sku in payload.get("value", []):
        if sku.get("resourceType") != "virtualMachines":
            continue
        family = sku.get("family")
        if not family:
            continue

        zones = sorted({z for li in sku.get("locationInfo") or [] for z in li.get("zones") or []})
        restricted, location_restricted, reason = set(), False, None
        for r in sku.get("restrictions") or []:
            reason = reason or r.get("reasonCode")
            info = r.get("restrictionInfo") or {}
            if r.get("type") == "Zone":
                restricted |= set(info.get("zones") or [])
            else:
                location_restricted = True

        caps = {c["name"]: c["value"] for c in sku.get("capabilities") or []}
        try:
            vcpus, memory = float(caps.get("vCPUs", 0)), float(caps.get("MemoryGB", 0))
        except (TypeError, ValueError):
            vcpus, memory = 0.0, 0.0
        try:
            gpus = float(caps.get("GPUs") or 0)
        except (TypeError, ValueError):
            gpus = 0.0

        entry = {"zones": zones, "restricted_zones": sorted(restricted)}
        if location_restricted:
            entry["location_restricted"] = True
        if reason:
            entry["restriction_reason"] = reason
        fam = families.setdefault(family, {"sizes": {}, "_ratios": [], "_gpu": False})
        fam["sizes"][sku["name"]] = entry
        if vcpus > 0:
            fam["_ratios"].append(memory / vcpus)
        fam["_gpu"] = fam["_gpu"] or gpus > 0

    classes = {}
    for name, fam in families.items():
        classes[name] = classify(name, fam.pop("_ratios"), fam.pop("_gpu"))
    return families, classes


if __name__ == "__main__":
    sub, region = sys.argv[1], sys.argv[2]
    pool = project(read(sub, region))

    # Annotate rather than filter: a growth-restricted family is still usable by
    # an EXISTING subscription within quota it already holds. Only the module
    # knows whether the target subscription is new.
    restricted = growth_restricted()
    for name, entry in pool["families"].items():
        if name in restricted:
            entry["lifecycle"] = "growth_restricted"

    sku_access, classes = project_skus(read_skus(sub, region))

    # Workload class is a property of the family, so it belongs on the pool
    # entry the module ranks -- not on the access data.
    for name, entry in pool["families"].items():
        if classes.get(name):
            entry["class"] = classes[name]

    print(json.dumps({"pool": pool, "sku_access": sku_access}, indent=2))
