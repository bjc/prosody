-- Only the operators needed by net.websocket.frames are provided at this point
return {
	band   = function (a, b, ...)
		local ret = a & b;
		if ... then
			for i = 1, select("#", ...) do
				ret = ret & (select(i, ...));
			end
		end
		return ret;
	end;
	bor    = function (a, b, ...)
		local ret = a | b;
		if ... then
			for i = 1, select("#", ...) do
				ret = ret | (select(i, ...));
			end
		end
		return ret;
	end;
	bxor   = function (a, b, ...)
		local ret = a ~ b;
		if ... then
			for i = 1, select("#", ...) do
				ret = ret ~ (select(i, ...));
			end
		end
		return ret;
	end;
	bnot   = function (x)
		return ~x;
	end;
	rshift = function (a, n) return a >> n end;
	lshift = function (a, n) return a << n end;
};

