module discord.w.ratelimiter;

import core.time;

mixin template RateLimitObject(Duration repeat)
{
	import std.datetime.systime;
	import core.sync.mutex;
	import vibe.core.core;
	import core.time;

	__gshared Mutex lock;
	__gshared long access;

	void waitFor() @trusted
	{
		if (!lock)
			lock = new Mutex();
		while (true)
		{
			long t;
			synchronized (lock)
			{
				auto now = Clock.currStdTime;
				t = now - access;
				if (t > repeat.total!"hnsecs")
				{
					access = now;
					return;
				}
			}
			auto wait = repeat - (t + 1000).hnsecs;
			if (wait.total!"hnsecs" > 0)
				sleep(wait);
		}
	}
}

mixin template DynamicRateLimitObject(size_t limit, Duration range, Duration repeat)
{
	import std.datetime.systime;
	import core.sync.mutex;
	import vibe.core.core;
	import core.time;

	__gshared Mutex lock;

	static assert(limit > 0, "Requires a limit of at least 1");

	__gshared size_t index;
	__gshared long[limit] accesses;

	void waitFor() @trusted
	{
		if (!lock)
			lock = new Mutex();
		while (true)
		{
			Duration wait;
			synchronized (lock)
			{
				auto now = Clock.currStdTime;
				auto prevAccess = accesses[(index + limit - 1) % $];
				auto access = accesses[index];
				bool hasLeft = now - access >= range.total!"hnsecs";
				if (hasLeft)
				{
					auto t = now - prevAccess;
					if (t > repeat.total!"hnsecs")
					{
						accesses[index] = now;
						index = (index + 1) % accesses.length;
						return;
					}
					wait = repeat - (t + 1000).hnsecs;
				}
				else
					wait = range - (now - access + 1000).hnsecs;
			}
			if (wait.total!"hnsecs" > 0)
				sleep(wait);
		}
	}
}

unittest
{
	import std.datetime.stopwatch;
	import vibe.core.core;

	auto a = runTask({
		mixin DynamicRateLimitObject!(4, 60.msecs, 10.msecs) testLimit;
		StopWatch sw;
		sw.start();
		testLimit.waitFor();
		assert(sw.peek >= 0.msecs && sw.peek < 10.msecs);
		testLimit.waitFor();
		assert(sw.peek >= 10.msecs && sw.peek < 20.msecs);
		testLimit.waitFor();
		assert(sw.peek >= 20.msecs && sw.peek < 30.msecs);
		testLimit.waitFor();
		assert(sw.peek >= 30.msecs && sw.peek < 40.msecs);
		testLimit.waitFor();
		assert(sw.peek >= 60.msecs && sw.peek < 70.msecs);
		sw.stop();
	});

	auto b = runTask({
		mixin RateLimitObject!(10.msecs) testLimit;
		StopWatch sw;
		sw.start();
		testLimit.waitFor();
		assert(sw.peek >= 0.msecs && sw.peek < 10.msecs);
		testLimit.waitFor();
		assert(sw.peek >= 10.msecs && sw.peek < 20.msecs);
		testLimit.waitFor();
		assert(sw.peek >= 20.msecs && sw.peek < 30.msecs);
		testLimit.waitFor();
		assert(sw.peek >= 30.msecs && sw.peek < 40.msecs);
		sw.stop();
	});

	a.join();
	b.join();
}
