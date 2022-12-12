
local response_codes = {
	-- Source: http://www.iana.org/assignments/http-status-codes

	[100] = "Continue"; -- RFC9110, Section 15.2.1
	[101] = "Switching Protocols"; -- RFC9110, Section 15.2.2
	[102] = "Processing";
	[103] = "Early Hints";
	-- [104-199] = "Unassigned";

	[200] = "OK"; -- RFC9110, Section 15.3.1
	[201] = "Created"; -- RFC9110, Section 15.3.2
	[202] = "Accepted"; -- RFC9110, Section 15.3.3
	[203] = "Non-Authoritative Information"; -- RFC9110, Section 15.3.4
	[204] = "No Content"; -- RFC9110, Section 15.3.5
	[205] = "Reset Content"; -- RFC9110, Section 15.3.6
	[206] = "Partial Content"; -- RFC9110, Section 15.3.7
	[207] = "Multi-Status";
	[208] = "Already Reported";
	-- [209-225] = "Unassigned";
	[226] = "IM Used";
	-- [227-299] = "Unassigned";

	[300] = "Multiple Choices"; -- RFC9110, Section 15.4.1
	[301] = "Moved Permanently"; -- RFC9110, Section 15.4.2
	[302] = "Found"; -- RFC9110, Section 15.4.3
	[303] = "See Other"; -- RFC9110, Section 15.4.4
	[304] = "Not Modified"; -- RFC9110, Section 15.4.5
	[305] = "Use Proxy"; -- RFC9110, Section 15.4.6
	-- [306] = "(Unused)"; -- RFC9110, Section 15.4.7
	[307] = "Temporary Redirect"; -- RFC9110, Section 15.4.8
	[308] = "Permanent Redirect"; -- RFC9110, Section 15.4.9
	-- [309-399] = "Unassigned";

	[400] = "Bad Request"; -- RFC9110, Section 15.5.1
	[401] = "Unauthorized"; -- RFC9110, Section 15.5.2
	[402] = "Payment Required"; -- RFC9110, Section 15.5.3
	[403] = "Forbidden"; -- RFC9110, Section 15.5.4
	[404] = "Not Found"; -- RFC9110, Section 15.5.5
	[405] = "Method Not Allowed"; -- RFC9110, Section 15.5.6
	[406] = "Not Acceptable"; -- RFC9110, Section 15.5.7
	[407] = "Proxy Authentication Required"; -- RFC9110, Section 15.5.8
	[408] = "Request Timeout"; -- RFC9110, Section 15.5.9
	[409] = "Conflict"; -- RFC9110, Section 15.5.10
	[410] = "Gone"; -- RFC9110, Section 15.5.11
	[411] = "Length Required"; -- RFC9110, Section 15.5.12
	[412] = "Precondition Failed"; -- RFC9110, Section 15.5.13
	[413] = "Content Too Large"; -- RFC9110, Section 15.5.14
	[414] = "URI Too Long"; -- RFC9110, Section 15.5.15
	[415] = "Unsupported Media Type"; -- RFC9110, Section 15.5.16
	[416] = "Range Not Satisfiable"; -- RFC9110, Section 15.5.17
	[417] = "Expectation Failed"; -- RFC9110, Section 15.5.18
	[418] = "I'm a teapot"; -- RFC2324, Section 2.3.2
	-- [419-420] = "Unassigned";
	[421] = "Misdirected Request"; -- RFC9110, Section 15.5.20
	[422] = "Unprocessable Content"; -- RFC9110, Section 15.5.21
	[423] = "Locked";
	[424] = "Failed Dependency";
	[425] = "Too Early";
	[426] = "Upgrade Required"; -- RFC9110, Section 15.5.22
	-- [427] = "Unassigned";
	[428] = "Precondition Required";
	[429] = "Too Many Requests";
	-- [430] = "Unassigned";
	[431] = "Request Header Fields Too Large";
	-- [432-450] = "Unassigned";
	[451] = "Unavailable For Legal Reasons";
	-- [452-499] = "Unassigned";

	[500] = "Internal Server Error"; -- RFC9110, Section 15.6.1
	[501] = "Not Implemented"; -- RFC9110, Section 15.6.2
	[502] = "Bad Gateway"; -- RFC9110, Section 15.6.3
	[503] = "Service Unavailable"; -- RFC9110, Section 15.6.4
	[504] = "Gateway Timeout"; -- RFC9110, Section 15.6.5
	[505] = "HTTP Version Not Supported"; -- RFC9110, Section 15.6.6
	[506] = "Variant Also Negotiates";
	[507] = "Insufficient Storage";
	[508] = "Loop Detected";
	-- [509] = "Unassigned";
	[510] = "Not Extended"; -- (OBSOLETED)
	[511] = "Network Authentication Required";
	-- [512-599] = "Unassigned";
};

for k,v in pairs(response_codes) do response_codes[k] = ("%03d %s"):format(k, v); end
return setmetatable(response_codes, { __index = function(_, k) return k.." Unassigned"; end })
