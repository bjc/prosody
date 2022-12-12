local record lib
	ready : function () : boolean
	waiter : function (num : integer, allow_many : boolean) : function (), function ()
	guarder : function () : function (id : function ()) : function () | nil
	record runner_t<T>
		func : function (T)
		thread : thread
		enum state_e
			-- from Lua manual
			"running"
			"suspended"
			"normal"
			"dead"

			-- from util.async
			"ready"
			"error"
		end
		state : state_e
		notified_state : state_e
		queue : { T }
		type watcher_t = function (runner_t<T>, ... : any)
		type watchers_t = { state_e : watcher_t }
		data : any
		id : string

		run : function (runner_t<T>, T) : boolean, state_e, integer
		enqueue : function (runner_t<T>, T) : runner_t<T>
		log : function (runner_t<T>, string, string, ... : any)
		onready : function (runner_t<T>, function) : runner_t<T>
		onready : function (runner_t<T>, function) : runner_t<T>
		onwaiting : function (runner_t<T>, function) : runner_t<T>
		onerror : function (runner_t<T>, function) : runner_t<T>
	end
	runner : function <T>(function (T), runner_t.watchers_t, any) : runner_t<T>
	wait_for : function (any) : any, any
	sleep : function (t:number)

	-- set_nexttick = function(new_next_tick) next_tick = new_next_tick; end;
	-- set_schedule_function = function (new_schedule_function) schedule_task = new_schedule_function; end;
end
return lib
