module discord.w.json;

mixin template OptionalSerializer(T)
{
	import std.traits;

	import vibe.data.json;
	import vibe.data.serialization;

	Json toJson() const @safe
	{
		Json ret = Json.emptyObject;
		static foreach (field; FieldNameTuple!T)
				{
				static if (hasUDA!(__traits(getMember, this, field), OptionalAttribute!DefaultPolicy))
					{
					if (__traits(getMember, this, field) != typeof(__traits(getMember, this, field)).init)
						{
						ret[field] = serializeToJson(__traits(getMember, this, field));
					}
				}
				else
					ret[field] = serializeToJson(__traits(getMember, this, field));
			}
		return ret;
	}

	static T fromJson(Json src) @safe
	{
		T ret;
		Members: foreach (key, member; src.get!(Json[string]))
		{
			static foreach (field; FieldNameTuple!T)
					{
					if (field == key)
						{
						if (member.type != Json.Type.null_)
							__traits(getMember, ret, field) = deserializeJson!(typeof(__traits(getMember,
									ret, field)))(member);
						continue Members;
					}
				}
		}
		return ret;
	}
}
