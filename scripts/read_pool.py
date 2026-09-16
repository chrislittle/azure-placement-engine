"""Project a subscription's Compute usages into the `pool` shape ape-placement wants.

Reads Microsoft.Compute/locations/{region}/usages, which is the fan-out read a
rebalance needs per member subscription. `available` is deliberately left unset:
there is no quota group behind a plain subscription, and the module must treat
that as unproven rather than unlimited.
"""

import json
import shutil
import subprocess
import sys

REGIONAL_TOTALS = {"cores", "lowprioritycores", "virtualmachines", "virtualmachinescalesets"}


def read(subscription: str, region: str) -> dict:
    url = (
        f"https://management.azure.com/subscriptions/{subscription}"
        f"/providers/Microsoft.Compute/locations/{region}/usages?api-version=2021-07-01"
    )
    # On Windows `az` is az.cmd, which CreateProcess will not resolve from a
    # bare name.
    az = shutil.which("az")
    if az is None:
        sys.exit("az CLI not found on PATH")
    out = subprocess.run(
        [az, "rest", "--method", "get", "--url", url, "-o", "json"],
        capture_output=True, text=True, check=True,
    )
    return json.loads(out.stdout)


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


if __name__ == "__main__":
    sub, region = sys.argv[1], sys.argv[2]
    print(json.dumps({"pool": project(read(sub, region))}, indent=2))
