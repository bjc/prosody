local st = require"util.stanza"

global record moduleapi
	get_name : function (moduleapi) : string
	get_host : function (moduleapi) : string
	enum host_type
		"global"
		"local"
		"component"
	end
	get_host_type : function (moduleapi) : host_type
	set_global : function (moduleapi)
	add_feature : function (moduleapi, string)
	add_identity : function (moduleapi, string, string, string) -- TODO enum?
	add_extension : function (moduleapi, st.stanza_t)
	fire_event : function (moduleapi, string, any) : any
	type handler = function (any) : any
	record util_events
		-- TODO import def
	end
	hook_object_event : function (moduleapi, util_events, string, handler, number)
	unhook_object_event : function (moduleapi, util_events, string, handler)
	hook : function (moduleapi, string, handler, number)
	hook_global : function (moduleapi, string, handler, number)
	hook_tag : function (moduleapi, string, string, handler, number)
	unhook : function (moduleapi, string, handler)
	wrap_object_event : function (moduleapi, util_events, string, handler)
	wrap_event : function (moduleapi, string, handler)
	wrap_global : function (moduleapi, string, handler)
	require : function (moduleapi, string) : table
	depends : function (moduleapi, string) : table
	shared : function (moduleapi, string) : table
	type config_getter = function<A> (moduleapi, string, A) : A
	get_option : config_getter<any>
	get_option_scalar : config_getter<nil | boolean | number | string>
	get_option_string : config_getter<string>
	get_option_number : config_getter<number>
	get_option_boolean : config_getter<boolean>
	record util_array
		-- TODO import def
		{ any }
	end
	get_option_array : config_getter<util_array>
	record util_set
		-- TODO import def
		_items : { any : boolean }
	end
	get_option_set : function (moduleapi, string, { any }) : util_set
	get_option_inherited_set : function (moduleapi, string, { any }) : util_set
	get_option_path : function (moduleapi, string, string, string) : string
	context : function (moduleapi, string) : moduleapi
	add_item : function (moduleapi, string, any)
	remove_item : function (moduleapi, string, any)
	get_host_items : function (moduleapi, string) : { any }
	handle_items : function (moduleapi, string, handler, handler, boolean)
	provides : function (moduleapi, string, table)
	record util_session
		-- TODO import def
		send : function ( st.stanza_t | string )
	end
	send : function (moduleapi, st.stanza_t, util_session)
	send_iq : function (moduleapi, st.stanza_t, util_session, number)
	broadcast : function (moduleapi, { string }, st.stanza_t, function)
	type timer_callback = function (number, ... : any) : number
	add_timer : function (moduleapi, number, timer_callback, ... : any)
	get_directory : function (moduleapi) : string
	enum file_mode
		"r" "w" "a" "r+" "w+" "a+"
	end
	load_resource : function (moduleapi, string, file_mode) : FILE
	enum store_type
		"keyval"
		"map"
		"archive"
	end
	open_store : function (moduleapi, string, store_type)
	enum stat_type
		"amount"
		"counter"
		"rate"
		"distribution"
		"sizes"
		"times"
	end
	record stats_conf
		initial : number
		units : string
		type : string
	end
	measure : function (moduleapi, string, stat_type, stats_conf)
	measure_object_event : function (moduleapi, util_events, string, string)
	measure_event : function (moduleapi, string, string)
	measure_global_event : function (moduleapi, string, string)
	enum status_type
		"error"
		"warn"
		"info"
		"core"
	end
	set_status : function (moduleapi, status_type, string, boolean)
	enum log_level
		"debug"
		"info"
		"warn"
		"error"
	end
	log_status : function (moduleapi, log_level, string, ... : any)
	get_status : function (moduleapi) : status_type, string, number

	-- added by modulemanager
	name : string
	host : string
	_log : function (log_level, string, ... : any)
	log : function (moduleapi, log_level, string, ... : any)
	reloading : boolean
	saved_state : any
	record module_environment
		module : moduleapi
	end
	environment : module_environment
	path : string
	resource_path : string

	-- methods the module can add
	load : function ()
	add_host : function (moduleapi)
	save : function () : any
	restore : function (any)
	unload : function ()
end

global module : moduleapi

global record common_event
	stanza : st.stanza_t
	record origin
		send : function (st.stanza_t)
	end
end

global record prosody
	version : string
end

return module
