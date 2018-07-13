module:hook("muc-config-form", function(event)
	table.insert(event.form, {
		type = "fixed";
		value = "Room information";
	});
end, 100);

module:hook("muc-config-form", function(event)
	table.insert(event.form, {
		type = "fixed";
		value = "Access to the room";
	});
end, 90);

module:hook("muc-config-form", function(event)
	table.insert(event.form, {
		type = "fixed";
		value = "Permissions in the room";
	});
end, 80);

module:hook("muc-config-form", function(event)
	table.insert(event.form, {
		type = "fixed";
		value = "Other options";
	});
end, 70);
