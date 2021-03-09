local record state
	enum waiterr
		"timeout"
		"signal"
	end
	add : function (state, number, boolean, boolean) : boolean
	add : function (state, number, boolean, boolean) : nil, string, number
	set : function (state, number, boolean, boolean) : boolean
	set : function (state, number, boolean, boolean) : nil, string, number
	del : function (state, number) : boolean
	del : function (state, number) : nil, string, number
	wait : function (state, number) : number, boolean, boolean
	wait : function (state, number) : nil, string, number
	wait : function (state, number) : nil, waiterr
	getfd : function (state) : number
end

local record lib
	new : function () : state
	ENOENT : number
	EEXIST : number
end

return lib
