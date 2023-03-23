local lib = record
	enum logbase
		"b" -- 1024
	end
	adjust : function (number, string) : number, string
	format : function (number, string, logbase) : string
end
return lib
