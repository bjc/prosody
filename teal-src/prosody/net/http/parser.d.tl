local record httpstream
	feed : function(httpstream, string)
end

local type sink_cb = function ()

local record httppacket
	enum http_method
		"HEAD"
		"GET"
		"POST"
		"PUT"
		"DELETE"
		"OPTIONS"
		-- etc
	end
	method : http_method
	record url_details
		path : string
		query : string
	end
	url : url_details
	path : string
	enum http_version
		"1.0"
		"1.1"
	end
	httpversion : http_version
	headers : { string : string }
	body : string | boolean
	body_sink : sink_cb
	chunked : boolean
	partial : boolean
end

local enum error_conditions
	"cancelled"
	"connection-closed"
	"certificate-chain-invalid"
	"certificate-verify-failed"
	"connection failed"
	"invalid-url"
	"unable to resolve service"
end

local type success_cb = function (httppacket)
local type error_cb = function (error_conditions)

local enum stream_mode
	"client"
	"server"
end

local record lib
	new : function (success_cb, error_cb, stream_mode) : httpstream
end

return lib
