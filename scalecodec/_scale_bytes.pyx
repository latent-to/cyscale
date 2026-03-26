# cython: language_level=3


cdef class ScaleBytes:
    """
    Representation of SCALE encoded Bytes.
    """

    def __init__(self, data):
        """
        Constructs a SCALE bytes-stream with provided `data`

        Parameters
        ----------
        data
        """
        self.offset = 0

        if type(data) is bytearray:
            self.data = data
        elif type(data) is bytes:
            self.data = bytearray(data)
        elif type(data) is str and data[0:2] == '0x':
            self.data = bytearray.fromhex(data[2:])
        else:
            raise ValueError("Provided data is not in supported format: provided '{}'".format(type(data)))

        self.length = len(self.data)

    cpdef bytearray get_next_bytes(self, int length):
        """
        Retrieve `length` amount of bytes of the stream

        Parameters
        ----------
        length: amount of requested bytes

        Returns
        -------
        bytearray
        """
        cdef int start = self.offset
        cdef unsigned char[:] view = self.data
        self.offset = start + length
        return bytearray(view[start:start + length])

    cpdef bytearray get_remaining_bytes(self):
        """
        Retrieves all remaining bytes from the stream

        Returns
        -------
        bytearray
        """
        cdef unsigned char[:] view = self.data
        cdef int start = self.offset
        self.offset = self.length
        return bytearray(view[start:])

    cpdef int get_remaining_length(self):
        """
        Returns how many bytes are left in the stream

        Returns
        -------
        int
        """
        return self.length - self.offset

    def reset(self):
        """
        Resets the pointer of the stream to the beginning
        """
        self.offset = 0

    def __str__(self):
        return "0x{}".format(self.data.hex())

    def __eq__(self, other):
        if not hasattr(other, 'data'):
            return False
        return self.data == other.data

    def __len__(self):
        return len(self.data)

    def __repr__(self):
        return "<{}(data=0x{})>".format(self.__class__.__name__, self.data.hex())

    def __add__(self, data):
        if isinstance(data, ScaleBytes):
            return ScaleBytes(self.data + data.data)

        if type(data) == bytes:
            data = bytearray(data)
        elif type(data) == str and data[0:2] == '0x':
            data = bytearray.fromhex(data[2:])

        if type(data) == bytearray:
            return ScaleBytes(self.data + data)

    def to_hex(self):
        """
        Return a hex-string (e.g. "0x00") representation of the byte-stream

        Returns
        -------
        str
        """
        return '0x{}'.format(self.data.hex())
