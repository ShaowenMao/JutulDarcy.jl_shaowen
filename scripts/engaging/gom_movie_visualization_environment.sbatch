#!/bin/bash
#SBATCH --job-name=gom_movie_viz_env
#SBATCH --partition=mit_normal
#SBATCH --account=mit_amf_advanced_cpu
#SBATCH --qos=mit_amf_advanced_cpu
#SBATCH --time=02:00:00
#SBATCH --cpus-per-task=4
#SBATCH --mem=8G
#SBATCH --output=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.out
#SBATCH --error=/home/%u/orcd/scratch/gom_grid/logs/%x-%j.err

set -euo pipefail

: "${GOM_MOVIE_ENV_ROOT:?Set the durable visualization environment root.}"
: "${GOM_MOVIE_WORKFLOW_REPO:?Set the pinned visualization workflow checkout.}"

environment_root="$(readlink -m -- "$GOM_MOVIE_ENV_ROOT")"
workflow_repo="$(readlink -f -- "$GOM_MOVIE_WORKFLOW_REPO")"
durable_prefix="/orcd/data/juanes/001/shaowen/gom_grid/software"
case "$environment_root/" in
    "$durable_prefix/"*) ;;
    *)
        echo "Environment root is outside the approved durable software tree." >&2
        exit 1
        ;;
esac
test "$environment_root" != "$durable_prefix"

requirements="$workflow_repo/scripts/visualization/gom_rs_publication/requirements.txt"
test -s "$requirements"
expected_requirements_sha256="$(sha256sum "$requirements" | awk '{print $1}')"

verify_environment() {
    root="$1"
    test -f "$root/ENVIRONMENT_PASS"
    test -x "$root/python/bin/python"
    tex_bin="$(find "$root/tex/.TinyTeX/bin" -mindepth 1 -maxdepth 1 -type d | head -1)"
    test -n "$tex_bin"
    test -x "$tex_bin/latex"
    test -x "$tex_bin/dvipng"
    PATH="$tex_bin:$PATH" "$root/python/bin/python" - <<'PY'
import matplotlib
import numpy
import pyvista
import scipy

assert matplotlib.__version__ == "3.10.9"
assert numpy.__version__ == "2.4.4"
assert pyvista.__version__ == "0.48.4"
assert scipy.__version__ == "1.17.1"
PY
    grep -Fxq "requirements_sha256=$expected_requirements_sha256" \
        "$root/ENVIRONMENT_METADATA.txt"
}

if test -d "$environment_root"; then
    verify_environment "$environment_root"
    echo "Verified existing visualization environment: $environment_root"
    exit 0
fi

incoming="${environment_root}.incoming"
mkdir -p -- "$(dirname -- "$environment_root")" "$incoming"

python3.12 -m venv "$incoming/python"
"$incoming/python/bin/python" -m pip install --upgrade pip setuptools wheel
"$incoming/python/bin/python" -m pip install --requirement "$requirements"
"$incoming/python/bin/python" -m pip check

installer="$incoming/install-bin-unix.sh"
curl -fL --retry 10 --retry-delay 30 \
    https://tinytex.yihui.org/install-bin-unix.sh -o "$installer"
installer_sha256="$(sha256sum "$installer" | awk '{print $1}')"
mkdir -p -- "$incoming/tex"
bundle_cache="$incoming/tinytex-bundles"
mkdir -p -- "$bundle_cache"
TINYTEX_VERSION=2026.05 \
TINYTEX_INSTALLER=TinyTeX-1 \
TINYTEX_DIR="$incoming/tex" \
    sh "$installer" "$bundle_cache" --no-path
tex_root="$incoming/tex/.TinyTeX"
tex_bin="$(find "$tex_root/bin" -mindepth 1 -maxdepth 1 -type d | head -1)"
test -n "$tex_bin"
PATH="$tex_bin:$PATH" tlmgr update --self
PATH="$tex_bin:$PATH" tlmgr install dvipng type1cm cm-super
test -x "$tex_bin/latex"
test -x "$tex_bin/dvipng"

test_dir="$incoming/validation"
mkdir -p -- "$test_dir"
printf '%s\n' \
    '\documentclass{article}' \
    '\begin{document}' \
    '$R_s\;[\mathrm{mol}\,\mathrm{kg}^{-1}]$ and $S_g\;[-]$' \
    '\end{document}' \
    > "$test_dir/test.tex"
(
    cd "$test_dir"
    PATH="$tex_bin:$PATH" latex -halt-on-error -interaction=nonstopmode test.tex
    PATH="$tex_bin:$PATH" dvipng -D 120 -T tight -o test.png test.dvi
)
test -s "$test_dir/test.png"

GOM_ENV_TEST_DIR="$test_dir" PATH="$tex_bin:$PATH" MPLBACKEND=Agg \
    "$incoming/python/bin/python" - <<'PY'
import os
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pyvista as pv

plt.rcParams.update({
    "font.family": "serif",
    "font.serif": ["Computer Modern Roman"],
    "text.usetex": True,
})
fig, ax = plt.subplots(figsize=(3, 2))
ax.plot([0, 1], [0, 1])
ax.set_title(r"$R_s\;[\mathrm{mol}\,\mathrm{kg}^{-1}]$")
output = Path(os.environ["GOM_ENV_TEST_DIR"])
fig.savefig(output / "matplotlib_tex.png", dpi=300)
fig.savefig(output / "matplotlib_tex.pdf")
plt.close(fig)
assert pv.__version__ == "0.48.4"
PY
test -s "$test_dir/matplotlib_tex.png"
test -s "$test_dir/matplotlib_tex.pdf"

"$incoming/python/bin/python" -m pip freeze \
    > "$incoming/PYTHON_REQUIREMENTS_LOCK.txt"
PATH="$tex_bin:$PATH" tlmgr --version > "$incoming/TEXLIVE_VERSION.txt"
printf '%s\n' \
    'status=pass' \
    'python=3.12' \
    'matplotlib=3.10.9' \
    'numpy=2.4.4' \
    'pyvista=0.48.4' \
    'scipy=1.17.1' \
    'tinytex_version=2026.05' \
    'tinytex_bundle=TinyTeX-1' \
    "tinytex_installer_sha256=$installer_sha256" \
    "requirements_sha256=$expected_requirements_sha256" \
    "workflow_commit=$(git -C "$workflow_repo" rev-parse HEAD)" \
    "built_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$incoming/ENVIRONMENT_METADATA.txt"
printf 'PASS\n' > "$incoming/ENVIRONMENT_PASS"

test ! -e "$environment_root"
mv -- "$incoming" "$environment_root"
verify_environment "$environment_root"
echo "Visualization environment completed: $environment_root"
