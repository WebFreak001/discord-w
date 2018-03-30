module app;

import std.algorithm;
import std.array;
import std.conv;
import std.stdio;
import std.string;
import std.typecons;

import vibe.core.file;
import vibe.core.path;
import vibe.data.json;

import discord.w;

enum ConfirmEmoji = Emoji.builtin("✅");
enum CancelEmoji = Emoji.builtin("❌");
enum ErrorEmoji = Emoji.builtin("❌");

struct OldNick
{
	Snowflake u;
	string n;
}

// inheriting from DiscordGateway to override gateway events
class MyGateway : DiscordGateway
{
	this(string token)
	{
		super(token);
	}

	struct ConfirmCallback
	{
		void delegate() @safe fn;
		Snowflake admin;
	}

	ConfirmCallback[Snowflake] confirmCallbacks;

	void confirm(Snowflake channel, Snowflake admin, string text, void delegate() @safe callback) @safe
	{
		auto msg = bot.channel(channel).sendMessage(text);
		runTask({
			bot.channel(channel).react(msg.id, ConfirmEmoji);
			bot.channel(channel).react(msg.id, CancelEmoji);
		});
		confirmCallbacks[msg.id] = ConfirmCallback(callback, admin);
	}

	void sendTemporary(Snowflake channel, string text) @safe
	{
		auto m = bot.channel(channel).sendMessage(text);
		runTask({ sleep(10.seconds); bot.channel(channel).deleteMessage(m.id); });
	}

	override void onMessageReactionAdd(MessageReactionAddPacket p)
	{
		super.onMessageReactionAdd(p);

		auto cb = p.message_id in confirmCallbacks;
		if (cb && cb.admin == p.user_id)
		{
			bot.channel(p.channel_id).deleteMessage(p.message_id);
			if (p.emoji.name == ConfirmEmoji.name)
				cb.fn();
		}
	}

	override void onMessageCreate(Message m) @safe
	{
		// the super call updates caches and should always be done
		super.onMessageCreate(m);
		// as this is a bot we don't want to process our own information
		// we get our own information from this.info which is sent by the Gateway
		if (m.author.id == this.info.user.id)
			return;

		// fetches from global cache which is updated by every gateway
		auto guild = getGuildByChannel(m.channel_id);
		// fetches from global cache which is updated by every gateway
		auto perms = getUserPermissions(guild, m.channel_id, m.author.id);

		// binary and the Permissions enum + check for administrator
		if (perms.hasPermission(Permissions.MANAGE_MESSAGES))
		{
			bool match = false;
			string args;
			// any emote called :deletthis:
			if (m.content.startsWith("<:deletthis:"))
			{
				auto end = m.content.indexOf('>');
				if (end != -1)
					match = true;
				args = m.content[end + 1 .. $].strip;
			}
			else if (m.content.startsWith(":deletthis:")) // or just the text if they don't have the emote
			{
				match = true;
				args = m.content[":deletthis:".length .. $].strip;
			}
			if (match)
			{
				int num = 0;
				if (args.length)
					num = args.to!int;
				if (num > 100)
				{
					bot.channel(m.channel_id).react(m.id, ErrorEmoji);
					sendTemporary(m.channel_id, "that's too much! <:ResidentSleeper:356899140896030721>");
					return;
				}
				if (num < 0)
				{
					bot.channel(m.channel_id).react(m.id, ErrorEmoji);
					sendTemporary(m.channel_id, "that's not enough! <:tangery:403173063429980161>");
					return;
				}
				Nullable!Snowflake before = m.id;
				bot.channel(m.channel_id).deleteMessage(m.id);
				if (num > 0)
				{
					auto messages = bot.channel(m.channel_id).getMessages(num,
							Nullable!Snowflake.init, before);
					auto messageIDs = messages.map!(a => a.id).array;
					confirm(m.channel_id, m.author.id,
							"Should I really delete " ~ num.to!string ~ " message" ~ (num == 1
								? "" : "s") ~ "? 🤔", () @safe{
								bot.channel(m.channel_id).deleteMessages(messageIDs);
							});
				}
				return;
			}
		}

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
		else if (m.content.startsWith("!bobbify") && perms.hasPermission(Permissions.MANAGE_NICKNAMES))
		{
			string newNick = m.content["!bobbify".length .. $].strip;
			if (!newNick.length)
				newNick = "Bob";
			GuildAPI gapi = bot.guild(guild);
			int success;
			int fails;
			GuildAPI.ChangeGuildMemberArgs args;
			args.nick = newNick;

			if (existsFile("old_" ~ guild.toString ~ ".txt"))
			{
				bot.channel(m.channel_id).sendMessage("❌ channel already bobbified.");
				return;
			}

			OldNick[] oldNicks;
			foreach (ref entry; gGuildUserCache.entries)
			{
				if (entry.guildUserID[0] == guild)
				{
					try
					{
						OldNick old;
						old.u = entry.guildUserID[1];
						old.n = entry.nick;
						gapi.modifyMember(entry.guildUserID[1], args);
						success++;
						oldNicks ~= old;
					}
					catch (Exception)
					{
						fails++;
					}
				}
			}
			bot.channel(m.channel_id).sendMessage("✅ " ~ success.to!string ~ "❌ " ~ fails.to!string);
			writeFileUTF8(NativePath("old_" ~ guild.toString ~ ".txt"), serializeToJsonString(oldNicks));
		}
		else if (m.content.startsWith("!unbobbify"))
		{
			GuildAPI gapi = bot.guild(guild);
			int success;
			int fails;

			if (!existsFile("old_" ~ guild.toString ~ ".txt"))
			{
				bot.channel(m.channel_id).sendMessage("❌ channel not bobbified.");
				return;
			}

			foreach (old; readFileUTF8("old_" ~ guild.toString ~ ".txt").deserializeJson!(OldNick[]))
			{
				try
				{
					GuildAPI.ChangeGuildMemberArgs args;
					args.nick = old.n;
					gapi.modifyMember(old.u, args);
					success++;
				}
				catch (Exception)
				{
					fails++;
				}
			}
			bot.channel(m.channel_id).sendMessage("✅ " ~ success.to!string ~ "❌ " ~ fails.to!string);
			removeFile("old_" ~ guild.toString ~ ".txt");
		}
		else if (m.mentions.canFind!(user => user.id == this.info.user.id))
		{
			string content;
			if (m.content.startsWith("<@" ~ this.info.user.id.toString ~ ">"))
				content = m.content[("<@" ~ this.info.user.id.toString ~ ">").length .. $].strip;
			else if (m.content.startsWith("<@!" ~ this.info.user.id.toString ~ ">"))
				content = m.content[("<@!" ~ this.info.user.id.toString ~ ">").length .. $].strip;
			else
				return;
			// starting a message by @-ing bot
			if (content.startsWith("say "))
			{
				runTask({ bot.channel(m.channel_id).sendMessage(content[4 .. $]); });
				bot.channel(m.channel_id).deleteMessage(m.id);
			}
			else if (content.startsWith("react"))
			{
				bot.channel(m.channel_id).react(m.id, Emoji.builtin("❌"));
				bot.channel(m.channel_id).react(m.id,
						Emoji.named(Snowflake(346759581546053648UL), "PagChomp"));
			}
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
