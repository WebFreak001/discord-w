module discord.w.gateway;

import core.time;

import std.algorithm;
import std.array;
import std.conv;
import std.datetime.systime;
import std.random;
import std.typecons;

import vibe.core.core;
import vibe.core.log;
import vibe.data.json;
import vibe.http.websockets;
import vibe.inet.url;

import discord.w.api;
import discord.w.data;
import discord.w.json;
import discord.w.minietf;
import discord.w.ratelimiter;
import discord.w.types;

string discordGatewayURL;
bool discordGatewayURLvalid = false;

enum maxPacketSize = 4096;

version (LargeShardedBot)
	enum IdentifyRateLimitCount = 2000;
else
	enum IdentifyRateLimitCount = 1000;

__gshared mixin RateLimitObject!(5100.msecs) connectRateLimit;
__gshared mixin DynamicRateLimitObject!(IdentifyRateLimitCount, 24.hours, 5100.msecs) identifyRateLimit;
__gshared mixin DynamicRateLimitObject!(12, 6.seconds, 100.msecs) sendRateLimit;
__gshared mixin DynamicRateLimitObject!(5, 60.seconds, 1000.msecs) statusRateLimit;

void validateDisconnectOpcode(short code) @safe
{
	switch (code)
	{
	case 4001:
		throw new Exception("Sent an invalid payload or opcode and got disconnected");
	case 4002:
		throw new Exception("Server decode error disconnection");
	case 4003:
		throw new Exception("Sent packet before Identify, disconnected");
	case 4004:
		throw new Exception("Identify packet incorrect, disconnected (did you set identifyPacket?)");
	case 4005:
		throw new Exception("Tried to send Identify more than once, disconnected");
	case 4007:
		logDiagnostic("Resume had an invalid session and got disconnected");
		return; // try reconnecting
	case 4008:
		throw new Exception("Payload rate limit exceeded, disconnected");
	case 4009:
		logDiagnostic("Session timed out and got disconnected");
		return; // try reconnecting
	case 4010:
		throw new Exception("Invalid shard in Identify packet, disconnected");
	case 4011:
		throw new Exception("Too many guilds to handle, requires sharding, disconnected");
	case 4000: // unknown
	default:
		return; // try reconnecting
	}
}

class DiscordGateway
{
@safe:
	enum Encoding : string
	{
		JSON = "json",
		ETF = "etf"
	}

	private
	{
		WebSocket socket;
		Encoding encoding;
		bool disconnected;
		bool shouldDisconnect;
		bool hasLastSequence;
		int lastSequence;
		bool receivedAck;
		bool workerRunning;
		string sessionID;
	}

	struct ConnectionInfo
	{
		int protocolVersion;
		User user;
		Snowflake[] privateChannels;
		Snowflake[] guilds;
	}

	ConnectionInfo info;

	bool connected()
	{
		return socket.connected;
	}

	OpIdentify identifyPacket;

	this(string token)
	{
		import std.system : os, endian;

		identifyPacket.token = token;
		identifyPacket.properties["$os"] = os.to!string;
		identifyPacket.properties["$browser"] = "discord-w/vibe.d";
		version (X86)
			identifyPacket.properties["$device"] = "x86 " ~ endian.to!string;
		else version (X86_64)
			identifyPacket.properties["$device"] = "x86_64 " ~ endian.to!string;
		else version (ARM_HardFloat)
			identifyPacket.properties["$device"] = "armhf " ~ endian.to!string;
		else version (ARM)
			identifyPacket.properties["$device"] = "arm " ~ endian.to!string;
		else version (PPC)
			identifyPacket.properties["$device"] = "powerpc " ~ endian.to!string;
	}

	void send(OpCode opcode, T)(T data)
	{
		static assert(opcode != OpCode.dispatch, "dispatch opCode is not sendable");
		static assert(opcode != OpCode.reconnect, "reconnect opCode is not sendable");
		static assert(opcode != OpCode.invalidSession, "invalidSession opCode is not sendable");
		static assert(opcode != OpCode.hello, "hello opCode is not sendable");
		static assert(opcode != OpCode.heartbeatAck, "heartbeatAck opCode is not sendable");

		struct Packet
		{
			OpCode op = opcode;
			T d;
			static if (opcode == OpCode.dispatch)
			{
				int s;
				string t;
			}
		}

		Packet packet;
		packet.d = data;

		final switch (encoding)
		{
		case Encoding.JSON:
			string s = serializeToJsonString(packet);
			if (s.length > maxPacketSize)
				throw new Exception("Attempted to send too large packet");
			sendRateLimit.waitFor();
			static if (opcode != OpCode.identify && opcode != OpCode.resume)
				logDebugV("Sending packet %s", s);
			socket.send(s);
			break;
		case Encoding.ETF:
			ubyte[] s = ETFBuffer.serialize(packet, maxPacketSize, false).bytes;
			assert(s.length <= maxPacketSize);
			sendRateLimit.waitFor();
			static if (opcode != OpCode.identify && opcode != OpCode.resume)
				logDebugV("Sending packet %s", s);
			socket.send(s);
			break;
		}
	}

	OpFrame receive() @trusted
	{
		OpFrame ret;

		final switch (encoding)
		{
		case Encoding.JSON:
			auto text = socket.receiveText;
			logDebugV("Received %s", text);
			auto j = parseJsonString(text);
			ret.op = cast(OpCode) j["op"].get!int;
			ret.j = j["d"];
			ret.isJson = true;
			if (ret.op == OpCode.dispatch)
			{
				ret.s = j["s"].get!int;
				ret.t = j["t"].get!string;
			}
			break;
		case Encoding.ETF:
			auto binary = socket.receiveBinary;
			logDebugV("Received %s", binary.binToString);
			auto etf = ETFBuffer.deserialzeTree(binary).children[0];
			auto e = etf.get!(ETFNode[string]);
			ret.op = cast(OpCode) e["op"].get!int;
			ret.e = e["d"];
			ret.isJson = false;
			if (ret.op == OpCode.dispatch)
			{
				ret.s = e["s"].get!int;
				ret.t = e["t"].get!string;
			}
			break;
		}
		return ret;
	}

	void connect(Encoding encoding = Encoding.JSON, bool handled = true)
	{
		assert(disconnected || !socket, "Attempted to connect when already connected");
		disconnected = false;
		socket = null;
		shouldDisconnect = false;
		this.encoding = encoding;
		while (!socket)
		{
			connectRateLimit.waitFor();
			if (!discordGatewayURLvalid)
			{
				discordGatewayURL = requestDiscordEndpoint("/gateway")["url"].get!string;
				discordGatewayURLvalid = true;
			}
			URL ws_url;
			try
			{
				ws_url = URL.parse(discordGatewayURL ~ "/?v=6&encoding=" ~ cast(string) encoding);
				socket = connectWebSocket(ws_url);
			}
			catch (Exception e)
			{
				socket = null;
				logDiagnostic("Failed to connect to %s, trying again in 10s...", ws_url);
				() @trusted{ logDebug("Exception: %s", e); }();
				discordGatewayURLvalid = false;
				sleep(10.seconds);
			}
		}
		if (handled)
			runTask({ runWorker(); });
	}

	void disconnect(short code = 1000)
	{
		shouldDisconnect = true;
		if (socket && socket.connected)
			socket.close(code);
		disconnected = true;
	}

	void reconnect(bool resume = false)
	{
		logDiagnostic("Reconnecting websocket");
		runTask({
			disconnect(900);
			while (workerRunning)
				yield();
			connect(encoding, false);
			runWorker(resume);
		});
	}

	void sendHeartbeat()
	{
		if (!receivedAck)
		{
			logDiagnostic("didn't receive an ack between last heartbeat and this heartbeat, reconnecting");
			reconnect();
			return;
		}
		logTrace("Sending heartbeat");
		receivedAck = false;
		if (hasLastSequence)
			send!(OpCode.heartbeat)(lastSequence);
		else
			send!(OpCode.heartbeat)(null);
	}

	void runHeartbeat(Duration interval)
	{
		logDebugV("Running heartbeat with %s interval", interval);
		while (true)
		{
			sleep(interval);
			if (socket.connected)
				sendHeartbeat();
			else
				break;
		}
	}

	void runWorker(bool resume = false)
	{
		scope (exit)
			workerRunning = false;
		assert(socket);
		workerRunning = true;
		auto hello = receive;
		if (hello.op != OpCode.hello)
			throw new Exception("Received unexpected opcode " ~ hello.op.to!string);
		logDebugV("Received hello packet %s", hello);
		receivedAck = true;
		runTask({ runHeartbeat(hello.d!OpHello.heartbeat_interval.msecs); });
		if (sessionID.length)
		{
			send!(OpCode.resume)(ResumeData(identifyPacket.token, sessionID, lastSequence));
		}
		else
		{
			identifyRateLimit.waitFor();
			send!(OpCode.identify)(identifyPacket);
		}
		try
		{
			while (socket.connected)
			{
				auto frame = receive;
				logDebugV("Received frame %s", frame);
				switch (frame.op)
				{
				case OpCode.dispatch:
					runTask(&processEvent, frame);
					break;
				case OpCode.reconnect:
					reconnect();
					break;
				case OpCode.invalidSession:
					sessionID = "";
					connectRateLimit.waitFor();
					reconnect();
					break;
				case OpCode.heartbeat:
				case OpCode.heartbeatAck:
					receivedAck = true;
					break;
				default:
					break;
				}
			}
		}
		catch (Exception e)
		{
			if (socket.connected)
				socket.close(900);
			() @trusted{ logDiagnostic("Error in socket worker: %s", e); }();
		}
		validateDisconnectOpcode(socket.closeCode);
		if (socket.closeCode == 4007 || socket.closeCode == 4009)
			sessionID = "";
		if (!shouldDisconnect)
		{
			if (!sessionID.length)
				sleep(uniform(1000, 5000).msecs);
			reconnect(!!sessionID.length);
		}
	}

	void joinVoiceChannel(Snowflake guild, Snowflake channel, bool selfMute, bool selfDeaf)
	{
		UpdateVoiceStateCommand cmd;
		cmd.guild_id = guild;
		cmd.channel_id = channel;
		cmd.self_mute = selfMute;
		cmd.self_deaf = selfDeaf;
		send!(OpCode.voiceStatusUpdate)(cmd);
	}

	void disconnectVoiceChannel(Snowflake guild, bool selfMute = true, bool selfDeaf = true)
	{
		UpdateVoiceStateCommand cmd;
		cmd.guild_id = guild;
		cmd.self_mute = selfMute;
		cmd.self_deaf = selfDeaf;
		send!(OpCode.voiceStatusUpdate)(cmd);
	}

	void updateStatus(UpdateStatus.StatusType status,
			Nullable!Activity game = Nullable!Activity.init, bool afk = false,
			SysTime idleSince = SysTime.init)
	{
		statusRateLimit.waitFor();
		Nullable!long idle;
		if (idleSince != SysTime.init)
			idle = idleSince.toUnixTime!long;
		send!(OpCode.statusUpdate)(UpdateStatus(idle, game, status, afk));
	}

	void onReadyEvent(ReadyPacket packet)
	{
		sessionID = packet.session_id;
		info.protocolVersion = packet.v;
		info.user = packet.user;
		info.guilds = packet.guilds.map!(a => a.id).array;
		info.privateChannels = packet.private_channels.map!(a => a.id).array;
	}

	void onResumedEvent(ResumedPacket)
	{
	}

	void onChannelCreate(Channel c)
	{
		gChannelCache.put(c);
	}

	void onChannelUpdate(Channel c)
	{
		gChannelCache.patch(c);
	}

	void onChannelDelete(Channel c)
	{
		gChannelCache.remove(c.id);
	}

	void onChannelPinsUpdate(ChannelPinsUpdatePacket)
	{
		logDiagnostic("TODO: implement channel pins update");
	}

	void onGuildCreate(Guild g)
	{
		gGuildCache.put(g);
		foreach (channel; g.channels)
		{
			channel.guild_id = g.id;
			gChannelCache.put(channel);
		}
		foreach (member; g.members)
		{
			GuildUserCache entry;
			entry.guildUserID = [g.id, member.user.id];
			entry.roles = member.roles;
			entry.joinDate = member.joined_at;
			entry.deaf = member.deaf;
			entry.mute = member.mute;
			entry.nick = member.nick.isNull ? null : member.nick.get;
			gGuildUserCache.put(entry);
			gUserCache.patch(member.user, true);
		}
	}

	void onGuildUpdate(Guild g)
	{
		gGuildCache.patch(g);
	}

	void onGuildDelete(UnavailableGuild g)
	{
		gGuildCache.update(g.id, (scope ref guild) { guild.unavailable = true; });
	}

	void onGuildBanAdd(User user, Snowflake guild_id)
	{
	}

	void onGuildBanRemove(User user, Snowflake guild_id)
	{
	}

	void onGuildEmojisUpdate(GuildEmojisUpdatePacket p)
	{
		gGuildCache.update(p.guild_id, (scope ref guild) { guild.emojis = p.emojis; });
	}

	void onGuildIntegrationsUpdate(GuildIntegrationsUpdatePacket)
	{
	}

	void onGuildMemberAdd(GuildMember member, Snowflake guild_id, bool isChunk)
	{
		GuildUserCache entry;
		entry.guildUserID = [guild_id, member.user.id];
		entry.roles = member.roles;
		entry.joinDate = member.joined_at;
		entry.deaf = member.deaf;
		entry.mute = member.mute;
		entry.nick = member.nick.isNull ? null : member.nick.get;
		gGuildUserCache.put(entry);
		gUserCache.patch(member.user, true);
	}

	void onGuildMemberRemove(GuildMemberRemovePacket p)
	{
		gGuildUserCache.remove([p.guild_id, p.user.id]);
	}

	void onGuildMemberUpdate(GuildMemberUpdatePacket p)
	{
		gGuildUserCache.update([p.guild_id, p.user.id], (scope ref obj) {
			obj.roles = p.roles;
			obj.nick = p.nick;
		});
	}

	void onGuildMembersChunk(GuildMembersChunkPacket p)
	{
		foreach (member; p.members)
			onGuildMemberAdd(member, p.guild_id, true);
	}

	void onGuildRoleCreate(GuildRoleCreatePacket p)
	{
		gGuildCache.update(p.guild_id, (scope ref guild) { guild.roles ~= p.role; });
	}

	void onGuildRoleUpdate(GuildRoleUpdatePacket p)
	{
		gGuildCache.update(p.guild_id, (scope ref guild) {
			auto index = guild.roles.countUntil!(a => a.id == p.role.id);
			if (index == -1)
				guild.roles ~= p.role;
			else
				guild.roles[index] = p.role;
		});
	}

	void onGuildRoleDelete(GuildRoleDeletePacket p)
	{
		gGuildCache.update(p.guild_id, (scope ref guild) {
			auto index = guild.roles.countUntil!(a => a.id == p.role_id);
			if (index != -1)
				guild.roles = guild.roles.remove(index);
		});
	}

	void onMessageCreate(Message m) @trusted
	{
		gMessageCache.put(m);
	}

	void onMessageUpdate(Message m)
	{
		gMessageCache.patch(m);
	}

	void onMessageDelete(MessageDeletePacket m)
	{
		auto success = gMessageCache.remove(m.id);
		if (!success)
			(() @trusted => logDiagnostic("Could not delete message %s from cache", m))();
	}

	void onMessageDeleteBulk(MessageDeleteBulkPacket m)
	{
		auto failed = gMessageCache.removeAll(m.ids);
		if (failed.length)
			(() @trusted => logDiagnostic("Could not delete messages %s from cache", failed))();
	}

	void onMessageReactionAdd(MessageReactionAddPacket p)
	{
		gMessageCache.update(p.message_id, (scope ref msg) @trusted{
			auto index = msg.reactions.countUntil!(a => a.emoji == p.emoji);
			if (index != -1)
			{
				msg.reactions[index].count++;
				msg.reactions[index].users ~= p.user_id;
			}
			else
				msg.reactions ~= Reaction(1, false, p.emoji, [p.user_id]);
		});
	}

	void onMessageReactionRemove(MessageReactionRemovePacket p)
	{
		gMessageCache.update(p.message_id, (scope ref msg) @trusted{
			auto index = msg.reactions.countUntil!(a => a.emoji == p.emoji);
			if (index != -1)
			{
				msg.reactions[index].count--;
				auto userIndex = msg.reactions[index].users.countUntil(p.user_id);
				if (userIndex != -1)
					msg.reactions[index].users = msg.reactions[index].users.remove(userIndex);
			}
		});
	}

	void onMessageReactionRemoveAll(MessageReactionRemoveAllPacket p)
	{
		gMessageCache.update(p.message_id, (scope ref msg) @trusted{
			msg.reactions = null;
		});
	}

	void onPresenceUpdate(PresenceUpdate p)
	{
		gGuildUserCache.update([p.guild_id, p.user.id], (scope ref obj) {
			obj.status = p.status;
			obj.game = p.game;
			obj.roles = p.roles;
		}, true);
	}

	void onTypingStart(TypingStartPacket p)
	{
		gChannelUserCache.update([p.channel_id, p.user_id], (scope ref obj) {
			obj.typing = SysTime.fromUnixTime(p.timestamp);
		}, true);
	}

	void onUserUpdate(User u)
	{
		gUserCache.patch(u, true);
	}

	void onVoiceStateUpdate(VoiceState s)
	{
		gVoiceStateCache.update([s.guild_id, s.channel_id, s.user_id], (scope ref obj) @trusted{
			obj.state = s;
		}, true);
	}

	void onVoiceServerUpdate(VoiceServerUpdatePacket)
	{
	}

	void onWebhooksUpdate(WebhooksUpdatePacket)
	{
	}

	void processEvent(OpFrame frame) @safe
	{
		assert(frame.op == OpCode.dispatch);
		hasLastSequence = true;
		lastSequence = frame.s;
		switch (frame.t)
		{
		case "HELLO":
			logDiagnostic("Don't know how to handle a HELLO event (not opcode)");
			break;
		case "READY":
			onReadyEvent(frame.d!ReadyPacket);
			break;
		case "RESUMED":
			onResumedEvent(frame.d!ResumedPacket);
			break;
		case "INVALID_SESSION":
			logDiagnostic("Don't know how to handle an INVALID_SESSION event (not opcode)");
			break;
		case "CHANNEL_CREATE":
			onChannelCreate(frame.d!Channel);
			break;
		case "CHANNEL_UPDATE":
			onChannelUpdate(frame.d!Channel);
			break;
		case "CHANNEL_DELETE":
			onChannelDelete(frame.d!Channel);
			break;
		case "CHANNEL_PINS_UPDATE":
			onChannelPinsUpdate(frame.d!ChannelPinsUpdatePacket);
			break;
		case "GUILD_CREATE":
			onGuildCreate(frame.d!Guild);
			break;
		case "GUILD_UPDATE":
			onGuildUpdate(frame.d!Guild);
			break;
		case "GUILD_DELETE":
			onGuildDelete(frame.d!UnavailableGuild);
			break;
		case "GUILD_BAN_ADD":
			onGuildBanAdd(frame.d!User, frame.dExt!("guild_id", Snowflake));
			break;
		case "GUILD_BAN_REMOVE":
			onGuildBanRemove(frame.d!User, frame.dExt!("guild_id", Snowflake));
			break;
		case "GUILD_EMOJIS_UPDATE":
			onGuildEmojisUpdate(frame.d!GuildEmojisUpdatePacket);
			break;
		case "GUILD_INTEGRATIONS_UPDATE":
			onGuildIntegrationsUpdate(frame.d!GuildIntegrationsUpdatePacket);
			break;
		case "GUILD_MEMBER_ADD":
			onGuildMemberAdd(frame.d!GuildMember, frame.dExt!("guild_id", Snowflake), false);
			break;
		case "GUILD_MEMBER_REMOVE":
			onGuildMemberRemove(frame.d!GuildMemberRemovePacket);
			break;
		case "GUILD_MEMBER_UPDATE":
			onGuildMemberUpdate(frame.d!GuildMemberUpdatePacket);
			break;
		case "GUILD_MEMBERS_CHUNK":
			onGuildMembersChunk(frame.d!GuildMembersChunkPacket);
			break;
		case "GUILD_ROLE_CREATE":
			onGuildRoleCreate(frame.d!GuildRoleCreatePacket);
			break;
		case "GUILD_ROLE_UPDATE":
			onGuildRoleUpdate(frame.d!GuildRoleUpdatePacket);
			break;
		case "GUILD_ROLE_DELETE":
			onGuildRoleDelete(frame.d!GuildRoleDeletePacket);
			break;
		case "MESSAGE_CREATE":
			onMessageCreate(frame.d!Message);
			break;
		case "MESSAGE_UPDATE":
			onMessageUpdate(frame.d!Message);
			break;
		case "MESSAGE_DELETE":
			onMessageDelete(frame.d!MessageDeletePacket);
			break;
		case "MESSAGE_DELETE_BULK":
			onMessageDeleteBulk(frame.d!MessageDeleteBulkPacket);
			break;
		case "MESSAGE_REACTION_ADD":
			onMessageReactionAdd(frame.d!MessageReactionAddPacket);
			break;
		case "MESSAGE_REACTION_REMOVE":
			onMessageReactionRemove(frame.d!MessageReactionRemovePacket);
			break;
		case "MESSAGE_REACTION_REMOVE_ALL":
			onMessageReactionRemoveAll(frame.d!MessageReactionRemoveAllPacket);
			break;
		case "PRESENCE_UPDATE":
			onPresenceUpdate(frame.d!PresenceUpdate);
			break;
		case "TYPING_START":
			onTypingStart(frame.d!TypingStartPacket);
			break;
		case "USER_UPDATE":
			onUserUpdate(frame.d!User);
			break;
		case "VOICE_STATE_UPDATE":
			onVoiceStateUpdate(frame.d!VoiceState);
			break;
		case "VOICE_SERVER_UPDATE":
			onVoiceServerUpdate(frame.d!VoiceServerUpdatePacket);
			break;
		case "WEBHOOKS_UPDATE":
			onWebhooksUpdate(frame.d!WebhooksUpdatePacket);
			break;
		default:
			logDiagnostic("Received unknown event %s: %s", frame.t, frame);
			break;
		}
	}
}

struct OpFrame
{
	OpCode op;
	union
	{
		Json j;
		ETFNode e;
	}

	int s;
	string t;
	bool isJson;

	void opAssign(OpFrame other)
	{
		op = other.op;
		s = other.s;
		t = other.t;
		isJson = other.isJson;
		if (other.isJson)
			j = other.j;
		else
			e = other.e;
	}

	string toString() @trusted
	{
		string ret = "frame {op=" ~ op.to!string ~ ", s=" ~ s.to!string ~ ", t='" ~ t ~ "', d=";
		if (isJson)
			ret ~= j.toPrettyString;
		else
			ret ~= e.toString;
		ret ~= '}';
		return ret;
	}

	T d(T)() @trusted
	{
		if (isJson)
			return deserializeJson!T(j);
		else
			return ETFBuffer.deserialize!T(e.bufferStart, false);
	}

	T dExt(string member, T)() @trusted
	{
		if (isJson)
			return deserializeJson!T(j[member]);
		else
			return ETFBuffer.deserialize!T(e[member].bufferStart, false);
	}
}

enum OpCode
{
	dispatch,
	heartbeat,
	identify,
	statusUpdate,
	voiceStatusUpdate,
	voiceServerPing,
	resume,
	reconnect,
	requestGuildMembers,
	invalidSession,
	hello,
	heartbeatAck
}

struct OpHello
{
	mixin OptionalSerializer!(typeof(this));

	int heartbeat_interval;
	string[] _trace;
}

struct OpIdentify
{
	mixin OptionalSerializer!(typeof(this));

	string token;
	string[string] properties;
	bool compress;
	int large_threshold = 100;
	int[2] shard = [0, 1];
	UpdateStatus presence;
}

struct ResumeData
{
	mixin OptionalSerializer!(typeof(this));

	string token;
	string session_id;
	int seq;
}

struct ReadyPacket
{
	mixin OptionalSerializer!(typeof(this));

	int v;
	User user;
	Channel[] private_channels;
	UnavailableGuild[] guilds;
	string session_id;
	string[] _trace;
}

struct ResumedPacket
{
	mixin OptionalSerializer!(typeof(this));

	string[] _trace;
}

struct ChannelPinsUpdatePacket
{
	mixin OptionalSerializer!(typeof(this));

	Snowflake channel_id;
	@optional SafeTime last_pin_timestamp;
}

struct GuildEmojisUpdatePacket
{
	mixin OptionalSerializer!(typeof(this));

	Snowflake guild_id;
	Emoji[] emojis;
}

struct GuildIntegrationsUpdatePacket
{
	mixin OptionalSerializer!(typeof(this));

	Snowflake guild_id;
}

struct GuildMemberRemovePacket
{
	mixin OptionalSerializer!(typeof(this));

	Snowflake guild_id;
	User user;
}

struct GuildMemberUpdatePacket
{
	mixin OptionalSerializer!(typeof(this));

	Snowflake guild_id;
	Snowflake[] roles;
	User user;
	string nick;
}

struct GuildMembersChunkPacket
{
	mixin OptionalSerializer!(typeof(this));

	Snowflake guild_id;
	GuildMember[] members;
}

struct GuildRoleCreatePacket
{
	mixin OptionalSerializer!(typeof(this));

	Snowflake guild_id;
	Role role;
}

struct GuildRoleUpdatePacket
{
	mixin OptionalSerializer!(typeof(this));

	Snowflake guild_id;
	Role role;
}

struct GuildRoleDeletePacket
{
	mixin OptionalSerializer!(typeof(this));

	Snowflake guild_id;
	Snowflake role_id;
}

struct MessageDeletePacket
{
	mixin OptionalSerializer!(typeof(this));

	Snowflake id;
	Snowflake channel_id;
}

struct MessageDeleteBulkPacket
{
	mixin OptionalSerializer!(typeof(this));

	Snowflake[] ids;
	Snowflake channel_id;
}

struct MessageReactionAddPacket
{
	mixin OptionalSerializer!(typeof(this));

	Snowflake user_id;
	Snowflake channel_id;
	Snowflake message_id;
	Emoji emoji;
}

struct MessageReactionRemovePacket
{
	mixin OptionalSerializer!(typeof(this));

	Snowflake user_id;
	Snowflake channel_id;
	Snowflake message_id;
	Emoji emoji;
}

struct MessageReactionRemoveAllPacket
{
	mixin OptionalSerializer!(typeof(this));

	Snowflake channel_id;
	Snowflake message_id;
}

struct TypingStartPacket
{
	mixin OptionalSerializer!(typeof(this));

	Snowflake channel_id;
	Snowflake user_id;
	long timestamp;
}

struct VoiceServerUpdatePacket
{
	mixin OptionalSerializer!(typeof(this));

	string token;
	Snowflake guild_id;
	string endpoint;
}

struct WebhooksUpdatePacket
{
	mixin OptionalSerializer!(typeof(this));

	Snowflake guild_id;
	Snowflake channel_id;
}

struct UpdateVoiceStateCommand
{
	mixin OptionalSerializer!(typeof(this));

	Snowflake guild_id;
	Nullable!Snowflake channel_id;
	bool self_mute;
	bool self_deaf;
}

struct RequestGuildMembersCommand
{
	mixin OptionalSerializer!(typeof(this));

	Snowflake guild_id;
	string query;
	int limit = 0;
}
