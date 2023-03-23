-- TODO many actually return Maybe(String)
local record lib
	record base64
		encode : function (s : string) : string
		decode : function (s : string) : string
	end
	record stringprep
		nameprep : function (s : string, strict : boolean) : string
		nodeprep : function (s : string, strict : boolean) : string
		resourceprep : function (s : string, strict : boolean) : string
		saslprep : function (s : string, strict : boolean) : string
	end
	record idna
		to_ascii : function (s : string) : string
		to_unicode : function (s : string) : string
	end
	record utf8
		valid : function (s : string) : boolean
		length : function (s : string) : integer
	end
	record confusable
		skeleton : function (s : string) : string
	end
	version : string
end
return lib

