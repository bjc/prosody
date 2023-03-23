local record lib
	record queue<T>
		size : integer
		count : function (queue<T>) : integer
		enum push_errors
			"queue full"
		end

		push : function (queue<T>, T) : boolean, push_errors
		pop : function (queue<T>) : T
		peek : function (queue<T>) : T
		replace : function (queue<T>, T) : boolean, push_errors
		type iterator = function (T, integer) : integer, T
		items : function (queue<T>) : iterator, T, integer
		type consume_iter = function (queue<T>) : T
		consume : function (queue<T>) : consume_iter
	end

	new : function<T> (size:integer, allow_wrapping:boolean) : queue<T>
end
return lib;
