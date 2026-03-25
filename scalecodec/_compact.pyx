# cython: language_level=3, boundscheck=False, wraparound=False, cdivision=True, nonecheck=False
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

from scalecodec._scale_bytes cimport ScaleBytes
from scalecodec._scale_bytes import ScaleBytes as _ScaleBytes
from scalecodec.base import ScaleType
from scalecodec.constants import TYPE_DECOMP_MAX_RECURSIVE
from scalecodec.exceptions import InvalidScaleTypeValueException


class Compact(ScaleType):
    """
    A space efficient type to encoding fixed-width integers
    """

    def __init__(self, data=None, **kwargs):
        self.compact_length = 0
        self.compact_bytes = None
        super().__init__(data, **kwargs)

    def process_compact_bytes(self):
        cdef bytearray compact_byte = self.get_next_bytes(1)
        cdef int byte_mod
        cdef int compact_length

        if len(compact_byte) == 0:
            raise InvalidScaleTypeValueException("Invalid byte for Compact")
        byte_mod = compact_byte[0] % 4

        if byte_mod == 0:
            compact_length = 1
        elif byte_mod == 1:
            compact_length = 2
        elif byte_mod == 2:
            compact_length = 4
        else:
            compact_length = 5 + (compact_byte[0] - 3) // 4

        self.compact_length = compact_length

        if compact_length == 1:
            self.compact_bytes = compact_byte
        elif compact_length == 2 or compact_length == 4:
            self.compact_bytes = compact_byte + self.get_next_bytes(compact_length - 1)
        else:
            self.compact_bytes = self.get_next_bytes(compact_length - 1)

        return self.compact_bytes

    def process(self):
        cdef int compact_length
        self.process_compact_bytes()
        compact_length = self.compact_length

        if compact_length <= 4:
            return int(int.from_bytes(self.compact_bytes, byteorder='little') / 4)
        else:
            return int.from_bytes(self.compact_bytes, byteorder='little')

    def process_encode(self, value):
        cdef object v = int(value)

        if v <= 0b00111111:
            return _ScaleBytes(bytearray(int(v << 2).to_bytes(1, 'little')))

        elif v <= 0b0011111111111111:
            return _ScaleBytes(bytearray(int((v << 2) | 0b01).to_bytes(2, 'little')))

        elif v <= 0b00111111111111111111111111111111:
            return _ScaleBytes(bytearray(int((v << 2) | 0b10).to_bytes(4, 'little')))

        else:
            for bytes_length in range(4, 68):
                if 2 ** (8 * (bytes_length - 1)) <= v < 2 ** (8 * bytes_length):
                    return _ScaleBytes(bytearray(
                        ((bytes_length - 4) << 2 | 0b11).to_bytes(1, 'little') +
                        v.to_bytes(bytes_length, 'little')))
            else:
                raise ValueError('{} out of range'.format(value))

    @classmethod
    def generate_type_decomposition(cls, _recursion_level=0, max_recursion=TYPE_DECOMP_MAX_RECURSIVE):
        if cls.sub_type is None:
            return cls.__name__

        scale_obj = cls.runtime_config.create_scale_object(cls.sub_type)
        return scale_obj.generate_type_decomposition(
            _recursion_level=_recursion_level + 1, max_recursion=max_recursion
        )


class CompactU32(Compact):
    """
    Specialized composite implementation for performance improvement
    """

    type_string = 'Compact<u32>'

    def process(self):
        cdef int compact_length
        self.process_compact_bytes()
        compact_length = self.compact_length

        if compact_length <= 4:
            return int(int.from_bytes(self.compact_bytes, byteorder='little') / 4)
        else:
            return int.from_bytes(self.compact_bytes, byteorder='little')

    def process_encode(self, value):
        cdef object v = int(value)

        if v <= 0b00111111:
            return _ScaleBytes(bytearray(int(v << 2).to_bytes(1, 'little')))

        elif v <= 0b0011111111111111:
            return _ScaleBytes(bytearray(int((v << 2) | 0b01).to_bytes(2, 'little')))

        elif v <= 0b00111111111111111111111111111111:
            return _ScaleBytes(bytearray(int((v << 2) | 0b10).to_bytes(4, 'little')))

        else:
            for bytes_length in range(4, 68):
                if 2 ** (8 * (bytes_length - 1)) <= v < 2 ** (8 * bytes_length):
                    return _ScaleBytes(bytearray(
                        ((bytes_length - 4) << 2 | 0b11).to_bytes(1, 'little') +
                        v.to_bytes(bytes_length, 'little')))
            else:
                raise ValueError('{} out of range'.format(value))
