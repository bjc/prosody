local type renderer = function (string, { string : any }) : string
local type filter = function (string, any) : string
local record lib
	new : function (string, string, funcs : { string : filter }) : renderer
end
return lib
