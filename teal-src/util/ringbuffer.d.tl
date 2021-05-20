local record lib
	record ringbuffer
		find : function (ringbuffer, string) : integer
		discard : function (ringbuffer, integer) : boolean
		read : function (ringbuffer, integer, boolean) : string
		readuntil : function (ringbuffer, string) : string
		write : function (ringbuffer, string) : integer
		size : function (ringbuffer) : integer
		length : function (ringbuffer) : integer
		sub : function (ringbuffer, integer, integer) : string
		byte : function (ringbuffer, integer, integer) : integer...
		free : function (ringbuffer) : integer
	end

	new : function (integer) : ringbuffer
end

return lib


