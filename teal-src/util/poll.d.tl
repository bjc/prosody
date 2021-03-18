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
	ENOENT : integer
	EEXIST : integer
end

return lib
