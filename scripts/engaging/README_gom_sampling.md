# GoM Sampling Cases on Engaging

This folder contains an Engaging `sbatch` launcher for the four 87-slice GoM input combinations:

- `all87_whole`: one full `.mat` file where all 87 fault slices are sampled independently.
- `all87_split`: shared common `.mat` plus one realization-specific `.mat` for the same all-independent sampling.
- `old86_whole`: one full `.mat` file for the 86-independent-sample setup.
- `old86_split`: shared common `.mat` plus one realization-specific `.mat` for the 86-independent-sample setup.

The whole cases are useful as baselines/checks. For large future sweeps, the split cases are the cleaner production pattern because many realizations can share the same common file.

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
sbatch --array=1-4 scripts/engaging/gom_sampling_cases.sbatch
```

The array index maps to:

```text
1 = all87_whole
2 = all87_split
3 = old86_whole
4 = old86_split
```

Simulation mode writes restart `.jld2` files only. It does not load all restart states at the end and does not write VTU files, so the simulation timing summary stays clean.

## Submit One Simulation Case

```bash
sbatch --export=ALL,CASE_ID=all87_split scripts/engaging/gom_sampling_cases.sbatch
```

Valid `CASE_ID` values are `all87_whole`, `all87_split`, `old86_whole`, and `old86_split`. The numeric values `1`, `2`, `3`, and `4` also work.

## Generate VTU for One Completed Case

After a simulation finishes, submit a separate VTU job for only the case you want to visualize:

```bash
sbatch --export=ALL,RUN_MODE=vtu,CASE_ID=all87_split scripts/engaging/gom_sampling_cases.sbatch
```

The VTU job uses the same `CASE_TAG` and `RUN_ROOT` convention as the simulation job, so it looks for restart files at:

```bash
$RUN_ROOT/$CASE_TAG/restart
```

and writes visualization files to:

```bash
$RUN_ROOT/$CASE_TAG/vtu
```

## Useful Overrides

Use these when the repository, inputs, or output folder differ from the defaults:

```bash
sbatch --export=ALL,REPO_ROOT=/path/to/repo,INPUT_ROOT=/path/to/inputs,RUN_ROOT=/path/to/runs,CASE_ID=old86_split scripts/engaging/gom_sampling_cases.sbatch
```

By default, `CASE_TAG` is the case key, for example `all87_split`. If you want a separate output folder for a rerun, set `CASE_TAG`:

```bash
sbatch --export=ALL,CASE_ID=all87_split,CASE_TAG=all87_split_retry01 scripts/engaging/gom_sampling_cases.sbatch
```

For simulation jobs, the script defaults to `HYPRE_THREADS=8` and uses `SLURM_CPUS_PER_TASK` for Julia threads. For VTU-only jobs, it defaults to `HYPRE_THREADS=1`.
