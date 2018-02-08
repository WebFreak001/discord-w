module discord.w.cache;

import std.algorithm;
import std.typecons;
import std.traits;

package alias Identity(alias A) = A;

// TODO: implement redis or write to disk

class SimpleCache(T, string idMember = "id", size_t limit = size_t.max)
{
@safe:
	alias IDType = typeof(__traits(getMember, T.init, idMember));

	private bool locked;
	T[] entries;
	size_t index;

	private void putUnsafe(T data)
	{
		index = entries.length;
		static if (limit != size_t.max)
		{
			if (index >= limit)
				index = (index % limit);
			else
				entries.length++;
		}
		else
			entries.length++;
		entries[index] = data;
	}

	void put(T data)
	{
		if (locked)
			assert(false, "Attempted to update cache while locked (deadlock)");
		synchronized (this)
		{
			auto id = __traits(getMember, data, idMember);
			if (entries.canFind!((a) => __traits(getMember, a, idMember) == id))
				throw new Exception("Entry with this ID already in cache");
			putUnsafe(data);
		}
	}

	bool has(IDType id)
	{
		if (locked)
			assert(false, "Attempted to update cache while locked (deadlock)");
		synchronized (this)
		{
			return entries.canFind!(a => __traits(getMember, a, idMember) == id);
		}
	}

	/// Returns: the IDs which could not been found
	IDType[] removeAll(IDType[] ids)
	{
		if (locked)
			assert(false, "Attempted to update cache while locked (deadlock)");
		synchronized (this)
		{
			foreach_reverse (i, element; entries)
			{
				auto rm = ids.countUntil(__traits(getMember, element, idMember));
				if (rm != -1)
				{
					ids = ids.remove!(SwapStrategy.unstable)(rm);
					entries = entries.remove(i);
				}
			}
			return ids;
		}
	}

	bool remove(IDType id)
	{
		if (locked)
			assert(false, "Attempted to update cache while locked (deadlock)");
		synchronized (this)
		{
			auto index = entries.countUntil!(a => __traits(getMember, a, idMember) == id);
			if (index == -1)
				return false;
			entries = entries.remove(index);
			return true;
		}
	}

	T update(IDType id, scope void delegate(scope ref T) @safe updater = null, bool put = false)
	{
		if (locked)
			assert(false, "Attempted to update cache while locked (deadlock)");
		synchronized (this)
		{
			auto index = entries.countUntil!(a => __traits(getMember, a, idMember) == id);
			if (index == -1)
			{
				if (put)
				{
					T data;
					__traits(getMember, data, idMember) = id;
					updater(data);
					putUnsafe(data);
					return data;
				}
				else
					throw new Exception("Tried to update non existant cache entry");
			}
			if (updater)
			{
				locked = true;
				updater(entries[index]);
				locked = false;
			}
			return entries[index];
		}
	}

	T patch(T value, bool put = false)
	{
		return update(__traits(getMember, value, idMember), (scope ref v) {
			foreach (name; FieldNameTuple!T)
			{
				static if (is(typeof(__traits(getMember, value, name)) : Nullable!U, U))
				{
					if (!__traits(getMember, value, name).isNull)
						__traits(getMember, v, name) = __traits(getMember, value, name);
				}
				else static if (isArray!(typeof(__traits(getMember, value, name))))
				{
					if (__traits(getMember, value, name).length)
						__traits(getMember, v, name) = __traits(getMember, value, name);
				}
				else static if (__traits(compiles, __traits(getMember, value, name) == null))
				{
					if (__traits(getMember, value, name) != null)
						__traits(getMember, v, name) = __traits(getMember, value, name);
				}
				else
					__traits(getMember, v, name) = __traits(getMember, value, name);
			}
		}, put);
	}
}
