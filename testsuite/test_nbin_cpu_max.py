"""The run stops at whichever of NBin or CPU_MAX comes first.

Upstream ALF discards NBin whenever CPU_MAX is set, so a run always burns its
whole time budget. This fork gates that override on NBin being unset, which is
what lets a checkpoint-restart driver ask for an exact number of bins and still
stay inside its wall-clock allocation.

Drives the ``Start`` parameter set already in the repository, rewriting only the
keys it varies, so the test needs no Python package beyond h5py -- in
particular no py_alf, whose forks differ in the arguments they accept.

Needs a built binary, so it skips unless ``Prog/ALF.out`` exists:

    cd ALF && source configure.sh GNU noMPI HDF5 && make program
    pytest testsuite/test_nbin_cpu_max.py
"""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

h5py = pytest.importorskip("h5py")

ALF_DIR = Path(__file__).resolve().parent.parent
ALF_BIN = ALF_DIR / "Prog" / "ALF.out"
START_DIR = ALF_DIR / "Scripts_and_Parameters_files" / "Start"

pytestmark = pytest.mark.skipif(
    not ALF_BIN.exists(), reason=f"{ALF_BIN} not built; run `make program` first"
)

# Shrunk from Start's 6x6 with time-displaced measurements: a bin then costs
# milliseconds, so a bin-bounded run finishes fast and a time-bounded one still
# produces plenty of bins.
SMALL = {
    "VAR_lattice": {"L1": 4, "L2": 4},
    "VAR_QMC": {"NSweep": 20, "Ltau": 0},
}


def _rewrite_parameters(path, overrides):
    """Rewrite ``key = value`` lines of *path*, per namelist.

    Scoping by namelist matters: several keys (``Beta`` for one) appear in more
    than one, and only the QMC namelist's copy should move.
    """
    namelist = None
    out = []
    for line in path.read_text().splitlines():
        stripped = line.strip()
        if stripped.startswith("&"):
            namelist = stripped[1:].split()[0]
        elif stripped.startswith("/"):
            namelist = None
        elif "=" in line and namelist in overrides:
            key = line.split("=", 1)[0].strip()
            for want, value in overrides[namelist].items():
                if key.lower() == want.lower():
                    line = f"{key:<20} = {value}"
                    break
        out.append(line)
    path.write_text("\n".join(out) + "\n")


def _run_alf(tmp_path, nbin, cpu_max):
    """Run ALF once in *tmp_path* and return the bins it wrote."""
    run_dir = tmp_path / "run"
    if not run_dir.exists():
        shutil.copytree(START_DIR, run_dir)
    overrides = {
        "VAR_lattice": dict(SMALL["VAR_lattice"]),
        "VAR_QMC": {**SMALL["VAR_QMC"], "NBin": nbin, "CPU_MAX": f"{cpu_max}d0"},
    }
    _rewrite_parameters(run_dir / "parameters", overrides)

    env = os.environ.copy()
    env["OMP_NUM_THREADS"] = "1"
    subprocess.run([str(ALF_BIN)], cwd=run_dir, env=env, check=True, timeout=900)

    with h5py.File(run_dir / "data.h5", "r") as f:
        return int(f["Ener_scal/obser"].shape[0])


def test_bin_bound_wins_when_it_is_reached_first(tmp_path):
    """A reachable NBin must be honoured exactly, not overshot.

    The time budget here is far larger than the work, so without the fix ALF
    would run the full CPU_MAX and produce many more bins than asked for.
    """
    assert _run_alf(tmp_path, nbin=20, cpu_max=1.0) == 20


def test_time_bound_still_applies_when_bins_are_out_of_reach(tmp_path):
    """A tiny budget must still truncate cleanly, well short of NBin.

    This is the graceful-stop path a checkpoint restart depends on: ALF breaks
    the bin loop on time, having already flushed the bins it completed.
    """
    bins = _run_alf(tmp_path, nbin=1_000_000, cpu_max=0.003)
    assert 0 < bins < 1_000_000


def test_no_bin_bound_is_pure_time_bounding(tmp_path):
    """NBin <= 0 keeps upstream's behaviour: run for the whole budget."""
    assert _run_alf(tmp_path, nbin=0, cpu_max=0.003) > 0


def test_bins_accumulate_across_a_restart(tmp_path):
    """Resuming appends to data.h5, so the bin bound counts this run's bins.

    That is what makes ``NBin = target - bins_on_disk`` land exactly on target.
    """
    assert _run_alf(tmp_path, nbin=10, cpu_max=1.0) == 10

    # Promote the checkpoint the way a restart does.
    run_dir = tmp_path / "run"
    for conf in run_dir.glob("confout_*"):
        conf.rename(run_dir / f"confin_{conf.name[len('confout_'):]}")

    assert _run_alf(tmp_path, nbin=5, cpu_max=1.0) == 15
