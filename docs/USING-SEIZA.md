# Using Seiza

Seiza is built for two jobs: moving quickly through real observing data and
getting trustworthy sky context when you ask for it. Image loading, stretching,
catalog access, and solving all stay on the Mac.

The screenshots in this guide show the current development build in
[PR #12](https://github.com/theatrus/seiza-mac/pull/12). The downloadable v0.3.0
release and current `main` are compared in the
[README feature matrix](../README.md#feature-matrix).

## Open one image or a directory

Choose **File > Open** and select a FITS, JPEG, PNG, or TIFF image. You can also
select a directory or drop a new image or directory onto an existing viewer
window.

Directory windows include a thumbnail drawer and accept the left and right
arrow keys. Seiza caches thumbnails locally and preloads nearby entries, so
moving through a long sequence does not require each thumbnail to be decoded
again. A directory may mix FITS and ordinary raster images.

![Seiza browsing 299 FITS frames with cached thumbnails and live stretch controls](images/seiza-directory-stretch.png)

The viewer starts each image fitted to the available window. Pinch around the
pointer to zoom, drag or scroll to pan, and press **Command-0** to fit again.

## Build a FITS stretch

Click the **Stretch** toolbar button to open the compact editor. Stages run from
top to bottom and keep floating-point data between them; Seiza only makes an
8-bit display image after the final stage.

In the live stack editor you can:

- add another stage without closing the editor;
- select any existing stage and edit its method or parameters;
- move a stage earlier or later with the arrow controls;
- remove a stage with its × button;
- undo or redo committed stretch changes;
- subtract a smooth background gradient before the first stage; and
- open the same editor in a persistent, resizable utility panel with the
  pop-out button.

![A two-stage Generalized Hyperbolic and Linear stretch with background extraction enabled](images/seiza-stretch-stack.png)

Automatic methods include Auto MTF and Percentile Asinh. Manual methods include
Linear, Asinh, Midtones Transfer, and Generalized Hyperbolic Stretch (GHS). GHS
can sample its symmetry point directly from the displayed image. Color FITS
data can use linked channels, independent channels, or luminance-preserving
color handling.

Edits are debounced and rendered on a bounded preview away from the main thread.
Newer edits replace obsolete preview work. **Save Changes** commits the complete
draft stack as one undoable operation and restores the full-resolution render;
**Cancel** returns to the committed image.

## Read the image before and after stretching

Open the inspector with the right-sidebar toolbar button. For FITS images it
shows dimensions, encoding, robust input statistics, the active stretch, and
paired histograms:

- **Input** is computed from normalized linear samples before stretching.
- **Display** is computed from the rendered display pixels after the complete
  stretch stack.

The plots suppress the visual dominance of clipped endpoint bins without
changing the recorded counts. This makes the useful distribution readable
while preserving the distinction between input data and display output.

## Solve only when you ask

Seiza does not solve while opening, browsing, stretching, or exporting an
image. Press **Solve** when you want a WCS solution and catalog context. The
inspector then reports the field center, pixel scale, match count, RMS error,
acquisition time, and overlay counts.

![A solved North America and Pelican Nebula frame with catalog-colored outlines, named stars, WCS grid, histograms, and solve quality](images/seiza-solved-overlays.png)

Solving requires a local Seiza catalog directory. Open **Seiza > Settings**,
choose the standard package, and use **Download and Install Catalogs**. Setup
reports manifest, download, verification, installation, and completion
progress. See [Catalogs and solving](../README.md#catalogs-and-solving) for the
data layout and command-line equivalents.

## Choose the sky context you need

After a successful solve, the **Overlays** menu controls each layer without
rerunning the solver. Available layers include:

- named and field stars;
- individual deep-sky catalogs and object labels;
- detailed OpenNGC outlines;
- current and older transients;
- acquisition-time comets and asteroids;
- the RA/Dec grid and field center; and
- detected image stars.

![Seiza's overlay menu showing independently toggleable catalogs, outlines, stars, transients, Solar System bodies, grid, and field center](images/seiza-overlay-controls.png)

Catalog colors and outline styling match Seiza Server. Catalog association is
sky-coordinate context, not a claim that an object is visibly detected in the
pixels. Satellite overlays are not included yet.

## Export the result

Choose **File > Export** or press **Shift-Command-E**. Seiza writes PNG, JPEG,
or TIFF at the source image dimensions. You can export the displayed image by
itself or include the currently visible solve overlays. The committed
full-resolution render is used even when a smaller live preview is on screen.

## Finder Quick Look

After installing Seiza, select a `.fits`, `.fit`, or `.fts` file in Finder and
press Space. The bundled Quick Look extension makes a bounded stretched preview
without launching the full viewer or opening solver catalogs.
