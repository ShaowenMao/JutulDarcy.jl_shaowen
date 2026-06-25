# GoM Sampling Cases on Engaging

This folder contains an Engaging `sbatch` launcher for the four 87-slice GoM input combinations:

- `all87_whole`: one full `.mat` file where all 87 fault slices are sampled independently.
- `all87_split`: shared common `.mat` plus one realization-specific `.mat` for the same all-independent sampling.
- `old86_whole`: one full `.mat` file for the 86-independent-sample setup.
- `old86_split`: shared common `.mat` plus one realization-specific `.mat` for the 86-independent-sample setup.

The whole cases are useful as baselines/checks. For large future sweeps, the split cases are the cleaner production pattern because many realizations can share the same common file.

The launcher requests the advanced CPU account/QOS:

```bash
#SBATCH -A mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
```

## Expected Engaging Layout

By default, the script expects the input files under:

```bash
/home/$USER/orcd/pool/jutuldarcy_case/gom_sampling_inputs
```

with this structure:

```text
gom_sampling_inputs/
  all87/
    jutul/
      lluis_field_case_87_all87_whole.mat
    jutul_split/
      lluis_field_case_87_all87_common.mat
      lluis_field_case_87_all87_realization_0001_specific.mat
  old86/
    jutul/
      lluis_field_case_87_old86_whole.mat
    jutul_split/
      lluis_field_case_87_old86_common.mat
      lluis_field_case_87_old86_realization_0001_specific.mat
```

If you put the files somewhere else, submit with `INPUT_ROOT=/path/to/gom_sampling_inputs`.

## Submit All Four Simulation Cases

From the repository on Engaging:

```bash
mkdir -p /home/$USER/orcd/scratch/jutuldarcy_case/gom_sampling_runs
sbatch --array=1-4 scripts/engaging/gom_sampling_cases.sbatch
```

The array index maps to:

```text
1 = all87_whole, MAX_TIMESTEP_CUTS=25
2 = all87_split, MAX_TIMESTEP_CUTS=25
3 = old86_whole, MAX_TIMESTEP_CUTS=25
4 = old86_split, MAX_TIMESTEP_CUTS=25
```

Simulation mode writes restart `.jld2` files only. It does not load all restart states at the end and does not write VTU files, so the simulation timing summary stays clean.

To run the same four cases with EHYSTR hysteresis disabled without modifying the `.mat` files, set `DISABLE_HYSTERESIS=true`:

```bash
sbatch --export=ALL,DISABLE_HYSTERESIS=true --array=1-4 scripts/engaging/gom_sampling_cases.sbatch
```

Those folders include `_nohyst`, for example:

```text
all87_split_cuts25_nohyst_job16482723/
```

If you want to limit how many run at once, use Slurm's array concurrency limit. For example, at most two at once:

```bash
sbatch --array=1-4%2 scripts/engaging/gom_sampling_cases.sbatch
```

## Submit One Simulation Case

```bash
mkdir -p /home/$USER/orcd/scratch/jutuldarcy_case/gom_sampling_runs
sbatch --export=ALL,CASE_ID=all87_split_cuts25 scripts/engaging/gom_sampling_cases.sbatch
```

Valid default `CASE_ID` values are `all87_whole`, `all87_split`, `old86_whole`, `old86_split`, `all87_whole_cuts25`, `all87_split_cuts25`, `old86_whole_cuts25`, and `old86_split_cuts25`. The numeric values `1` through `4` also work.

For deliberate comparison reruns, explicit legacy names `all87_whole_cuts8`, `all87_split_cuts8`, `old86_whole_cuts8`, and `old86_split_cuts8` still work and mean `MAX_TIMESTEP_CUTS=8`.

## Submit Old GoM Large Control

To compare the current driver/sbatch setup against the previous `gom_large_hys` input, run one control job using the old input file:

```bash
sbatch --export=ALL,CASE_ID=gom_large_hys_control scripts/engaging/gom_sampling_cases.sbatch
```

By default this reads:

```bash
/home/$USER/orcd/pool/jutuldarcy_case/gom_inputs/lluis_field_case.mat
```

This defaults to `MAX_TIMESTEP_CUTS=25`. To deliberately rerun the old control with `MAX_TIMESTEP_CUTS=8`, use:

```bash
sbatch --export=ALL,CASE_ID=gom_large_hys_control_cuts8 scripts/engaging/gom_sampling_cases.sbatch
```

If the old input lives somewhere else, override `GOM_LARGE_HYS_MATFILE_PATH`.

## Generate VTU for One Completed Case

After a simulation finishes, submit a separate VTU job for only the case you want to visualize:

```bash
sbatch --export=ALL,RUN_MODE=vtu,CASE_ID=all87_split_cuts25,CASE_TAG=all87_split_cuts25_job16423849 scripts/engaging/gom_sampling_cases.sbatch
```

The VTU job uses the same `CASE_TAG` and `RUN_ROOT` convention as the simulation job, so it looks for restart files at:

```bash
$RUN_ROOT/$CASE_TAG/restart
```

and writes visualization files to:

```bash
$RUN_ROOT/$CASE_TAG/vtu
```

Detailed stdout/stderr logs are written next to each case:

```bash
$RUN_ROOT/$CASE_TAG/logs
```

Slurm initially creates small `slurm-bootstrap-*.out` and `slurm-bootstrap-*.err` files in `$RUN_ROOT` because it needs a stdout/stderr target before the script can calculate the case folder.

By default, case folders include the timestep-cut setting and Slurm array job id, for example:

```text
all87_split_cuts25_job16423849/
```

The script moves those bootstrap logs into the same `logs/` folder after startup. If a job fails before the script starts, a bootstrap log can still remain directly under `$RUN_ROOT`.

Because a later VTU-only job has a different Slurm job id, pass the simulation `CASE_TAG` explicitly when exporting visualization from a completed run:

```bash
sbatch --export=ALL,RUN_MODE=vtu,CASE_ID=all87_split_cuts25,CASE_TAG=all87_split_cuts25_job16423849 scripts/engaging/gom_sampling_cases.sbatch
```

## Useful Overrides

Use these when the repository, inputs, or output folder differ from the defaults:

```bash
sbatch --export=ALL,REPO_ROOT=/path/to/repo,INPUT_ROOT=/path/to/inputs,RUN_ROOT=/path/to/runs,CASE_ID=old86_split_cuts25 scripts/engaging/gom_sampling_cases.sbatch
```

By default, `CASE_TAG` is the case key plus timestep-cut setting plus Slurm array job id, for example `all87_split_cuts25_job16423849`. If you want a custom output folder for a rerun, set `CASE_TAG`:

```bash
sbatch --export=ALL,CASE_ID=all87_split_cuts25,CASE_TAG=all87_split_cuts25_retry01 scripts/engaging/gom_sampling_cases.sbatch
```

For simulation jobs, the script defaults to `HYPRE_THREADS=8` and uses `SLURM_CPUS_PER_TASK` for Julia threads. For VTU-only jobs, it defaults to `HYPRE_THREADS=1`.

After submission, confirm the account/QOS with:

```bash
scontrol show job <JOBID>_1 | grep -E "Account=|QOS=|Partition=|MinMemory"
```
