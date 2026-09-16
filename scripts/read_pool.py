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
import shutil
import subprocess
import sys

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

        entry = {"zones": zones, "restricted_zones": sorted(restricted)}
        if location_restricted:
            entry["location_restricted"] = True
        if reason:
            entry["restriction_reason"] = reason
        families.setdefault(family, {"sizes": {}})["sizes"][sku["name"]] = entry
    return families


if __name__ == "__main__":
    sub, region = sys.argv[1], sys.argv[2]
    print(json.dumps({
        "pool": project(read(sub, region)),
        "sku_access": project_skus(read_skus(sub, region)),
    }, indent=2))
