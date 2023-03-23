local record http_errors
	enum known_conditions
		"cancelled"
		"connection-closed"
		"certificate-chain-invalid"
		"certificate-verify-failed"
		"connection failed"
		"invalid-url"
		"unable to resolve service"
	end
	type registry_keys = known_conditions | integer
	record error
		type : string
		condition : string
		code : integer
		text : string
	end
	registry : { registry_keys : error }
	new : function (integer, known_conditions, table)
	new : function (integer, string, table)
end
return http_errors
