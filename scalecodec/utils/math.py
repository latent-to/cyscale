"""Some simple math-related utility functions not present in the standard
library.
"""

from math import ceil, log2


def trailing_zeros(value: int) -> int:
    """Returns the number of trailing zeros in the binary representation of
    the given integer.
    """
    num_zeros = 0
    while value & 1 == 0:
        num_zeros += 1
        value >>= 1
    return num_zeros


def next_power_of_two(value: int) -> int:
    """Returns the smallest power of two that is greater than or equal
    to the given integer.
    """
    if value < 0:
        raise ValueError("Negative integers not supported")
    return 1 if value == 0 else 1 << ceil(log2(value))
