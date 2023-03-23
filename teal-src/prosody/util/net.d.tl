
local enum type_strings
	"both"
	"ipv4"
	"ipv6"
end

local record lib
	local_addresses : function (type_strings, boolean) : { string }
	pton : function (string):string
	ntop : function (string):string
end
return lib
