# Step62 all-timestep movie outputs

This workflow preserves the three designated 1,000-year movie simulations and
exports every report time without rerunning the simulations.

## Durable restart archive

`gom_step62_movie_restart_archive.sbatch` accepts a completed scratch result
root through `GOM_MOVIE_SOURCE_ROOT` and a destination below
`/orcd/data/juanes/001/shaowen/gom_grid/movie_runs` through
`GOM_MOVIE_ARCHIVE_ROOT`. The source simulation array job is supplied as
`GOM_MOVIE_SOURCE_JOB_ID`.

The archive job requires `PASS`, a passing movie summary, and restart steps
1:210 for each selected task. It then:

1. creates a SHA-256 manifest for every source file;
2. copies into a resumable `.incoming` directory;
3. verifies every archived file against the manifest;
4. atomically promotes the verified payload; and
5. removes the exact validated scratch source only when
   `GOM_MOVIE_REMOVE_SOURCE=true`.

An interrupted job can be resubmitted. A promoted archive is reverified before
any remaining source cleanup is completed.

## All-report-time VTU export

`gom_step62_movie_vtu_from_archive.sbatch` reads the durable restart archive
and writes its output directly beside it as `vtu_job<array-job-id>`. It uses
the original checksum-pinned science checkout via `GOM_MOVIE_SCIENCE_REPO`
and the separately versioned export scripts via `GOM_MOVIE_WORKFLOW_DIR`.

For each of tasks 5, 6, and 7, the exporter produces:

- one initial-condition VTU;
- one VTU for each of report steps 1:210;
- one PVD collection with physical time in years;
- categorical fault and stratigraphy indicators;
- a SHA-256 manifest covering all 212 visualization files; and
- metadata, validation output, and a `PASS` marker.

The VTU payload contains the compact state fields used by the established
visualization workflow. It does not add QoI tables or rerun the reservoir
simulation.
