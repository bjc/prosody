local Promise = require "prosody.util.promise".Promise;

local record sslctx -- from LuaSec
end

local record lib

	enum http_method
		"GET"
		"HEAD"
		"POST"
		"PUT"
		"OPTIONS"
		"DELETE"
		-- etc?
	end

	record http_client_options
		sslctx : sslctx
	end

	record http_options
		id : string
		onlystatus : boolean
		body : string
		method : http_method
		headers : { string : string }
		insecure : boolean
		suppress_errors : boolean
		streaming_handler : function
		suppress_url : boolean
		sslctx : sslctx
	end

	record http_request
		host : string
		port : string
		enum Scheme
			"http"
			"https"
		end
		scheme : Scheme
		url : string
		userinfo : string
		path : string

		method : http_method
		headers : { string : string }

		insecure : boolean
		suppress_errors : boolean
		streaming_handler : function
		http : http_client
		time : integer
		id : string
		callback : http_callback
	end

	record http_response
	end

	type http_callback = function (string, number, http_response, http_request)

	record http_client
		options : http_client_options
		request : function (http_client, string, http_options, http_callback)
	end

	request : function (string, http_options, http_callback) : Promise, string
	default : http_client
	new : function (http_client_options) : http_client
	events : table
	-- COMPAT
	urlencode : function (string) : string
	urldecode : function (string) : string
	formencode : function ({ string : string }) : string
	formdecode : function (string) : { string : string }
	destroy_request : function (http_request)

	enum available_features
		"sni"
	end
	features : { available_features : boolean }
end

return lib
