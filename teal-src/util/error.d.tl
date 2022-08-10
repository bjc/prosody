local enum error_type
	"auth"
	"cancel"
	"continue"
	"modify"
	"wait"
end

local enum error_condition
	"bad-request"
	"conflict"
	"feature-not-implemented"
	"forbidden"
	"gone"
	"internal-server-error"
	"item-not-found"
	"jid-malformed"
	"not-acceptable"
	"not-allowed"
	"not-authorized"
	"policy-violation"
	"recipient-unavailable"
	"redirect"
	"registration-required"
	"remote-server-not-found"
	"remote-server-timeout"
	"resource-constraint"
	"service-unavailable"
	"subscription-required"
	"undefined-condition"
	"unexpected-request"
end

local record protoerror
	type : error_type
	condition : error_condition
	text : string
	code : integer
end

local record Error
	type : error_type
	condition : error_condition
	text : string
	code : integer
	context : { any : any }
	source : string
end

local type compact_registry_item = { string, string, string, string }
local type compact_registry = { compact_registry_item }
local type registry = { string : protoerror }
local type context = { string : any }

local record error_registry_wrapper
	source : string
	registry : registry
	new : function (string, context) : Error
	coerce : function (any, string) : any, Error
	wrap : function (Error) : Error
	wrap : function (string, context) : Error
	is_error : function (any) : boolean
end

local record lib
	record configure_opt
		auto_inject_traceback : boolean
	end
	new : function (protoerror, context, { string : protoerror }, string) : Error
	init : function (string, string, registry | compact_registry) : error_registry_wrapper
	init : function (string, registry | compact_registry) : error_registry_wrapper
	is_error : function (any) : boolean
	coerce : function (any, string) : any, Error
	from_stanza : function (table, context, string) : Error
	configure : function
end

return lib
