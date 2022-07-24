local record server
	record LuaSocketTCP
	end
	record LuaSecCTX
	end

	record extra_settings
	end

	record interface
	end
	enum socket_type
		"tcp"
		"tcp6"
		"tcp4"
	end

	record listeners
		onconnect : function (interface)
		ondetach : function (interface)
		onattach : function (interface, string)
		onincoming : function (interface, string, string)
		ondrain : function (interface)
		onreadtimeout : function (interface)
		onstarttls : function (interface)
		onstatus : function (interface, string)
		ondisconnect : function (interface, string)
	end

	get_backend : function () : string

	type port = string | integer
	enum read_mode
		"*a"
		"*l"
	end
	type read_size = read_mode | integer
	addserver : function (string, port, listeners, read_size, LuaSecCTX) : interface
	addclient : function (string, port, listeners, read_size, LuaSecCTX, socket_type, extra_settings) : interface
	record listen_config
		read_size : read_size
		tls_ctx : LuaSecCTX
		tls_direct : boolean
		sni_hosts : { string : LuaSecCTX }
	end
	listen : function (string, port, listeners, listen_config) : interface
	enum quitting
		"quitting"
	end
	loop : function () : quitting
	closeall : function ()
	setquitting : function (boolean | quitting)

	wrapclient : function (LuaSocketTCP, string, port, listeners, read_size, LuaSecCTX, extra_settings) : interface
	wrapserver : function (LuaSocketTCP, string, port, listeners, listen_config) : interface
	watchfd : function (integer | LuaSocketTCP, function (interface), function (interface)) : interface
	link : function ()

	record config
	end
	set_config : function (config)

end

return server
