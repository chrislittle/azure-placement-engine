"""Project live Azure state into the `quota` and `sku_access` inputs ape-placement wants.

Two separate reads, because they are two separate gates:

  quota        Microsoft.Compute/locations/{region}/usages -- what quota exists.
              This is also the fan-out read a reallocation needs per member
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

# Categories are Azure Compute Fleet's `vmCategories` names. See
# knowledge/vm-series-classes.yaml for why each rule exists and why the order
# matters.
FPGA_FAMILIES = r"^standardNP"
STORAGE_FAMILIES = r"^standardL"
BURSTABLE_FAMILIES = r"^standardB"

REGIONAL_TOTALS = {"cores", "lowprioritycores", "virtualmachines", "virtualmachinescalesets"}


class RegionNotAccessible(Exception):
    """The subscription has no access to the region.

    Compute usages answers NoRegisteredProviderFound for a region the
    subscription has not been granted, at every API version. It is an access
    answer wearing a provider-registration error's clothes.
    """


def _az(url: str) -> str:
    # On Windows `az` is az.cmd, which CreateProcess will not resolve from a
    # bare name.
    az = shutil.which("az")
    if az is None:
        sys.exit("az CLI not found on PATH")
    out = subprocess.run(
        [az, "rest", "--method", "get", "--url", url, "-o", "json"],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        if "NoRegisteredProviderFound" in out.stderr:
            raise RegionNotAccessible(url)
        raise RuntimeError(out.stderr.strip()[:400])
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
            # the others outrank them on unused if let through.
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


def classify(family, ratios, has_gpu, has_rdma=False):
    """Azure vmCategory for a family. Order matters; see the knowledge file."""
    # NP reports a GPUs capability although its accelerators are FPGAs, so this
    # must be tested before the GPU check or every NP lands in GpuAccelerated.
    if re.match(FPGA_FAMILIES, family, re.IGNORECASE):
        return "FpgaAccelerated"
    if has_gpu:
        return "GpuAccelerated"
    if has_rdma:
        return "HighPerformanceCompute"
    if re.match(STORAGE_FAMILIES, family, re.IGNORECASE):
        return "StorageOptimized"
    if not ratios:
        return None
    ratios = sorted(ratios)
    median = ratios[len(ratios) // 2]
    if median < 3:
        return "ComputeOptimized"
    if median <= 6:
        return "GeneralPurpose"
    return "MemoryOptimized"


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
        rdma = str(caps.get("RdmaEnabled", "")).lower() == "true"
        confidential = bool(caps.get("ConfidentialComputingType"))
        architecture = caps.get("CpuArchitectureType")

        entry = {"zones": zones, "restricted_zones": sorted(restricted)}
        if location_restricted:
            entry["location_restricted"] = True
        if reason:
            entry["restriction_reason"] = reason
        fam = families.setdefault(family, {
            "sizes": {}, "_ratios": [], "_gpu": False, "_rdma": False,
            "_cc": False, "_arch": set(),
        })
        fam["sizes"][sku["name"]] = entry
        if vcpus > 0:
            fam["_ratios"].append(memory / vcpus)
        fam["_gpu"] = fam["_gpu"] or gpus > 0
        fam["_rdma"] = fam["_rdma"] or rdma
        fam["_cc"] = fam["_cc"] or confidential
        if architecture:
            fam["_arch"].add(architecture)

    attributes = {}
    for name, fam in families.items():
        attributes[name] = {
            "category": classify(
                name, fam.pop("_ratios"), fam.pop("_gpu"), fam.pop("_rdma")
            ),
            # Flags rather than categories, matching how Azure models them.
            "burstable": bool(re.match(BURSTABLE_FAMILIES, name, re.IGNORECASE)),
            "confidential_computing": fam.pop("_cc"),
            "architectures": sorted(fam.pop("_arch")),
        }
    return families, attributes


if __name__ == "__main__":
    sub, region = sys.argv[1], sys.argv[2]
    try:
        quota = project(read(sub, region))
        accessible = True
    except RegionNotAccessible:
        # Emit a well-formed answer rather than crashing: "no access" is a real
        # result, and the module has to be able to say so.
        quota = {"regional_cores_limit": 0, "regional_cores_used": 0, "families": {}}
        accessible = False
    quota["region_accessible"] = accessible

    # Annotate rather than filter: a growth-restricted family is still usable by
    # an EXISTING subscription within quota it already holds. Only the module
    # knows whether the target subscription is new.
    restricted = growth_restricted()
    for name, entry in quota["families"].items():
        if name in restricted:
            entry["lifecycle"] = "growth_restricted"

    # Deliberately still read the SKUs. They are useless for detecting the
    # access gap -- 796 of 866 VM SKUs in Germany North report no restriction at
    # all for a subscription that cannot deploy there -- but the projection is
    # what proves that, and callers may want it anyway.
    sku_access, attributes = ({}, {}) if not accessible else project_skus(read_skus(sub, region))

    # Category and attributes belong on the quota entry the module ranks,
    # not on the access data.
    for name, entry in quota["families"].items():
        attrs = attributes.get(name)
        if attrs and attrs["category"]:
            entry.update(attrs)

    print(json.dumps({"quota": quota, "sku_access": sku_access}, indent=2))
