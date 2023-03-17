
local gettime = require "prosody.util.time".now
local setmetatable = setmetatable;

local _ENV = nil;
-- luacheck: std none

local throttle = {};
local throttle_mt = { __index = throttle };

function throttle:update()
	local newt = gettime();
	local elapsed = newt - self.t;
	self.t = newt;
	local balance = (self.rate * elapsed) + self.balance;
	if balance > self.max then
		self.balance = self.max;
	else
		self.balance = balance;
	end
	return self.balance;
end

function throttle:peek(cost)
	cost = cost or 1;
	return self.balance >= cost or self:update() >= cost;
end

function throttle:poll(cost, split)
	if self:peek(cost) then
		self.balance = self.balance - cost;
		return true;
	else
		local balance = self.balance;
		if split then
			self.balance = 0;
		end
		return false, balance, (cost-balance);
	end
end

local function create(max, period)
	return setmetatable({ rate = max / period, max = max, t = gettime(), balance = max }, throttle_mt);
end

return {
	create = create;
};
