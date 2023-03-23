
local record lib
	type resolve_func = function (any)
	type promise_body = function (resolve_func, resolve_func)

	record Promise<A, B>
		type on_resolved = function (A) : any
		type on_rejected = function (B) : any
		next : function (Promise, on_resolved, on_rejected) : Promise<any, any>
	end

	new : function (promise_body) : Promise
	resolve : function (any) : Promise
	reject : function (any) : Promise
	all : function ({ Promise }) : Promise
	all_settled : function ({ Promise }) : Promise
	race : function ({ Promise }) : Promise
	try : function
	is_promise : function(any) : boolean
end

return lib
