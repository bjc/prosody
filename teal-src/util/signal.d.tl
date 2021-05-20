local record lib
	enum signal
		"SIGABRT"
		"SIGALRM"
		"SIGBUS"
		"SIGCHLD"
		"SIGCLD"
		"SIGCONT"
		"SIGFPE"
		"SIGHUP"
		"SIGILL"
		"SIGINT"
		"SIGIO"
		"SIGIOT"
		"SIGKILL"
		"SIGPIPE"
		"SIGPOLL"
		"SIGPROF"
		"SIGQUIT"
		"SIGSEGV"
		"SIGSTKFLT"
		"SIGSTOP"
		"SIGSYS"
		"SIGTERM"
		"SIGTRAP"
		"SIGTTIN"
		"SIGTTOU"
		"SIGURG"
		"SIGUSR1"
		"SIGUSR2"
		"SIGVTALRM"
		"SIGWINCH"
		"SIGXCPU"
		"SIGXFSZ"
	end
	signal : function (integer | signal, function, boolean) : boolean
	raise : function (integer | signal)
	kill : function (integer, integer | signal)
	-- enum : integer
end
return lib
