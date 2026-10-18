# Windows parity follow-up, October 18, 2026

Reference: [Windows #66](https://github.com/theatrus/seiza-win/pull/66),
reviewed at `b3d57c249b823a010f93e99905cfdf462c1824ba`. It is an open Windows
proposal; the Mac implementations are native and independently validated.

| Capability | Mac work |
| --- | --- |
| Current core/API baseline | [#76](https://github.com/theatrus/seiza-mac/pull/76): published core/C ABI 0.39.0, full generated header and flat-quality review |
| Persistent RC-Astro command | [#82](https://github.com/theatrus/seiza-mac/pull/82): Settings, bookmark renewal and synchronization across Parallax windows |
| Median Anchor and Layered | [#83](https://github.com/theatrus/seiza-mac/pull/83): complete image recipe controls and selectable live previews |
| Concurrent filter sessions | This branch: recursive discovery, independent calibration/checkpoints/previews, pause all and selected finish |
| Windows #64 long folder labels | Already present in Mac: one-line middle truncation, separate count and full-path help |

Merge order is #76, then #83, then the multi-filter follow-up. #82 is independent
and targets main. Layered defaults to linked color on Mac so mono data is valid;
RGB users can explicitly choose luminance-preserving color. Live preview changes
never alter accumulated linear FITS samples.

The published API now also supports measured flat-session response construction,
comparison and change maps. Those workflows still need dedicated Mac interaction
design and evidence handling; see [CALIBRATION-QUALITY.md](CALIBRATION-QUALITY.md).
This work does not silently select replacement flats or treat inconclusive dust
measurements as a passing result.
