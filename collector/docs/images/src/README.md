# Collector diagram sources

These two diagrams are rendered by the repository's shared renderer, which also
holds the shared stylesheet and the icon mapping:

```powershell
cd ../../../../docs/images/src
./render.ps1 -IconRoot 'C:\path\to\Azure_Public_Service_Icons\Icons'
```

It renders this folder and `docs/images/src` together, so both sets stay in one
house style.

| Diagram | What it shows |
|---|---|
| `collector-flow.png` | The ten steps, which of them write, and the approval block |
| `quota-group-architecture.png` | Where a quota group sits in AQV, and what is still unknown |

See [`docs/images/src/README.md`](../../../../docs/images/src/README.md) for the
conventions, the icon list, and why the Azure SVG files are not committed.
