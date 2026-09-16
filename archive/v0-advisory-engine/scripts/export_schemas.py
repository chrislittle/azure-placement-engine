"""Regenerate JSON Schema files from the pydantic contracts.

The pydantic models are the source of truth; `schemas/*.json` is the published
artifact so agents and non-Python callers can validate without importing us.
Run after any contract change:  python scripts/export_schemas.py
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from placement.contracts.decision import DecisionRecord  # noqa: E402
from placement.contracts.requirements import Requirements  # noqa: E402

TARGETS = {
    "requirements.schema.json": (Requirements, "Azure Placement Engine — workload requirements"),
    "decision-record.schema.json": (DecisionRecord, "Azure Placement Engine — decision record"),
}


def main() -> int:
    out_dir = ROOT / "schemas"
    out_dir.mkdir(exist_ok=True)
    for filename, (model, title) in TARGETS.items():
        schema = model.model_json_schema(by_alias=True)
        schema = {"$schema": "https://json-schema.org/draft/2020-12/schema", "title": title, **schema}
        (out_dir / filename).write_text(json.dumps(schema, indent=2) + "\n", encoding="utf-8")
        print(f"wrote schemas/{filename}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
