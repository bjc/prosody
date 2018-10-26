local xpcall = xpcall;

if select(2, xpcall(function (x) return x end, function () end,  "test")) ~= "test" then
	xpcall = require"util.compat".xpcall;
end

return {
	xpcall = xpcall;
};
