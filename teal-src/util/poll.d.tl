local record state
	enum waiterr
		"timeout"
		"signal"
	end
	add : function (state, integer, boolean, boolean) : boolean
	add : function (state, integer, boolean, boolean) : nil, string, integer
	set : function (state, integer, boolean, boolean) : boolean
	set : function (state, integer, boolean, boolean) : nil, string, integer
	del : function (state, integer) : boolean
	del : function (state, integer) : nil, string, integer
	wait : function (state, integer) : integer, boolean, boolean
	wait : function (state, integer) : nil, string, integer
	wait : function (state, integer) : nil, waiterr
	getfd : function (state) : integer
end

local record lib
	new : function () : state
	EEXIST : integer
	EMFILE : integer
	ENOENT : integer
	enum api_backend
		"epoll"
		"poll"
		"select"
	end
	api : api_backend
end

return lib
