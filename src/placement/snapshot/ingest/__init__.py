"""Ingesters: turn a raw Azure source into a slice of the world snapshot.

Every ingester follows the same shape — a pure `parse_*` that takes a payload,
and a thin `fetch_*` that goes to the network. Keeping them apart is what makes
an offline dump a first-class input rather than a workaround.
"""

from __future__ import annotations

import json
from pathlib import Path

#: Tried in order. JSON is specified as UTF-8, but `az rest > file.json` on a
#: Windows console writes cp1252, so a region named "Gävle" is enough to make a
#: strict UTF-8 read fail. UTF-8 is attempted first, so a genuinely UTF-8 file is
#: never mis-decoded; the rest are there so the documented workflow just works.
ENCODINGS = ("utf-8-sig", "utf-8", "cp1252", "latin-1")


class PayloadError(ValueError):
    pass


def read_payload(path: str | Path) -> tuple[dict, str]:
    """Read a JSON payload, tolerating the encodings Azure tooling actually emits.

    Returns the parsed document and the encoding that worked, so a caller can
    surface a fallback rather than hiding it.
    """
    raw = Path(path).read_bytes()

    decode_errors: list[str] = []
    for encoding in ENCODINGS:
        try:
            text = raw.decode(encoding)
        except UnicodeDecodeError as exc:
            decode_errors.append(f"{encoding}: {exc.reason}")
            continue

        try:
            document = json.loads(text)
        except json.JSONDecodeError as exc:
            # Decoded cleanly but isn't JSON — trying another codec won't help.
            raise PayloadError(f"{path}: not valid JSON ({exc})") from exc

        if not isinstance(document, dict):
            raise PayloadError(
                f"{path}: expected a JSON object at the root, got {type(document).__name__}"
            )
        return document, encoding

    raise PayloadError(f"{path}: could not decode as any of {', '.join(ENCODINGS)} — " + "; ".join(decode_errors))
