#!/bin/sh
# cyscale development tasks. Usage: ./dev.sh <command>
set -eu

# Always regenerate the committed .c files through setup.py, never the
# standalone `cythonize` CLI: setup.py passes relative Extension sources, so
# the Cython metadata embedded in the .c files stays relative
# ("scalecodec/types.pyx") instead of leaking an absolute local path.
# `--no-project` skips uv's own build of the package, which would otherwise
# run without Cython and fail on a missing/stale .c file. The build targets
# the project venv's interpreter so `test` picks up the freshly built .so.
if [ -x .venv/bin/python ]; then
    PY="$(.venv/bin/python -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
else
    PY="3"
fi
BUILD="uv run --no-project --python $PY --with cython --with setuptools python setup.py build_ext --inplace"

cmd="${1:-help}"
[ "$#" -gt 0 ] && shift

case "$cmd" in
    build)
        # Regenerate .c for changed .pyx files and build extensions in place.
        $BUILD
        ;;
    rebuild-all)
        # Force-regenerate every extension, then restore .c files whose .pyx
        # did not change (a full rebuild re-emits them with harmless
        # Cython-output drift, which is pure diff noise).
        $BUILD --force
        git diff --name-only -- 'scalecodec/*.c' 'scalecodec/utils/*.c' | while read -r f; do
            pyx="${f%.c}.pyx"
            if git diff --quiet -- "$pyx"; then
                git checkout -- "$f"
            fi
        done
        ;;
    test)
        # base58 is only needed by the b58encode comparison tests.
        uv run --with base58 pytest test/ "$@"
        ;;
    bench)
        uv run python benchmarks/bench.py "$@"
        ;;
    help|*)
        echo "usage: ./dev.sh {build|rebuild-all|test|bench} [args...]"
        echo
        echo "  build        regenerate .c for changed .pyx and build extensions in place"
        echo "  rebuild-all  force-regenerate everything, restoring diff-noise-only .c files"
        echo "  test         run the test suite (extra args passed to pytest)"
        echo "  bench        run benchmarks/bench.py (extra args passed through)"
        ;;
esac
