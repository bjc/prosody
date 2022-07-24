local record array_t<T>
	{ T }
end

local record lib
	metamethod __call : function () : array_t
end

return lib
