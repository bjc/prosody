-- Import gettime() from LuaSocket, as a way to access high-resolution time
-- in a platform-independent way

local socket_gettime = require "socket".gettime;

return {
	now = socket_gettime;
}
