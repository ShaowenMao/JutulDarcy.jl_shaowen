# GOM y-z movie-frame workflow

This workflow applies the approved publication renderer to every report time
of the three designated Step62 movie cases. It does not apply to the full
1,620-case ensemble.

## Figure contract

Analytical question: how do dissolved and free-phase CO2 migrate through the
faulted reservoir and interbedded top seal over the common 1,000-year
schedule?

The visual contract is fixed across cases and time:

- cases: source tasks 5, 6, and 7;
- time grain: report steps 1:210 (the initial-condition VTU is not a report
  frame and does not contain `Rs`);
- quantities: `Rs` and `Saturations_2` (`S_g`);
- slice: y-z plane at x = 22,500 m;
- smoothing: connected, geology-aware, and lithology-connected within the
  non-fault stratigraphy;
- context: grey clay interbeds and dark fault feature edges;
- `Rs`: CSP11 IceFire with white at zero, fixed range 0-18;
- `S_g`: inverted Black-Body Radiation, fixed range 0-0.6;
- display cutoff: 0.015 for both variants;
- typography: black, left-aligned, 10 pt LaTeX text;
- raster output: 600-dpi PNG for every report time; and
- vector output: PDF at 25, 50, 100, and 1,000 years only.

The PVD collections provide the exact physical time. Every frame therefore
uses the same adaptive hour/day/year label and can be assembled into a
temporally correct movie.

## Work partition

`render_gom_movie_frames.py` maps a 126-task array into:

- 3 cases;
- 2 quantities; and
- 21 chunks of at most 10 report steps.

Each frame has a JSON completion marker tied to the input VTU size and
modification time. Resubmitting a failed chunk skips already validated frames.

The full durable payload contains:

- 1,260 PNG frames (210 x 3 x 2);
- 24 selected-time PDFs (4 x 3 x 2);
- 1,260 geological-domain audit CSVs;
- per-frame renderer logs and completion markers; and
- one time/path manifest per case and quantity.

`validate_gom_movie_frames.py` inspects every PNG and PDF, reconciles times
against the source PVD, validates every marker, writes a SHA-256 manifest, and
creates the final `PASS` marker.

## Engaging chain

The dependency-safe sequence is:

1. build and validate the pinned Python/TinyTeX environment;
2. finish and certify all-timestep VTU export;
3. render Case 7 final-time `Rs` and `S_g` smoke figures;
4. validate the smoke figures;
5. render the full 126-task frame array; and
6. validate and certify the complete durable output.

Large inputs and outputs live below
`/orcd/data/juanes/001/shaowen/gom_grid/movie_runs`. Scratch contains only
small Slurm logs and node-local temporary/cache files.
