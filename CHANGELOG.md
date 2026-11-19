# Changelog

Notable changes to the Hardware Monitor plugin, newest first. The version lives
in `manifest.json`; `scripts/release.sh X.Y.Z` turns the Unreleased notes below
into a dated version entry, bumps the manifest to match, and commits and tags
the release.

Releases up to 1.2.1 were not tagged. Their release commits are 1.0.0
`f9aa323`, 1.1.0 `8e1fd16`, 1.1.1 `7c577c0`, 1.2.0 `ff91bb8` and 1.2.1
`c217fdb`.

## Unreleased

### Added

- `scripts/check.sh`, a pre-push check (manifest validation, manifest defaults
  against the schema, syntax of every helper and QML file), and
  `scripts/release.sh` with this changelog.
- README: a Development section on trying a checkout in your own bar.
- The top-processes header says "by name" when grouping found no systemd app
  identity and fell back to process names.
- `proc_top.py --help`. Unknown or malformed arguments are now rejected with a
  usage message instead of silently ignored.
- `gpuTempIconRotation`, so the GPU temperature glyph turns on its own;
  `gpuIconRotation` now rotates only the GPU glyph.

### Changed

- README and manifest descriptions now match the code: the panel header and
  its settings drawer (gear or `s`), the mode-dependent `showGauges` default,
  how `gpu: "auto"` picks a card and what an unmatched value does, `monitors`
  and `itemsOrder` as comma-separated strings, top processes by RAM or CPU,
  and rows for `padOpacity` and the four glyph rotation settings.
- The top-processes helper does about half the CPU work per refresh: one
  `/proc` read per process in the first sample, and linear-time grouping.
- `proc_top.py` exits 1 on a failure and 2 on a bad argument instead of 0; it
  still prints `{}`, so the panel behaves as before.
- Bar temperatures stay dim up to `warnTempC` and warm toward the urgent colour
  from there to `criticalTempC`, as the settings describe. With the defaults, a
  50-75 °C reading now draws dim instead of slightly warmed.
- Middle click resamples the widget on every screen, like the IPC `refresh`.
- The hover tooltip names all three clicks.
- `percentPad: "trail"` (and its old name `"space"`) is retired and reads as
  `"none"`, which it already drew. README and manifest give the real
  mode-dependent default (`"zero"` in `compact`/`full`/`labels`).
- `ramFormat: "available"` is an alias of `"free"`; both show `MemAvailable`.
- README and manifest say that `showCpuTemp`/`showGpuTemp` add the standalone
  temperature cells of `icons` mode, and list the `show`/`hide` IPC calls.

### Fixed

- Every NVIDIA card is listed, so `gpu` can select a second one.
- AMD cards without a marketing name in `pci.ids` are named from their device
  entry instead of "AMD/ATI", which also makes them selectable by name.
- A sensor file whose only line has no trailing newline is read instead of
  skipped.
- Until the probe answers, the CPU has no placeholder "CPU" model name, so the
  panel header and `status` show their unknown-CPU fallbacks instead.
- Grouped top processes no longer fold systemd services (journald, logind,
  oomd...) into pid 1's "systemd" row under a borrowed name such as
  "systemd-oomd · 12"; a merged group is named after its own app.
- A grouped row's RAM counts shared libraries and shared memory once instead of
  once per process, so multi-process apps no longer read up to twice their
  real footprint or outrank bigger single-process apps. A single process's
  figure now matches its `VmRSS`.
- On hosts with more than 4096 processes the newest ones are no longer
  silently left out of the top-processes list (the scan bound is now 16384).
- Non-ASCII app names from systemd units show one placeholder dot per
  character instead of one per byte.
- Apps started through `gtk-launch` (Spotify, for example) get their own
  top-processes rows instead of all sharing one "gtk-launch" row.
- Bar cells update in place on each sample instead of being rebuilt, so their
  colour and gauge-fill animations run, and only the bar's own orientation
  holds cells.
- The width reserved for a temperature figure follows `tempFormat`, so the
  narrower formats no longer leave a gap after the figure.
- With `ramFormat: "available"` the settings drawer now marks the Free chip.
- `status` no longer prints "undefined" for a GPU the probe could not name.

## 1.2.1 — 2026-10-16

### Fixed

- Helper output is treated as untrusted: the probe's JSON keeps only known
  keys, and a sensor path is accepted only under `/sys` or `/proc`, with path
  traversal refused and control characters stripped.
- Every helper process is bounded in time and output size, and a failed probe
  retries discovery after 30 seconds instead of leaving the widget without
  sensors until the shell reloads.
- An idle Intel discrete GPU with no display attached is skipped, so sampling
  no longer keeps it awake; with `nvidia-smi` installed but no NVIDIA card, its
  error text is no longer shown as a GPU name (#4).
- Glyphs from settings render as plain text, and `padOpacity` and the glyph
  rotation settings appear in the settings schema.

## 1.2.0 — 2026-10-10

### Added

- A top-processes section in the system panel, sorted by RAM or CPU and
  grouped by application, sampled only while the panel is open (#2, #3).

### Fixed

- Bar figure cells reserve their width, so the readout no longer shifts as
  numbers change (#3).

## 1.1.1 — 2026-09-29

### Added

- A settings drawer in the system panel (gear button or `s`) for readout mode,
  shown items, RAM and temperature format, and °C/°F.
- Settings for which items the bar shows and in what order, and more
  `ramFormat` and `tempFormat` options.

### Changed

- The plugin id is now `meviusisback.hw-monitor`; this fork continues Edgar
  Silva's original plugin.
- The `icons` readout shows GPU load, CPU load, CPU temperature with a
  thermometer glyph, and RAM.

### Fixed

- Panel layout clipping, doubled degree signs, a Tab navigation error, and
  missing temperatures in `full` mode.
- Bar glyphs follow the theme's foreground colour.

## 1.1.0 — 2026-09-01

### Added

- The `icons` readout, now the default: a glyph and a figure per component.
- A system panel on left click, with dials, a 60-second CPU load history, and
  processor, memory and GPU details.
- `monitors`, to draw the widget only on chosen screens.

## 1.0.0 — 2026-08-18

- First release: memory, CPU and GPU in the Omarchy bar as `compact`, `full`
  and `labels` readouts, read from `/proc` and `/sys`.
