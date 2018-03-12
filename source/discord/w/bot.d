module discord.w.bot;

import discord.w.api;
import discord.w.gateway;
import discord.w.types;

struct DiscordBot
{
	string token;
	DiscordGateway gateway;

	ChannelAPI[Snowflake] channelAPIs;

	ChannelAPI channel(Snowflake id) @safe
	{
		auto api = id in channelAPIs;
		if (api)
			return *api;
		return channelAPIs[id] = ChannelAPI(id, authBot(token));
	}

	GuildAPI[Snowflake] guildAPIs;

	GuildAPI guild(Snowflake id) @safe
	{
		auto api = id in guildAPIs;
		if (api)
			return *api;
		return guildAPIs[id] = GuildAPI(id, authBot(token));
}
}

DiscordBot makeBot(string token, DiscordGateway gateway)
{
	DiscordBot ret;
	ret.token = token;
	ret.gateway = gateway;
	ret.gateway.connect();
	return ret;
}

DiscordBot makeBot(Gateway : DiscordGateway = DiscordGateway)(string token)
{
	return makeBot(token, new Gateway(token));
}
