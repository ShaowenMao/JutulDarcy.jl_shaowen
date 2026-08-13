# Step62 Initial-State Equilibrium Validation

This isolated workflow tests whether the imported all-brine initial state is a
discrete equilibrium for the exact JutulDarcy production model. It does not
modify production inputs, active jobs, restart files, or archived results.

## Scientific test

For each selected case, the workflow reconstructs the checksum-pinned split MAT
input using the exact production code and physics configuration. It then:

1. records the untouched pressure from the common MAT file;
2. records the assembled MRST pressure and Jutul reference-phase pressure;
3. measures the capillary-pressure adjustment applied during import;
4. computes exact TPFA liquid-potential residuals and liquid fluxes on all
   internal faces, faces touching the fault, and faces inside the fault;
5. disables every well and verifies that no boundary conditions or source terms
   are present;
6. advances a gravity-on, zero-injection control; and
7. records pressure, saturation, dissolved concentration, component masses,
   and face diagnostics without writing full-grid states.

An exactly equilibrated all-brine state should exhibit negligible liquid flux,
pressure change, saturation change, dissolved-concentration change, and total
mass drift. The workflow reports measurements rather than imposing a universal
pass/fail tolerance; tolerances must be interpreted relative to nonlinear and
linear solver settings and compared across representative cases.

## Staged use on Engaging

Run the helper self-test locally or on a login node; run all full-grid model
construction and simulation through Slurm.

1. Rank a modest candidate cohort with
   `gom_step62_initial_equilibrium_selection.sbatch`.
2. Submit one short smoke control, for example with report years
   `1/365.25,30/365.25,1`.
3. Inspect the imported-pressure, face-potential, and state-evolution tables.
4. Submit full logarithmic controls for a low-permeability case, a
   high-permeability case, and a case with heterogeneous entry pressure.

The default full report times are 1 day, 30 days, 1 year, 10 years, 100 years,
and 1,000 years. Override them with `GOM_EQUILIBRIUM_REPORT_YEARS`.

## Outputs

Each durable case directory contains:

- `initial_import_pressure_audit.tsv`
- `liquid_face_equilibrium.tsv`
- `zero_injection_state_evolution.tsv`
- `equilibrium_summary.txt`
- `RUN_METADATA.txt`
- `SHA256SUMS`
- `COMPLETE`

Results are first written to node-local storage and are only published to the
durable result root after checksum verification.
