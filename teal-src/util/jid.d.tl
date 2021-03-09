local record lib
	split : function (string) : string, string, string
	bare : function (string) : string
	prepped_split : function (string, boolean) : string, string, string
	join : function (string, string, string) : string
	prep : function (string, boolean) : string
	compare : function (string, string) : boolean
	node : function (string) : string
	host : function (string) : string
	resource : function (string) : string
	escape : function (string) : string
	unescape : function (string) : string
end

return lib
