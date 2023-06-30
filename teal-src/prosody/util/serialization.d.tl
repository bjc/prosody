local record _M
	enum preset
		"debug"
		"oneline"
		"compact"
		"pretty"
	end
	type fallback = function (any, string) : string
	record config
		preset : preset
		fallback :  fallback
		fatal : boolean
		keywords : { string : boolean }
		indentwith : string
		itemstart : string
		itemsep : string
		itemlast : string
		tstart : string
		tend : string
		kstart : string
		kend : string
		equals : string
		unquoted : boolean | string
		hex : string
		freeze : boolean
		maxdepth : integer
		multirefs : boolean
		table_pairs : function
	end
	type serializer = function (any) : string
	new : function (config|preset) : serializer
	serialize : function (any, config|preset) : string
end
return _M
