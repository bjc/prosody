
local response_codes = {
	-- Source: http://www.iana.org/assignments/http-status-codes
	-- s/^\(\d*\)\s*\(.*\S\)\s*\[RFC.*\]\s*$/^I["\1"] = "\2";
	[100] = "Continue";
	[101] = "Switching Protocols";
	[102] = "Processing";

	[200] = "OK";
	[201] = "Created";
	[202] = "Accepted";
	[203] = "Non-Authoritative Information";
	[204] = "No Content";
	[205] = "Reset Content";
	[206] = "Partial Content";
	[207] = "Multi-Status";
	[208] = "Already Reported";
	[226] = "IM Used";

	[300] = "Multiple Choices";
	[301] = "Moved Permanently";
	[302] = "Found";
	[303] = "See Other";
	[304] = "Not Modified";
	[305] = "Use Proxy";
	-- The 306 status code was used in a previous version of [RFC2616], is no longer used, and the code is reserved.
	[307] = "Temporary Redirect";
	[308] = "Permanent Redirect";

	[400] = "Bad Request";
	[401] = "Unauthorized";
	[402] = "Payment Required";
	[403] = "Forbidden";
	[404] = "Not Found";
	[405] = "Method Not Allowed";
	[406] = "Not Acceptable";
	[407] = "Proxy Authentication Required";
	[408] = "Request Timeout";
	[409] = "Conflict";
	[410] = "Gone";
	[411] = "Length Required";
	[412] = "Precondition Failed";
	[413] = "Payload Too Large";
	[414] = "URI Too Long";
	[415] = "Unsupported Media Type";
	[416] = "Range Not Satisfiable";
	[417] = "Expectation Failed";
	[418] = "I'm a teapot";
	[421] = "Misdirected Request";
	[422] = "Unprocessable Entity";
	[423] = "Locked";
	[424] = "Failed Dependency";
	-- The 425 status code is reserved for the WebDAV advanced collections expired proposal [RFC2817]
	[426] = "Upgrade Required";
	[428] = "Precondition Required";
	[429] = "Too Many Requests";
	[431] = "Request Header Fields Too Large";

	[500] = "Internal Server Error";
	[501] = "Not Implemented";
	[502] = "Bad Gateway";
	[503] = "Service Unavailable";
	[504] = "Gateway Timeout";
	[505] = "HTTP Version Not Supported";
	[506] = "Variant Also Negotiates"; -- Experimental
	[507] = "Insufficient Storage";
	[508] = "Loop Detected";
	[510] = "Not Extended";
	[511] = "Network Authentication Required";
};

for k,v in pairs(response_codes) do response_codes[k] = k.." "..v; end
return setmetatable(response_codes, { __index = function(t, k) return k.." Unassigned"; end })
