# Image I/O boundary

The Mac app pins the prepared [Seiza 0.48 release](https://github.com/theatrus/seiza/pull/409)
commit `723fb702eb01283ddf0343a7217f7a987f0d709a` until publication. The complete
C header matches that revision. It includes the shared file-calibration coordinator,
header reads (#408) and small pixel-window reads (#407).

`SeizaCore.readHeader` calls `seiza_read_image_header_json` and returns the native
keyword values, FITS HISTORY/COMMENT records and XISF/PixInsight WCS cards. Seiza
owns container dispatch and header parsing. The Mac uses this wrapper for the
SEIZATRF display-product marker; its custom Rust export, FITS/XISF branch and
direct `seiza-xisf` dependency are removed. Existing C calls still own calibration
frame roles, physical compatibility, grading, grouping and matching.

The app, Quick Look and Finder thumbnails share one enabled astronomy-extension
list. File selectors and collection/stack filtering use that list too. This is
Mac format-support policy; the core also understands containers such as distributed
XISF headers that the app has not enabled as document types.

The release does not add a shared filename-filter classifier. Browser and optional
stack splitting retain their explicit filename heuristic. Native calibration
matching continues to use the file's actual FILTER metadata and compatibility
rules; filename guesses do not select calibration frames.

The generated header also exposes `seiza_read_image_window`, which can support a
future source-pixel readout without decoding a large mosaic. No current Mac feature
needs a separate source-window reader, so this change does not add an unused Swift
wrapper. Its raw samples would need to be distinguished from displayed/stretched
pixels, and compressed XISF can refuse window reads.

Regression tests cover header-only FITS reads with commentary, an XISF PixInsight
solution and display marker, native read failures, and existing display-product
render/save behavior. No stacking or stretching algorithms change here.
