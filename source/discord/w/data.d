module discord.w.data;

import discord.w.types;
import discord.w.cache;

import std.typecons;

struct GuildUserCache
{
	Snowflake[2] guildUserID;
	Snowflake[] roles;
	Nullable!Activity game;
	SafeTime joinDate;
	PresenceUpdate.Status status;
	bool deaf, mute;
	string nick;
}

struct ChannelUserCache
{
	Snowflake[2] channelUserID;
	SafeTime typing;
}

struct VoiceStateCache
{
	union
	{
		VoiceState state;
		Snowflake[3] id;
	}
}

__gshared auto _gUserCache = new SimpleCache!User();
__gshared auto _gGuildUserCache = new SimpleCache!(GuildUserCache, "guildUserID")();
__gshared auto _gChannelUserCache = new SimpleCache!(ChannelUserCache, "channelUserID")();
__gshared auto _gVoiceStateCache = new SimpleCache!VoiceStateCache();
__gshared auto _gChannelCache = new SimpleCache!Channel();
__gshared auto _gGuildCache = new SimpleCache!Guild();
__gshared auto _gMessageCache = new SimpleCache!(Message, "id", 16 * 1024 * 1024)();

auto gUserCache() @trusted
{
	return _gUserCache;
}

auto gGuildUserCache() @trusted
{
	return _gGuildUserCache;
}

auto gChannelUserCache() @trusted
{
	return _gChannelUserCache;
}

auto gVoiceStateCache() @trusted
{
	return _gVoiceStateCache;
}

auto gChannelCache() @trusted
{
	return _gChannelCache;
}

auto gGuildCache() @trusted
{
	return _gGuildCache;
}

auto gMessageCache() @trusted
{
	return _gMessageCache;
}
