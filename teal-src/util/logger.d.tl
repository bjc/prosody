local record util
	enum loglevel
		"debug"
		"info"
		"warn"
		"error"
	end
	type logger = function ( loglevel, string, ...:any )
	type sink = function ( string, loglevel, string, ...:any )
	type simple_sink = function ( string, loglevel, string )
	init : function ( string ) : logger
	make_logger : function ( string, loglevel ) : function ( string, ...:any )
	reset : function ()
	add_level_sink : function ( loglevel, sink )
	add_simple_sink : function ( simple_sink, { loglevel } )
end

return util
