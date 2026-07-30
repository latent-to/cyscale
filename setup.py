from setuptools import setup
from setuptools.extension import Extension

_cython_compiler_directives = {
    "language_level": "3",
    "boundscheck": False,
    "wraparound": False,
    "cdivision": True,
    "nonecheck": False,
}

_extensions = [
    Extension("scalecodec._scale_bytes", ["scalecodec/_scale_bytes.pyx"]),
    Extension("scalecodec._value_decode", ["scalecodec/_value_decode.pyx"]),
    Extension("scalecodec._primitives", ["scalecodec/_primitives.pyx"]),
    Extension("scalecodec._compact", ["scalecodec/_compact.pyx"]),
    Extension("scalecodec.utils._math", ["scalecodec/utils/_math.pyx"]),
    Extension("scalecodec.utils._ss58", ["scalecodec/utils/_ss58.pyx"]),
    Extension("scalecodec.base", ["scalecodec/base.pyx"]),
    Extension("scalecodec.types", ["scalecodec/types.pyx"]),
]

try:
    from Cython.Build import cythonize

    ext_modules = cythonize(
        _extensions, compiler_directives=_cython_compiler_directives
    )
except ImportError:
    # Fall back to pre-generated .c files when Cython is not installed
    ext_modules = [
        Extension("scalecodec._scale_bytes", ["scalecodec/_scale_bytes.c"]),
        Extension("scalecodec._value_decode", ["scalecodec/_value_decode.c"]),
        Extension("scalecodec._primitives", ["scalecodec/_primitives.c"]),
        Extension("scalecodec._compact", ["scalecodec/_compact.c"]),
        Extension("scalecodec.utils._math", ["scalecodec/utils/_math.c"]),
        Extension("scalecodec.utils._ss58", ["scalecodec/utils/_ss58.c"]),
        Extension("scalecodec.base", ["scalecodec/base.c"]),
        Extension("scalecodec.types", ["scalecodec/types.c"]),
    ]

setup(ext_modules=ext_modules)
