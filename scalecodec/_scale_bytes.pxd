# cython: language_level=3
cdef class ScaleBytes:
    cdef public bytearray data
    cdef public int offset
    cdef public int length
    cpdef bytearray get_next_bytes(self, int length)
    cpdef bytearray get_remaining_bytes(self)
    cpdef int get_remaining_length(self)
