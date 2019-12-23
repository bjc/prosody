-- Only the operators needed by net.websocket.frames are provided at this point
return {
	band   = function (a, b) return a & b end;
	bor    = function (a, b) return a | b end;
	bxor   = function (a, b) return a ~ b end;
};

