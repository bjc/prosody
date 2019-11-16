
local response_codes = {
	-- Source: http://www.iana.org/assignments/http-status-codes

	[100] = "Continue"; -- RFC7231, Section 6.2.1
	[101] = "Switching Protocols"; -- RFC7231, Section 6.2.2
	[102] = "Processing";
	[103] = "Early Hints";
	-- [104-199] = "Unassigned";

	[200] = "OK"; -- RFC7231, Section 6.3.1
	[201] = "Created"; -- RFC7231, Section 6.3.2
	[202] = "Accepted"; -- RFC7231, Section 6.3.3
	[203] = "Non-Authoritative Information"; -- RFC7231, Section 6.3.4
	[204] = "No Content"; -- RFC7231, Section 6.3.5
	[205] = "Reset Content"; -- RFC7231, Section 6.3.6
	[206] = "Partial Content"; -- RFC7233, Section 4.1
	[207] = "Multi-Status";
	[208] = "Already Reported";
	-- [209-225] = "Unassigned";
	[226] = "IM Used";
	-- [227-299] = "Unassigned";

	[300] = "Multiple Choices"; -- RFC7231, Section 6.4.1
	[301] = "Moved Permanently"; -- RFC7231, Section 6.4.2
	[302] = "Found"; -- RFC7231, Section 6.4.3
	[303] = "See Other"; -- RFC7231, Section 6.4.4
	[304] = "Not Modified"; -- RFC7232, Section 4.1
	[305] = "Use Proxy"; -- RFC7231, Section 6.4.5
	-- [306] = "(Unused)"; -- RFC7231, Section 6.4.6
	[307] = "Temporary Redirect"; -- RFC7231, Section 6.4.7
	[308] = "Permanent Redirect";
	-- [309-399] = "Unassigned";

	[400] = "Bad Request"; -- RFC7231, Section 6.5.1
	[401] = "Unauthorized"; -- RFC7235, Section 3.1
	[402] = "Payment Required"; -- RFC7231, Section 6.5.2
	[403] = "Forbidden"; -- RFC7231, Section 6.5.3
	[404] = "Not Found"; -- RFC7231, Section 6.5.4
	[405] = "Method Not Allowed"; -- RFC7231, Section 6.5.5
	[406] = "Not Acceptable"; -- RFC7231, Section 6.5.6
	[407] = "Proxy Authentication Required"; -- RFC7235, Section 3.2
	[408] = "Request Timeout"; -- RFC7231, Section 6.5.7
	[409] = "Conflict"; -- RFC7231, Section 6.5.8
	[410] = "Gone"; -- RFC7231, Section 6.5.9
	[411] = "Length Required"; -- RFC7231, Section 6.5.10
	[412] = "Precondition Failed"; -- RFC7232, Section 4.2
	[413] = "Payload Too Large"; -- RFC7231, Section 6.5.11
	[414] = "URI Too Long"; -- RFC7231, Section 6.5.12
	[415] = "Unsupported Media Type"; -- RFC7231, Section 6.5.13
	[416] = "Range Not Satisfiable"; -- RFC7233, Section 4.4
	[417] = "Expectation Failed"; -- RFC7231, Section 6.5.14
	[418] = "I'm a teapot"; -- RFC2324, Section 2.3.2
	-- [419-420] = "Unassigned";
	[421] = "Misdirected Request"; -- RFC7540, Section 9.1.2
	[422] = "Unprocessable Entity";
	[423] = "Locked";
	[424] = "Failed Dependency";
	[425] = "Too Early";
	[426] = "Upgrade Required"; -- RFC7231, Section 6.5.15
	-- [427] = "Unassigned";
	[428] = "Precondition Required";
	[429] = "Too Many Requests";
	-- [430] = "Unassigned";
	[431] = "Request Header Fields Too Large";
	-- [432-450] = "Unassigned";
	[451] = "Unavailable For Legal Reasons";
	-- [452-499] = "Unassigned";

	[500] = "Internal Server Error"; -- RFC7231, Section 6.6.1
	[501] = "Not Implemented"; -- RFC7231, Section 6.6.2
	[502] = "Bad Gateway"; -- RFC7231, Section 6.6.3
	[503] = "Service Unavailable"; -- RFC7231, Section 6.6.4
	[504] = "Gateway Timeout"; -- RFC7231, Section 6.6.5
	[505] = "HTTP Version Not Supported"; -- RFC7231, Section 6.6.6
	[506] = "Variant Also Negotiates";
	[507] = "Insufficient Storage";
	[508] = "Loop Detected";
	-- [509] = "Unassigned";
	[510] = "Not Extended";
	[511] = "Network Authentication Required";
	-- [512-599] = "Unassigned";
};

for k,v in pairs(response_codes) do response_codes[k] = ("%03d %s"):format(k, v); end
return setmetatable(response_codes, { __index = function(_, k) return k.." Unassigned"; end })
