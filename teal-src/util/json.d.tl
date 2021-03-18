local record lib
	encode : function (any) : string
	decode : function (string) : any, string

	enum json_type_name
		"null"
		"boolean"
		"object"
		"array"
		"number"
		"string"
		"integer"
	end

	type null_type = (nil)
	null : null_type
end
return lib
