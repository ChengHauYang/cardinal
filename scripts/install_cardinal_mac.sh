#!/usr/bin/env bash
#
# install_cardinal_mac.sh
#
# One-shot installer for Cardinal + OpenMC on macOS (Apple Silicon or Intel),
# using an existing MOOSE conda environment.
#
# It performs the full sequence:
#
#   1. Preflight checks (macOS, Xcode CLT, conda, MOOSE env, disk space)
#   2. Clone (or reuse) the Cardinal repository
#   3. Fetch submodules via scripts/get-dependencies.sh
#   4. Export the build environment (ENABLE_NEK / HDF5_ROOT / library paths)
#   5. make -j<N>
#   6. Download the OpenMC ENDF/B-VII.1 cross-section library
#   7. Write cardinal_env.sh (and optionally hook it into your shell rc)
#   8. Smoke-test the build
#
# Usage:
#   ./install_cardinal_mac.sh [options]
#
# Run with --help for the full option list.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

CONDA_ENV="moose"
PREFIX="${HOME}"
REPO_URL="https://github.com/neams-th-coe/cardinal.git"
BRANCH=""
XS_DIR=""                     # resolved after PREFIX is known
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
ENABLE_NEK="false"
SKIP_CLONE=0
SKIP_DEPS=0
SKIP_BUILD=0
SKIP_XS=0
SKIP_TESTS=0
WRITE_RC=0
CLEAN=0

# Cap the default job count; the MOOSE/OpenMC compile is memory hungry
# (roughly 2 GB of RAM per parallel C++ translation unit at peak).
if [[ "${JOBS}" -gt 8 ]]; then JOBS=8; fi

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_BLD=$'\033[1m';  C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_OFF=""
fi

STEP_NO=0
step() { STEP_NO=$((STEP_NO + 1)); printf '\n%s==> [%d/8] %s%s\n' "${C_BLU}${C_BLD}" "${STEP_NO}" "$*" "${C_OFF}"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✓%s %s\n' "${C_GRN}" "${C_OFF}" "$*"; }
warn() { printf '    %s!%s %s\n' "${C_YEL}" "${C_OFF}" "$*"; }
die()  { printf '\n%serror:%s %s\n\n' "${C_RED}${C_BLD}" "${C_OFF}" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
${C_BLD}install_cardinal_mac.sh${C_OFF} — install Cardinal + OpenMC on macOS

${C_BLD}Options${C_OFF}
  --conda-env NAME   MOOSE conda environment to build in   (default: ${CONDA_ENV})
  --prefix DIR       Parent directory for the checkout      (default: ${PREFIX})
  --branch NAME      Git branch/tag to check out            (default: repo default)
  --repo URL         Git remote to clone from               (default: upstream)
  --xs-dir DIR       Cross-section install directory        (default: <prefix>/cross_sections)
  -j, --jobs N       Parallel compile jobs                  (default: ${JOBS})

  --enable-nek       Also build NekRS (sets NEKRS_HOME automatically)
  --clean            Remove build/ and install/ before compiling

  --skip-clone       Reuse the existing checkout, do not git clone/fetch
  --skip-deps        Skip scripts/get-dependencies.sh (submodules)
  --skip-build       Skip the compile step
  --skip-xs          Skip the cross-section download
  --skip-tests       Skip the post-install smoke test

  --write-rc         Append 'source <cardinal>/cardinal_env.sh' to your shell rc
  -h, --help         Show this help

${C_BLD}Examples${C_OFF}
  # Standard fresh install into \$HOME/cardinal
  ./install_cardinal_mac.sh

  # Rebuild an existing checkout with 12 cores, no re-download of data
  ./install_cardinal_mac.sh --skip-clone --skip-xs -j 12

  # Full build including NekRS
  ./install_cardinal_mac.sh --enable-nek
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --conda-env) CONDA_ENV="${2:?--conda-env needs a value}"; shift 2 ;;
    --prefix)    PREFIX="${2:?--prefix needs a value}";       shift 2 ;;
    --branch)    BRANCH="${2:?--branch needs a value}";       shift 2 ;;
    --repo)      REPO_URL="${2:?--repo needs a value}";       shift 2 ;;
    --xs-dir)    XS_DIR="${2:?--xs-dir needs a value}";       shift 2 ;;
    -j|--jobs)   JOBS="${2:?--jobs needs a value}";           shift 2 ;;
    --enable-nek) ENABLE_NEK="true"; shift ;;
    --clean)      CLEAN=1;      shift ;;
    --skip-clone) SKIP_CLONE=1; shift ;;
    --skip-deps)  SKIP_DEPS=1;  shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --skip-xs)    SKIP_XS=1;    shift ;;
    --skip-tests) SKIP_TESTS=1; shift ;;
    --write-rc)   WRITE_RC=1;   shift ;;
    -h|--help)    usage; exit 0 ;;
    *) die "unknown option: $1  (try --help)" ;;
  esac
done

[[ "${JOBS}" =~ ^[0-9]+$ && "${JOBS}" -gt 0 ]] || die "--jobs must be a positive integer, got '${JOBS}'"

PREFIX="${PREFIX%/}"
CARDINAL_DIR="${PREFIX}/cardinal"
XS_DIR="${XS_DIR:-${PREFIX}/cross_sections}"
XS_DIR="${XS_DIR%/}"
XS_XML="${XS_DIR}/endfb-vii.1-hdf5/cross_sections.xml"

# If this script is being run from inside an existing checkout, build that one
# rather than cloning a second copy somewhere else.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
if [[ -f "${SCRIPT_DIR}/../Makefile" && -d "${SCRIPT_DIR}/../contrib" ]]; then
  CARDINAL_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
  SKIP_CLONE=1
fi

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------

step "Preflight checks"

[[ "$(uname -s)" == "Darwin" ]] || die "this script targets macOS; on Linux use the standard build instructions"
ok "macOS $(sw_vers -productVersion) on $(uname -m)"

xcode-select -p &>/dev/null || die "Xcode command line tools missing. Run: xcode-select --install"
ok "Xcode command line tools present"

command -v git  >/dev/null || die "git not found on PATH"
command -v curl >/dev/null || command -v wget >/dev/null || die "need curl or wget to download cross sections"

# Locate conda and make 'conda activate' usable from a non-interactive script.
if ! command -v conda >/dev/null; then
  die "conda not found on PATH. Install miniforge and re-run."
fi
CONDA_BASE="$(conda info --base)"
# shellcheck disable=SC1091
set +u
source "${CONDA_BASE}/etc/profile.d/conda.sh"
conda activate "${CONDA_ENV}" 2>/dev/null \
  || { set -u; die "conda environment '${CONDA_ENV}' not found.
    Create it first, e.g.:
      conda create -n ${CONDA_ENV} moose-dev -c https://conda.software.inl.gov/public"; }
set -u
ok "conda environment '${CONDA_ENV}' active (${CONDA_PREFIX})"

# The MOOSE conda package sets these from its activate.d hooks. Without them
# the Cardinal Makefile cannot find PETSc or libMesh.
[[ -n "${PETSC_DIR:-}"   ]] || die "PETSC_DIR is unset — '${CONDA_ENV}' does not look like a moose-dev environment"
[[ -n "${LIBMESH_DIR:-}" ]] || die "LIBMESH_DIR is unset — '${CONDA_ENV}' does not look like a moose-dev environment"
ok "PETSC_DIR=${PETSC_DIR}"
ok "LIBMESH_DIR=${LIBMESH_DIR}"

for tool in mpicc mpicxx cmake ninja; do
  command -v "${tool}" >/dev/null || die "'${tool}' not found in the '${CONDA_ENV}' environment"
done
ok "toolchain: $(mpicxx --version 2>/dev/null | head -1)"

# HDF5 must come from conda; the Makefile default ($PETSC_DIR/$PETSC_ARCH) does
# not exist in a conda-based MOOSE install.
[[ -f "${CONDA_PREFIX}/include/hdf5.h" ]] || die "hdf5.h not found in ${CONDA_PREFIX}/include — install hdf5 into the '${CONDA_ENV}' env"
ok "HDF5 headers found in ${CONDA_PREFIX}"

# The build tree plus cross sections need a fair amount of room.
DF_TARGET="${PREFIX}"
while [[ ! -d "${DF_TARGET}" && "${DF_TARGET}" != "/" ]]; do DF_TARGET="$(dirname "${DF_TARGET}")"; done
AVAIL_GB="$(df -g "${DF_TARGET}" 2>/dev/null | awk 'NR==2 {print $4}')"
if [[ -z "${AVAIL_GB}" ]]; then
  warn "could not determine free disk space on ${DF_TARGET}"
elif [[ "${AVAIL_GB}" -lt 30 ]]; then
  warn "only ${AVAIL_GB} GB free on ${DF_TARGET}; a full build + cross sections needs roughly 30 GB"
else
  ok "${AVAIL_GB} GB free on ${DF_TARGET}"
fi

info "build plan: jobs=${JOBS}  nek=${ENABLE_NEK}  target=${CARDINAL_DIR}"

# ---------------------------------------------------------------------------
# 2. Source checkout
# ---------------------------------------------------------------------------

step "Cardinal source checkout"

if [[ "${SKIP_CLONE}" -eq 1 ]]; then
  [[ -d "${CARDINAL_DIR}" ]] || die "--skip-clone given but ${CARDINAL_DIR} does not exist"
  ok "reusing existing checkout at ${CARDINAL_DIR}"
elif [[ -d "${CARDINAL_DIR}/.git" ]]; then
  ok "checkout already present at ${CARDINAL_DIR}"
else
  mkdir -p "${PREFIX}"
  info "cloning ${REPO_URL} -> ${CARDINAL_DIR}"
  git clone "${REPO_URL}" "${CARDINAL_DIR}"
  ok "clone complete"
fi

cd "${CARDINAL_DIR}"

if [[ -n "${BRANCH}" ]]; then
  info "checking out '${BRANCH}'"
  git fetch origin "${BRANCH}"
  git checkout "${BRANCH}"
fi
ok "on $(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD)"

# ---------------------------------------------------------------------------
# 3. Submodules
# ---------------------------------------------------------------------------

step "Third-party dependencies (submodules)"

if [[ "${SKIP_DEPS}" -eq 1 ]]; then
  warn "skipped (--skip-deps)"
else
  info "this fetches moose, openmc, nekRS, DAGMC, moab, ... and takes a while"
  ./scripts/get-dependencies.sh
  ok "submodules checked out"
fi

# ---------------------------------------------------------------------------
# 4. Build environment
# ---------------------------------------------------------------------------

step "Build environment"

export ENABLE_NEK
export ENABLE_OPENMC="true"

# Point OpenMC's HDF5 detection at conda instead of the (nonexistent)
# $PETSC_DIR/$PETSC_ARCH tree that the Makefile would otherwise assume.
export HDF5_ROOT="${CONDA_PREFIX}"

# macOS ignores LD_LIBRARY_PATH — the dynamic loader reads DYLD_* instead.
# We export both so the same env file works if it is ever reused on Linux.
export DYLD_LIBRARY_PATH="${CONDA_PREFIX}/lib${DYLD_LIBRARY_PATH:+:${DYLD_LIBRARY_PATH}}"
export LD_LIBRARY_PATH="${CONDA_PREFIX}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

# Used by MOOSE/libMesh sub-builds if they are ever triggered.
export MOOSE_JOBS="${JOBS}"
export LIBMESH_JOBS="${JOBS}"
export JOBS="${JOBS}"

if [[ "${ENABLE_NEK}" == "true" ]]; then
  # config/check_nekrs.mk hard-requires this to equal <cardinal>/install.
  export NEKRS_HOME="${CARDINAL_DIR}/install"
  ok "NEKRS_HOME=${NEKRS_HOME}"
else
  info "NekRS disabled (ENABLE_NEK=false); NEKRS_HOME not required"
fi

ok "HDF5_ROOT=${HDF5_ROOT}"
ok "DYLD_LIBRARY_PATH=${CONDA_PREFIX}/lib:..."

# ---------------------------------------------------------------------------
# 5. Compile
# ---------------------------------------------------------------------------

step "Compiling Cardinal"

if [[ "${SKIP_BUILD}" -eq 1 ]]; then
  warn "skipped (--skip-build)"
else
  if [[ "${CLEAN}" -eq 1 ]]; then
    info "removing build/ and install/"
    rm -rf build install
  fi
  info "make -j${JOBS}  (expect 30-90 minutes on a first build)"
  BUILD_START="$(date +%s)"
  make -j"${JOBS}"
  ok "build finished in $(( ($(date +%s) - BUILD_START) / 60 )) min"
fi

[[ -x "${CARDINAL_DIR}/cardinal-opt" ]] || die "cardinal-opt was not produced — check the compile output above"
ok "binary: ${CARDINAL_DIR}/cardinal-opt"

# ---------------------------------------------------------------------------
# 6. OpenMC cross sections
# ---------------------------------------------------------------------------

step "OpenMC cross-section data (ENDF/B-VII.1)"

if [[ "${SKIP_XS}" -eq 1 ]]; then
  warn "skipped (--skip-xs)"
elif [[ -f "${XS_XML}" ]]; then
  ok "already present at ${XS_XML}"
else
  info "downloading a few GB into ${XS_DIR} — this is the step that is usually missed"
  # The upstream helper creates endfb-vii.1-hdf5/ *before* downloading and then
  # short-circuits on any later run if that directory exists. Clear a partial
  # extraction out of the way so an interrupted download is actually retried.
  if [[ -d "${XS_DIR}/endfb-vii.1-hdf5" ]]; then
    warn "found an incomplete ${XS_DIR}/endfb-vii.1-hdf5 (no cross_sections.xml); removing it to retry"
    rm -rf "${XS_DIR}/endfb-vii.1-hdf5"
  fi
  mkdir -p "${XS_DIR}"
  # The upstream helper takes the download directory as its first argument and
  # unpacks endfb-vii.1-hdf5/ beneath it.
  ./scripts/download-openmc-cross-sections.sh "${XS_DIR}"
  [[ -f "${XS_XML}" ]] || die "download finished but ${XS_XML} is missing"
  ok "cross sections installed"
fi

if [[ -f "${XS_XML}" ]]; then
  export OPENMC_CROSS_SECTIONS="${XS_XML}"
  ok "OPENMC_CROSS_SECTIONS=${OPENMC_CROSS_SECTIONS}"
else
  warn "OPENMC_CROSS_SECTIONS not set; every OpenMC test will fail until it is"
fi

# ---------------------------------------------------------------------------
# 7. Persist the environment
# ---------------------------------------------------------------------------

step "Writing cardinal_env.sh"

ENV_FILE="${CARDINAL_DIR}/cardinal_env.sh"
{
  echo "# Generated by scripts/install_cardinal_mac.sh on $(date)"
  echo "# Source this before building or running Cardinal:"
  echo "#   source ${ENV_FILE}"
  echo ""
  echo "conda activate ${CONDA_ENV}"
  echo ""
  echo "export CARDINAL_DIR=\"${CARDINAL_DIR}\""
  echo "export ENABLE_NEK=${ENABLE_NEK}"
  echo "export ENABLE_OPENMC=true"
  echo "export HDF5_ROOT=\"\${CONDA_PREFIX}\""
  echo ""
  echo "# macOS uses DYLD_LIBRARY_PATH; LD_LIBRARY_PATH is kept for portability."
  echo "export DYLD_LIBRARY_PATH=\"\${CONDA_PREFIX}/lib\${DYLD_LIBRARY_PATH:+:\${DYLD_LIBRARY_PATH}}\""
  echo "export LD_LIBRARY_PATH=\"\${CONDA_PREFIX}/lib\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}\""
  echo ""
  echo "export MOOSE_JOBS=${JOBS}"
  echo "export LIBMESH_JOBS=${JOBS}"
  echo "export JOBS=${JOBS}"
  if [[ "${ENABLE_NEK}" == "true" ]]; then
    echo ""
    echo "export NEKRS_HOME=\"${CARDINAL_DIR}/install\""
  fi
  if [[ -f "${XS_XML}" ]]; then
    echo ""
    echo "export OPENMC_CROSS_SECTIONS=\"${XS_XML}\""
  fi
  echo ""
  echo "export PATH=\"${CARDINAL_DIR}:\${PATH}\""
} > "${ENV_FILE}"
chmod +x "${ENV_FILE}"
ok "wrote ${ENV_FILE}"

RC_FILE="${HOME}/.zshrc"
[[ "${SHELL##*/}" == "bash" ]] && RC_FILE="${HOME}/.bash_profile"
RC_LINE="source ${ENV_FILE}"

if [[ "${WRITE_RC}" -eq 1 ]]; then
  if grep -qF "${RC_LINE}" "${RC_FILE}" 2>/dev/null; then
    ok "${RC_FILE} already sources it"
  else
    printf '\n# Cardinal\n%s\n' "${RC_LINE}" >> "${RC_FILE}"
    ok "appended to ${RC_FILE}"
  fi
else
  info "to load it automatically:  echo '${RC_LINE}' >> ${RC_FILE}"
fi

# ---------------------------------------------------------------------------
# 8. Smoke test
# ---------------------------------------------------------------------------

step "Smoke test"

if [[ "${SKIP_TESTS}" -eq 1 ]]; then
  warn "skipped (--skip-tests)"
elif [[ ! -f "${XS_XML}" ]]; then
  warn "no cross sections — skipping (OpenMC tests cannot pass without them)"
else
  info "running the openmc_errors/fixed_source test group"
  if ./run_tests --re 'openmc_errors/fixed_source' -j "${JOBS}"; then
    ok "smoke test passed"
  else
    warn "smoke test failed — see the output above"
    warn "run the full suite with:  cd ${CARDINAL_DIR} && ./run_tests -j ${JOBS}"
  fi
fi

# ---------------------------------------------------------------------------

cat <<EOF

${C_GRN}${C_BLD}Cardinal is installed.${C_OFF}

  source ${ENV_FILE}
  cd ${CARDINAL_DIR}
  ./run_tests -j ${JOBS}

EOF
