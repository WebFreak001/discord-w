module app;

import std.stdio;
import std.string;
import std.typecons;

import discord.w;

class MyGateway : DiscordGateway
{
	this(string token)
	{
		super(token);
	}

	override void onMessageCreate(Message m) @safe
	{
		super.onMessageCreate(m);

		if (m.author.id == this.info.user.id)
			return;

		if (m.content.startsWith("!status "))
		{
			string status = m.content["!status ".length .. $].strip;
			Nullable!Activity game = Activity.init;
			game.name = status;
			updateStatus(UpdateStatus.StatusType.online, status.length ? game : Nullable!Activity.init);
		}
		else if (m.content.startsWith("!ping"))
		{
			bot.channel(m.channel_id).sendMessage("pong!");
		}
	}
}

DiscordBot bot;

void main(string[] args)
{
	if (args.length <= 1)
	{
		writeln("Usage: ", args[0], " [token]");
		return;
	}

	bot = makeBot!MyGateway(args[1]);

	while (bot.gateway.connected)
	{
		sleep(10.msecs);
	}
}
