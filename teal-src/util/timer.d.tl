local record util_timer
	record task end
	type timer_callback = function (number) : number
	add_task : function ( number, timer_callback, any ) : task
	stop : function ( task )
	reschedule : function ( task, number ) : task
end
return util_timer
