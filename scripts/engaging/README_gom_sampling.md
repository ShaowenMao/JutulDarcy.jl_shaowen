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

To keep hysteresis enabled but raise the Killough hysteresis `s_min` threshold
from the `.mat` deck, set `HYSTERESIS_S_MIN`. This is the targeted stability
test for the hysteresis cases:

```bash
sbatch --export=ALL,HYSTERESIS_S_MIN=0.05 --array=1-4 scripts/engaging/gom_sampling_cases.sbatch
```

Those folders include the threshold, for example:

```text
all87_split_cuts25_smin0p05_job16482723/
```

To run the all87 split case with one cloned saturation domain for each
independent PREDICT fault sample, set `FAULT_SATURATION_DOMAIN_MODE`:

```bash
sbatch --export=ALL,CASE_ID=all87_split_cuts25,HYSTERESIS_S_MIN=0.05,FAULT_SATURATION_DOMAIN_MODE=predict_sample scripts/engaging/gom_sampling_cases.sbatch
```

This keeps the all87 split porosity, permeability, wells, schedule, and original
Pc/Kr curves unchanged. The script relabels the 87 x 6 PREDICT fault sample
groups into 522 fault saturation domains and clones the corresponding
drainage/imbibition SGOF tables. These folders include `_satpredict`, for
example:

```text
all87_split_cuts25_smin0p05_satpredict_job16482723/
```

To force a whole `.mat` file to ignore exported MRST transmissibilities `T` and
let JutulDarcy compute transmissibilities from grid and rock, set
`USE_MRST_TRANSMISSIBILITY=false`:

```bash
sbatch --export=ALL,CASE_ID=all87_whole,HYSTERESIS_S_MIN=0.05,USE_MRST_TRANSMISSIBILITY=false scripts/engaging/gom_sampling_cases.sbatch
```

The alias `IGNORE_MRST_T=true` is equivalent and takes precedence if both are
set. These folders include `_jutult`, for example:

```text
all87_whole_cuts25_smin0p05_jutult_job16482723/
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

## Generate VTU for the Eight Hysteresis Comparison Cases

For the current hysteresis-on job `16482723` and no-hysteresis job `16536683`, submit:

```bash
sbatch --array=1-8%4 scripts/engaging/gom_sampling_vtu_8cases.sbatch
```

The wrapper exports VTU files for:

```text
1 = all87_whole_cuts25_job16482723
2 = all87_split_cuts25_job16482723
3 = old86_whole_cuts25_job16482723
4 = old86_split_cuts25_job16482723
5 = all87_whole_cuts25_nohyst_job16536683
6 = all87_split_cuts25_nohyst_job16536683
7 = old86_whole_cuts25_nohyst_job16536683
8 = old86_split_cuts25_nohyst_job16536683
```

The hysteresis-on failed cases still have partial restart files, so their VTU
exports are useful for inspecting how far they got before the crash. Each case
writes VTU files to:

```bash
$RUN_ROOT/$CASE_TAG/vtu
```

If you rerun the simulations and get different Slurm job ids, override them:

```bash
sbatch --array=1-8%4 \
  --export=ALL,HYST_JOB_ID=<hysteresis_job_id>,NOHYST_JOB_ID=<nohyst_job_id> \
  scripts/engaging/gom_sampling_vtu_8cases.sbatch
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

For the fault Pc entry-pressure convergence experiment, use:

```bash
sbatch --export=ALL,CASE_ID=all87_split_cuts25,FAULT_PC_ENTRY_TREATMENT=plateau,FAULT_PC_ENTRY_SG_MAX=1.0e-4 scripts/engaging/gom_sampling_cases.sbatch
```

This only changes explicit split-input fault `SGOF` tables where the first point is `Sg=0, Pc=0` and the second point is a very small positive gas saturation. The case folder gets a `_pcplateau` tag.

To keep reservoir hysteresis active for explicit split fault tables while leaving fault curves drainage-only, add:

```bash
EXPLICIT_FAULT_HYSTERESIS_MODE=reservoir,HYSTERESIS_S_MIN=0.05
```

The script duplicates each explicit fault drainage table as its own imbibition table and preserves the common reservoir imbibition tables. The case folder gets a `_reshyst` tag.

After submission, confirm the account/QOS with:

```bash
scontrol show job <JOBID>_1 | grep -E "Account=|QOS=|Partition=|MinMemory"
```

## Solver Checkpoint Experiment

`gom_solver_checkpoint.sbatch` compares four numerical policies from the same
saved state without rerunning the earlier report steps:

| Task | Relaxation | Timestep policy |
|---|---|---|
| 1 | off | `TARGET_ITS=8`, `TARGET_DS=Inf`, maximum increase `10.0` |
| 2 | on | `TARGET_ITS=8`, `TARGET_DS=Inf`, maximum increase `10.0` |
| 3 | off | `TARGET_ITS=5`, `TARGET_DS=0.05`, maximum increase `1.25` |
| 4 | on | `TARGET_ITS=5`, `TARGET_DS=0.05`, maximum increase `1.25` |

Create the bootstrap-log directory and submit all four tasks with the restart
folder from the original run:

```bash
mkdir -p /home/$USER/orcd/scratch/jutuldarcy_case/gom_sampling_runs/solver_checkpoints

sbatch --array=1-4 \
  --export=ALL,SOURCE_RESTART_PATH=/path/to/original/restart,TARGET_REPORT_STEP=63 \
  scripts/engaging/gom_solver_checkpoint.sbatch
```

Each task links `jutul_62.jld2` into its own job-numbered folder, solves only
report step 63, and leaves the source restart folder unchanged. Set
`TARGET_REPORT_STEP=105` to repeat the comparison from `jutul_104.jld2`.

For the relaxation timestep-refinement experiment, tasks 1-2 solve step 63 at
`TARGET_DS=0.02/0.01`. Tasks 3-6 solve step 105 at
`TARGET_DS=Inf/0.05/0.02/0.01`. All six use relaxation, `TARGET_ITS=5`, a
maximum timestep increase of `1.25`, and 10 maximum nonlinear iterations:

```bash
sbatch --array=1-6 \
  --export=ALL,CHECKPOINT_EXPERIMENT=timestep_refinement,MAX_NONLINEAR_ITERATIONS=10,SOURCE_RESTART_PATH=/path/to/original/restart \
  scripts/engaging/gom_solver_checkpoint.sbatch
```

Use the one-task reference mode to solve step 105 with `TARGET_DS=0.005` from
the same `jutul_104.jld2` checkpoint:

```bash
sbatch --array=1 \
  --export=ALL,CHECKPOINT_EXPERIMENT=timestep_reference,SOURCE_RESTART_PATH=/path/to/original/restart \
  scripts/engaging/gom_solver_checkpoint.sbatch
```

## Solver Full-Run Comparison

`gom_solver_fullrun.sbatch` runs the `s05_c012_case01` split realization from
time zero with the validated relaxation policy. Task 1 uses `TARGET_DS=0.05`
and task 2 uses `TARGET_DS=0.02`; all physical-model and other solver controls
are identical.

```bash
sbatch --array=1-2 scripts/engaging/gom_solver_fullrun.sbatch
```

The two cases use the advanced CPU account, 8 Julia/HYPRE threads, 64 GB per
task, and a four-day wall-time limit. Restart and case-local log files are
written below `gom_sampling_runs`; VTU export remains disabled.
