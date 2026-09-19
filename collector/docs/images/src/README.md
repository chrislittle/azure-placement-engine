# Diagram sources

The PNGs beside this folder are rendered from the HTML here, the same way
`ghcp-credit-visibility-azure` does it: hand-written HTML, headless Chrome,
Fluent palette, Segoe UI.

```powershell
./render.ps1 -IconRoot 'C:\path\to\Azure_Public_Service_Icons\Icons'
```

It substitutes the icons, renders each `.html` to a PNG at 2x, and crops the
trailing white space to the content.

## The icons are not in this repository

The diagrams use Microsoft's Azure architecture icons. They are Microsoft's, and
they are **not** covered by this repository's MIT licence, so the SVG files are
not committed here.

Microsoft's terms: *"Microsoft permits the use of these icons in architectural
diagrams, training materials, or documentation."* That is what these are.

Download them from
[learn.microsoft.com/azure/architecture/icons](https://learn.microsoft.com/en-us/azure/architecture/icons/)
and point `-IconRoot` at the `Icons` folder inside the archive.

The HTML carries `{{icon:name}}` placeholders. `render.ps1` maps each one to a
file and inlines it as a data URI, so the rendered PNG is self-contained and the
HTML can be committed without the SVGs.

| Placeholder | Icon |
|---|---|
| `{{icon:quotas}}` | `other/02951-icon-service-Azure-Quotas.svg` |
| `{{icon:mgroups}}` | `general/10011-icon-service-Management-Groups.svg` |
| `{{icon:subs}}` | `general/10002-icon-service-Subscriptions.svg` |
| `{{icon:vm}}` | `compute/10021-icon-service-Virtual-Machine.svg` |
| `{{icon:roles}}` | `identity/10340-icon-service-Entra-Identity-Roles-and-Administrators.svg` |
| `{{icon:location}}` | `general/10818-icon-service-Location.svg` |
| `{{icon:workflow}}` | `general/10852-icon-service-Workflow.svg` |

`render.ps1` fails rather than rendering a diagram with a missing icon, and
fails again if a placeholder is left unresolved.

## Conventions

| | |
|---|---|
| Width | 1180px, 32px padding, rendered at `--force-device-scale-factor=2` |
| Navy | `#243A5E` headings |
| Text | `#201F1E` body, `#605E5C` secondary |
| Borders | `#EDEBE9` |
| Accents | `#0078D4` blue, `#107C10` green, `#6E5494` purple, `#CA5010` orange |
| Dashed | Something that does not exist yet |
| Orange | Work still to do. Green is built and working |
