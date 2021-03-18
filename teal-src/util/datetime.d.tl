-- TODO s/number/integer/ once Teal gets support for that

local record lib
	date     : function (t : integer) : string
	datetime : function (t : integer) : string
	time     : function (t : integer) : string
	legacy   : function (t : integer) : string
	parse    : function (t : string) : integer
end

return lib
