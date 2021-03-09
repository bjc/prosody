-- TODO s/number/integer/ once Teal gets support for that

local record lib
	date     : function (t : number) : string
	datetime : function (t : number) : string
	time     : function (t : number) : string
	legacy   : function (t : number) : string
	parse    : function (t : string) : number
end

return lib
