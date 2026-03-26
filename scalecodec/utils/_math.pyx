# cython: language_level=3, cdivision=True

"""Some simple math-related utility functions not present in the standard
   library.
"""

from libc.stdint cimport int64_t, uint64_t


cpdef int trailing_zeros(int64_t value) nogil:
    """Returns the number of trailing zeros in the binary representation of
    the given integer.
    """
    cdef int num_zeros = 0
    while value & 1 == 0:
        num_zeros += 1
        value >>= 1
    return num_zeros


cpdef int64_t next_power_of_two(int64_t value):
    """Returns the smallest power of two that is greater than or equal
    to the given integer.
    """
    cdef int64_t result
    if value < 0:
        raise ValueError("Negative integers not supported")
    if value <= 1:
        return 1
    result = 1
    while result < value:
        result <<= 1
    return result
