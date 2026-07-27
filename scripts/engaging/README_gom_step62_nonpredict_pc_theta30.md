# Step62 non-PREDICT Pc reference comparison

This run family repeats the accepted four-geology production case while
changing only the shared non-PREDICT fault Pc reference contact angle from
70 degrees to 30 degrees.

The locked runtime configuration remains:

```text
cases=01,03,04,07
grid=Step62
slices=87
cells=2165082
schedule_steps=210
schedule_end=1000 years
injection_end=50 years
hysteresis=true
hysteresis_s_min=0.05
explicit_fault_hysteresis=drainage-equivalent
fault_pc_plateau=522 explicit PREDICT tables only
fault_pc_plateau_sg_max=1e-4
transmissibility=JutulDarcy
well_volume_fraction=1e-3
```

The accepted four geology-specific MAT files must be reused byte-for-byte.
Only the common MAT file changes, and its preparation-time differential
validator must pass before Jutul submission.

Submit the preflight, three-step smoke, and production arrays with
dependencies:

```bash
preflight_job=$(sbatch --parsable \
  scripts/engaging/gom_step62_four_geology_np_pc_theta30_preflight.sbatch)
smoke_job=$(sbatch --parsable --dependency=afterok:${preflight_job} \
  scripts/engaging/gom_step62_four_geology_np_pc_theta30_smoke.sbatch)
full_job=$(sbatch --parsable --dependency=afterok:${smoke_job} \
  scripts/engaging/gom_step62_four_geology_np_pc_theta30_full.sbatch)
```

Each submission requires:

```text
GOM_FOUR_GEOLOGY_INPUT_DIR
JUTULDARCY_COMBINED_REPO
GOM_GRID_ROOT
```

Expected non-PREDICT entry pressures at `Sg=0.001` are:

| Band | Entry pressure |
|---|---:|
| LM2 | 19.329059 kPa |
| MM-UM | 2.086237 kPa |
| Younger | 0.642426 kPa |
