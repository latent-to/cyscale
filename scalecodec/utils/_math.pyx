# cython: language_level=3, cdivision=True
# Python SCALE Codec Library
#
# Copyright 2018-2020 Stichting Polkascan (Polkascan Foundation).
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

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
