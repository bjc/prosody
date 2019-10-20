local template = [[
{greet!?Hi}, {name?world}!
]];
local expect1 = [[
Hello, WORLD!
]];
local expect2 = [[
Hello, world!
]];
local expect3 = [[
Hi, YOU!
]];

describe("util.interpolation", function ()
	it("renders", function ()
		local render = require "util.interpolation".new("%b{}", string.upper);
		assert.equal(expect1, render(template, { greet = "Hello", name = "world" }));
		assert.equal(expect2, render(template, { greet = "Hello" }));
		assert.equal(expect3, render(template, { name = "you" }));
	end);
end);
