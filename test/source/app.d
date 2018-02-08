module app;

import std.stdio;
import std.string;
import std.typecons;

import discord.w;

// inheriting from DiscordGateway to override gateway events
class MyGateway : DiscordGateway
{
	this(string token)
	{
		super(token);
	}

	override void onMessageCreate(Message m) @safe
	{
		// the super call updates caches and should always be done
		super.onMessageCreate(m);

		// as this is a bot we don't want to process our own information
		// we get our own information from this.info which is sent by the Gateway
		if (m.author.id == this.info.user.id)
			return;

		if (m.content.startsWith("!status "))
		{
			string status = m.content["!status ".length .. $].strip;
			// nullables are used throughout the entire library to make arguments optional to embed.
			// a custom Json (de)serializer is used in all structs to omit optional fields that equal to their init value.
			Nullable!Activity game = Activity.init;
			game.name = status;
			updateStatus(UpdateStatus.StatusType.online, status.length ? game : Nullable!Activity.init);
		}
		else if (m.content.startsWith("!ping"))
		{
			// bot.channel binds the HTTP channel API to this channel with the bot token and caches it
			bot.channel(m.channel_id).sendMessage("pong!");
		}
	}
}

DiscordBot bot;

// call with ./test [token]
void main(string[] args)
{
	if (args.length <= 1)
	{
		writeln("Usage: ", args[0], " [token]");
		return;
	}

	// make bot creates a gateway instance with the token as parameter.
	// you can also pass a custom gateway instance
	bot = makeBot!MyGateway(args[1]);

	// TOOD: the bot can auto reconnect on failure, so here should be a different while(true) loop.
	while (bot.gateway.connected)
	{
		sleep(10.msecs);
	}
}
