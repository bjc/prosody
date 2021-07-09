module:set_global();

local server = require "net.http.server";
local codes = require "net.http.codes";
local xml_escape = require "util.stanza".xml_escape;
local render = require "util.interpolation".new("%b{}", xml_escape);

local show_private = module:get_option_boolean("http_errors_detailed", false);
local always_serve = module:get_option_boolean("http_errors_always_show", true);
local default_message = { module:get_option_string("http_errors_default_message", "That's all I know.") };
local default_messages = {
	[400] = { "What kind of request do you call that??" };
	[403] = { "You're not allowed to do that." };
	[404] = { "Whatever you were looking for is not here. %";
		"Where did you put it?", "It's behind you.", "Keep looking." };
	[500] = { "% Check your error log for more info.";
		"Gremlins.", "It broke.", "Don't look at me." };
	["/"] = {
		"A study in simplicity.";
		"Better catch it!";
		"Don't just stand there, go after it!";
		"Well, say something, before it runs too far!";
		"Welcome to the world of XMPP!";
		"You can do anything in XMPP!"; -- "The only limit is XML.";
		"You can do anything with Prosody!"; -- the only limit is memory?
	};
};

local messages = setmetatable(module:get_option("http_errors_messages", {}), { __index = default_messages });

local html = [[
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>{title}</title>
<style>
body{margin-top:14%;text-align:center;background-color:#f8f8f8;font-family:sans-serif}
h1{font-size:xx-large}
p{font-size:x-large}
p.warning>span{font-size:large;background-color:yellow}
p.extra{font-size:large;font-family:courier}
@media(prefers-color-scheme:dark){
body{background-color:#161616;color:#eee}
p.warning>span{background-color:inherit;color:yellow}
}
</style>
</head>
<body>
<h1>{icon?{icon_raw!?}} {title}</h1>
<p>{message}</p>
{warning&<p class="warning"><span>&#9888; {warning?} &#9888;</span></p>}
{extra&<p class="extra">{extra?}</p>}
</body>
</html>
]];

local function get_page(code, extra)
	local message = messages[code];
	if always_serve or message then
		message = message or default_message;
		return render(html, {
			title = rawget(codes, code) or ("Code "..tostring(code));
			message = message[1]:gsub("%%", function ()
				return message[math.random(2, math.max(#message,2))];
			end);
			extra = extra;
		});
	end
end

-- Main error page handler
module:hook_object_event(server, "http-error", function (event)
	if event.response then
		event.response.headers.content_type = "text/html; charset=utf-8";
	end
	return get_page(event.code, (show_private and event.private_message) or event.message or (event.error and event.error.text));
end);

-- Way to use the template for other things so to give a consistent appearance
module:hook("http-message", function (event)
	if event.response then
		event.response.headers.content_type = "text/html; charset=utf-8";
	end
	return render(html, event);
end);

local icon = [[
<svg xmlns="http://www.w3.org/2000/svg" height="0.7em" viewBox="0 0 480 480" width="0.7em">
<rect fill="#6197df" height="220" rx="60" ry="60" width="220" x="10" y="10"></rect>
<rect fill="#f29b00" height="220" rx="60" ry="60" width="220" x="10" y="240"></rect>
<rect fill="#f29b00" height="220" rx="60" ry="60" width="220" x="240" y="10"></rect>
<rect fill="#6197df" height="220" rx="60" ry="60" width="220" x="240" y="240"></rect>
</svg>
]];

-- Something nicer shown instead of 404 at the root path, if nothing else handles this path
module:hook_object_event(server, "http-error", function (event)
	local request, response = event.request, event.response;
	if request and response and request.path == "/" and response.status_code == 404 then
		response.status_code = 200;
		response.headers.content_type = "text/html; charset=utf-8";
		local message = messages["/"];
		return render(html, {
				icon_raw = icon,
				title = "Prosody is running!";
				message = message[math.random(#message)];
			});
	end
end, 1);

