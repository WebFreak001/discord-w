module discord.w.api;

import core.time;
import std.conv;
import std.datetime;
import std.string;
import std.typecons;
import std.uri;

import vibe.core.core;
import vibe.core.log;
import vibe.data.json;
import vibe.http.client;
import vibe.inet.url;
import vibe.stream.operations;

import discord.w.types;
import discord.w.json;

alias TTS = Flag!"tts";

enum discordwVersion = "1";

enum discordEndpointBase = "https://discordapp.com/api/v6";

struct HTTPRateLimit
{
	struct Info
	{
		long limit, remaining;
		SysTime reset;
	}

	Info[string] infos;
	bool globalRatelimit;
	SysTime globalReset;

	void call(string bucket) @safe
	{
		if (globalRatelimit)
		{
			auto left = globalReset - Clock.currTime;
			(() @trusted => logDebug("Global rate limit waiting %s", left))();
			sleep(left);
		}
		while (true)
		{
			auto info = bucket in infos;
			if (!info)
				return;
			auto now = Clock.currTime;
			if (info.reset == SysTime.init || info.reset <= now)
				return;
			if (info.remaining == 0)
			{
				(() @trusted => logDebug("Waiting for %s due to heuristic rate limit", info.reset - now))();
				sleep(info.reset - now);
				continue;
			}
			info.remaining--;
			(() @trusted => logDebugV("Got %s left in bucket %s", *info, bucket))();
			return;
		}
	}

	bool update(string bucket, scope HTTPClientResponse res) @safe
	{
		const limit = res.headers.get("X-RateLimit-Limit", "");
		const remaining = res.headers.get("X-RateLimit-Remaining", "");
		const reset = res.headers.get("X-RateLimit-Reset", "");
		const global = res.headers.get("X-RateLimit-Global", "");
		const retryAfter = res.headers.get("Retry-After", "");
		if (global == "true")
		{
			auto dur = retryAfter.length ? retryAfter.to!int.msecs : 5.seconds;
			(() @trusted => logDiagnostic("Got globally rate limited, retrying in %s", dur))();
			globalReset = Clock.currTime + dur;
			globalRatelimit = true;
			sleep(dur);
			return false;
		}
		if (!reset.length || !limit.length || !remaining.length)
		{
			if (res.statusCode == HTTPStatus.tooManyRequests)
			{
				(() @trusted => logDiagnostic("TOO MANY REQUESTS, but no RateLimit headers sent?"))();
				sleep(1.seconds);
				return false;
			}
			return true;
		}
		Info info;
		info.limit = limit.to!long;
		info.remaining = remaining.to!long;
		info.reset = SysTime.fromUnixTime(reset.to!long);
		(() @trusted => logDebugV("Updating ratelimit bucket %s to %s", bucket, info))();
		infos[bucket] = info;
		bool gotResponse = res.statusCode != HTTPStatus.tooManyRequests;
		if (!gotResponse)
		{
			auto now = Clock.currTime;
			if (info.reset > now)
			{
				(() @trusted => logDebug("Retrying in %s because of %s rate limit", info.reset - now,
						bucket))();
				sleep(info.reset - now);
			}
			else
				(() @trusted => logDebug("Retrying immediately because of %s rate limit", bucket))();
		}
		return gotResponse;
	}
}

HTTPRateLimit httpRateLimit;

Json requestDiscordEndpoint(string route, string bucket = "",
		void delegate(scope HTTPClientRequest req) @safe requester = null) @safe
{
	(() @trusted => logDebug("Requesting Discord API Route %s (with rate limit bucket %s)",
			route, bucket))();
	if (!bucket.length)
		bucket = route;
	assert(route.length && route[0] == '/');
	assert(bucket.length && bucket[0] == '/');
	URL url = URL(discordEndpointBase ~ route);
	Json ret;
	bool haveRet;
	httpRateLimit.call(bucket);
	int try_ = 0;
	while (!haveRet)
	{
		if (try_ > 5)
			throw new Exception("Failed to request endpoint after 5 retries.");
		try_++;
		(() @trusted => logDebugV("Request try %s for %s", try_, url))();
		auto task = Task.getThis();
		auto t = (() @trusted => setTimer(12.seconds, { task.interrupt(); }))();
		scope (exit)
			t.stop();
		try
		{
			requestHTTP(url, (scope req) {
				req.headers.addField("User-Agent",
					"DiscordBot (https://github.com/WebFreak001/discord-w, " ~ discordwVersion ~ ")");
				if (requester)
					requester(req);
			}, (scope res) {
				t.stop();
				if (res.statusCode >= 300 && res.statusCode < 400)
				{
					string loc = res.headers.get("Location", "");
					(() @trusted => logDebugV("Getting redirected to %s", loc))();
					if (!loc.length)
						throw new Exception("Expected 'Location' header for redirect status code");
					if (loc.startsWith("http:", "https:"))
					{
						if (!loc.startsWith(discordEndpointBase))
							throw new Exception(
								"Global redirect not redirecting to discord endpoint base, aborting request");
						url = URL(discordEndpointBase ~ loc[discordEndpointBase.length .. $]);
					}
					else if (loc[0] == '/')
					{
						auto apiBase = URL(discordEndpointBase).pathString;
						if (!loc.startsWith(apiBase))
							throw new Exception("Redirect escaping current API base path");
						url = URL(discordEndpointBase ~ loc[apiBase.length .. $]);
					}
					else
					{
						url = url.parentURL ~ InetPath(loc);
					}
				}
				else
				{
					(() @trusted => logTrace("updating bucket for %s", url))();
					bool cont = httpRateLimit.update(bucket, res);
					(() @trusted => logTrace("updated bucket for %s, result=%s", url, cont))();
					if (res.statusCode == HTTPStatus.tooManyRequests)
					{
						(() @trusted => logDebugV("Got 429 TOO MANY REQUESTS for %s", url))();
						return;
					}
					else if (!(res.statusCode >= 200 && res.statusCode < 300))
						throw new Exception(
							"Got invalid HTTP status code " ~ res.statusCode.to!string
							~ " with data " ~ res.bodyReader.readAllUTF8);
					if (res.statusCode != 204)
						ret = res.bodyReader.readAllUTF8.parseJsonString;
					haveRet = true;
				}
			});
		}
		catch (InterruptException)
		{
			logWarn("Request for %s took too long and was interrupted", url);
		}
	}
	return ret;
}

Json requestDiscordEndpointNull(HTTPMethod method, string route, string bucket,
		scope void delegate(scope HTTPClientRequest req) @safe requester) @safe
{
	return requestDiscordEndpoint(route, bucket, (scope req) @safe {
		if (requester)
			requester(req);
		req.method = method;
		req.writeBody(null, null);
	});
}

Json requestDiscordEndpointJson(T)(HTTPMethod method, T value, string route,
		string bucket, scope void delegate(scope HTTPClientRequest req) @safe requester) @safe
{
	return requestDiscordEndpoint(route, bucket, (scope req) @safe {
		if (requester)
			requester(req);
		req.method = method;
		req.writeJsonBody(value);
	});
}

enum simpleRequesters = q{
	Json simpleNullRequest(HTTPMethod method, string route = "", string bucket = "") const @safe
	{
		prependEndpoint(endpoint, route);
		if (bucket.length)
			prependEndpoint(endpoint, bucket);
		return requestDiscordEndpointNull(method, route, bucket, requester);
	}

	Json simpleJsonRequest(T)(HTTPMethod method, T value, string route = "", string bucket = "") const @safe
	{
		prependEndpoint(endpoint, route);
		if (bucket.length)
			prependEndpoint(endpoint, bucket);
		return requestDiscordEndpointJson(method, value, route, bucket, requester);
	}
};

void prependEndpoint(string endpoint, ref string value) @safe
{
	if (!value.length)
	{
		value = endpoint;
		return;
	}
	else if (value.startsWith(endpoint))
		return;
	else if (value.startsWith("/"))
		value = endpoint ~ value;
	else
		value = endpoint ~ "/" ~ value;
}

void delegate(scope HTTPClientRequest req) @safe authBot(string token,
		scope void delegate(scope HTTPClientRequest req) @safe then = null) @safe
{
	return (scope req) @safe {
		req.headers.addField("Authorization", "Bot " ~ token);
		if (then)
			then(req);
	};
}

struct ChannelAPI
{
	string endpoint;
	void delegate(scope HTTPClientRequest req) @safe requester;

	this(Snowflake id, void delegate(scope HTTPClientRequest req) @safe requester = null) @safe
	{
		endpoint = "/channels/" ~ id.toString;
		this.requester = requester;
	}

	struct Update
	{
		mixin OptionalSerializer!(typeof(this));

		@optional Nullable!string name;
		@optional int position = -1;
		@optional Nullable!string topic;
		@optional Nullable!bool nsfw;
		@optional int bitrate;
		@optional int user_limit = -1;
		@optional Overwrite[] permission_overwrites;
		@optional Nullable!Snowflake parent_id;
	}

	mixin(simpleRequesters);

	Channel get() const @safe
	{
		return simpleNullRequest(HTTPMethod.GET).deserializeJson!Channel;
	}

	@(Permissions.MANAGE_CHANNELS)
	void updateChannel(Update update) const @safe
	{
		simpleJsonRequest(HTTPMethod.PATCH, update);
	}

	@(Permissions.MANAGE_CHANNELS)
	void deleteChannel() const @safe
	{
		simpleNullRequest(HTTPMethod.DELETE);
	}

	@(Permissions.READ_MESSAGE_HISTORY)
	Message[] getMessages(int limit = 50, Nullable!Snowflake around = Nullable!Snowflake.init,
			Nullable!Snowflake before = Nullable!Snowflake.init,
			Nullable!Snowflake after = Nullable!Snowflake.init) const @safe
	{
		if (limit > 100)
			throw new Exception("Can only get at most 100 messages");
		auto route = "/messages";
		string query = "?limit=" ~ limit.to!string;
		if (!around.isNull)
			query ~= "&around=" ~ around.get.toString;
		if (!before.isNull)
			query ~= "&before=" ~ before.get.toString;
		if (!after.isNull)
			query ~= "&after=" ~ after.get.toString;
		return simpleNullRequest(HTTPMethod.GET, route ~ query, route).deserializeJson!(Message[]);
	}

	@(Permissions.READ_MESSAGE_HISTORY)
	Message getMessage(Snowflake id) const @safe
	{
		return simpleNullRequest(HTTPMethod.GET, "/messages/" ~ id.toString, "/messages")
			.deserializeJson!Message;
	}

	@(Permissions.SEND_MESSAGES)
	Message sendMessage(string content, Nullable!Snowflake nonce = Nullable!Snowflake.init,
			TTS tts = No.tts, Nullable!Embed embed = Nullable!Embed.init) const @safe
	{
		auto route = endpoint ~ "/messages";
		Json json = Json.emptyObject;
		json["content"] = Json(content);
		if (!nonce.isNull)
			json["nonce"] = Json(nonce.get.toString);
		if (tts)
			json["tts"] = Json(true);
		if (!embed.isNull)
			json["embed"] = serializeToJson(embed.get);
		return requestDiscordEndpoint(route, route, (scope req) {
			// waiting for https://github.com/vibe-d/vibe.d/pull/1876
			// or https://github.com/vibe-d/vibe.d/pull/1178
			// to get merged to support file/image upload
			if (requester)
				requester(req);
			req.method = HTTPMethod.POST;
			req.writeJsonBody(json);
		}).deserializeJson!Message;
	}

	@(Permissions.SEND_MESSAGES)
	Message updateOwnMessage(Snowflake message, string content = null,
			Nullable!Embed embed = Nullable!Embed.init) const @safe
	{
		Json json = Json.emptyObject;
		if (content.length)
			json["content"] = Json(content);
		if (!embed.isNull)
			json["embed"] = serializeToJson(embed.get);
		return simpleJsonRequest(HTTPMethod.PATCH, json, "/messages/" ~ message.toString, "/messages")
			.deserializeJson!Message;
	}

	@(Permissions.MANAGE_MESSAGES)
	void deleteMessage(Snowflake message) const @safe
	{
		simpleNullRequest(HTTPMethod.DELETE, "/messages/" ~ message.toString, "/messages");
	}

	@(Permissions.MANAGE_MESSAGES)
	void deleteMessages(Snowflake[] messages) const @safe
	{
		if (messages.length < 1)
			throw new Exception("Need to delete at least 1 message");
		if (messages.length == 0)
			return deleteMessage(messages[0]);
		if (messages.length > 100)
			throw new Exception("Can delete at most 100 messages");
		simpleJsonRequest(HTTPMethod.POST, ["messages" : messages], "/messages/bulk-delete");
	}

	@(Permissions.READ_MESSAGE_HISTORY | Permissions.ADD_REACTIONS)
	void react(Snowflake message, Emoji emoji) const @trusted
	{
		string path = "/messages/" ~ message.toString ~ "/reactions/"
			~ emoji.toAPIString ~ "/" ~ "@me".encodeComponent;
		simpleNullRequest(HTTPMethod.PUT, path, "/messages/reactions");
	}

	@(Permissions.READ_MESSAGE_HISTORY | Permissions.ADD_REACTIONS)
	void unreact(Snowflake message, Emoji emoji) const @trusted
	{
		string path = "/messages/" ~ message.toString ~ "/reactions/"
			~ emoji.toAPIString ~ "/" ~ "@me".encodeComponent;
		simpleNullRequest(HTTPMethod.DELETE, path, "/messages/reactions");
	}

	@(Permissions.READ_MESSAGE_HISTORY | Permissions.MANAGE_MESSAGES)
	void deleteReaction(Snowflake message, Emoji emoji, Snowflake author) const @trusted
	{
		string path = "/messages/" ~ message.toString ~ "/reactions/"
			~ emoji.toAPIString ~ "/" ~ author.toString;
		simpleNullRequest(HTTPMethod.DELETE, path, "/messages/reactions");
	}

	@(Permissions.READ_MESSAGE_HISTORY)
	User[] getReactionsByEmoji(Snowflake message, Emoji emoji, Nullable!Snowflake before = Nullable!Snowflake.init,
			Nullable!Snowflake after = Nullable!Snowflake.init, int limit = 100) const @trusted
	{
		string query = "?limit=" ~ limit.to!string;
		if (!before.isNull)
			query ~= "&before=" ~ before.get.toString;
		if (!after.isNull)
			query ~= "&after=" ~ after.get.toString;
		string path = "/messages/" ~ message.toString ~ "/reactions/" ~ emoji.toAPIString ~ query;
		return simpleNullRequest(HTTPMethod.GET, path, "/messages/reactions").deserializeJson!(User[]);
	}

	@(Permissions.MANAGE_MESSAGES)
	void clearReactions(Snowflake message) const @trusted
	{
		simpleNullRequest(HTTPMethod.DELETE,
				"/messages/" ~ message.toString ~ "/reactions", "/messages/reactions");
	}

	@(Permissions.MANAGE_ROLES)
	void editChannelPermissions(Snowflake overwrite, uint allow, uint deny, string type) const @trusted
	{
		Json json = Json.emptyObject;
		json["allow"] = Json(allow);
		json["deny"] = Json(deny);
		json["type"] = Json(type);
		simpleJsonRequest(HTTPMethod.PUT, json, "/permissions/" ~ overwrite.toString);
	}

	@(Permissions.MANAGE_ROLES)
	void deleteChannelPermissions(Snowflake overwrite) const @trusted
	{
		simpleNullRequest(HTTPMethod.DELETE, "/permissions/" ~ overwrite.toString, "/permissions");
	}

	@(Permissions.MANAGE_CHANNELS)
	Invite[] getInvites() const @trusted
	{
		return simpleNullRequest(HTTPMethod.GET, "/invites").deserializeJson!(Invite[]);
	}

	@(Permissions.CREATE_INSTANT_INVITE)
	Invite createInvite(Duration maxAge = 24.hours, int maxUses = 0,
			bool temporary = false, bool unique = false) const @trusted
	{
		Json json;
		if (maxAge != 24.hours)
			json["max_age"] = Json(maxAge.total!"seconds");
		if (maxUses)
			json["max_uses"] = Json(maxUses);
		if (temporary)
			json["temporary"] = Json(temporary);
		if (unique)
			json["unique"] = Json(unique);
		return simpleJsonRequest(HTTPMethod.POST, json, "/invites").deserializeJson!Invite;
	}

	void triggerTypingIndicator() const @trusted
	{
		simpleNullRequest(HTTPMethod.POST, "/typing");
	}

	Message[] getPinnedMessages() const @trusted
	{
		return simpleNullRequest(HTTPMethod.GET, "/pins").deserializeJson!(Message[]);
	}

	@(Permissions.MANAGE_MESSAGES)
	void pinMessage(Snowflake id) const @trusted
	{
		simpleNullRequest(HTTPMethod.PUT, "/pins/" ~ id.toString, "/pins");
	}

	@(Permissions.MANAGE_MESSAGES)
	void unpinMessage(Snowflake id) const @trusted
	{
		simpleNullRequest(HTTPMethod.DELETE, "/pins/" ~ id.toString, "/pins");
	}

	void addToGroupDM(Snowflake user) const @trusted
	{
		simpleNullRequest(HTTPMethod.PUT, "/recipients/" ~ user.toString, "/recipients");
	}

	void removeFromGroupDM(Snowflake user) const @trusted
	{
		simpleNullRequest(HTTPMethod.DELETE, "/recipients/" ~ user.toString, "/recipients");
	}
}

struct GuildAPI
{
	string endpoint;
	void delegate(scope HTTPClientRequest req) @safe requester;

	this(Snowflake id, void delegate(scope HTTPClientRequest req) @safe requester = null) @safe
	{
		endpoint = "/guilds/" ~ id.toString;
		this.requester = requester;
	}

	mixin(simpleRequesters);

	Guild get() const @safe
	{
		return simpleNullRequest(HTTPMethod.GET).deserializeJson!Guild;
	}

	struct Update
	{
		mixin OptionalSerializer!(typeof(this));

		@optional Nullable!string name;
		@optional Nullable!string region;
		@optional int verification_level = -1;
		@optional int default_message_notifications = -1;
		@optional int explicit_content_filter = -1;
		@optional Nullable!Snowflake afk_channel_id;
		@optional int afk_timeout = -1;
		@optional Nullable!string icon;
		@optional Nullable!Snowflake owner_id;
		@optional Nullable!string splash;
		@optional Nullable!Snowflake system_channel_id;
	}

	@(Permissions.MANAGE_GUILD)
	Guild updateGuild(Update update) const @safe
	{
		return simpleJsonRequest(HTTPMethod.PATCH, update).deserializeJson!Guild;
	}

	@(Permissions.MANAGE_GUILD)
	void deleteGuild() const @safe
	{
		simpleNullRequest(HTTPMethod.DELETE);
	}

	Channel[] channels() const @safe
	{
		return simpleNullRequest(HTTPMethod.GET, "/channels").deserializeJson!(Channel[]);
	}

	struct ChannelArgs
	{
		mixin OptionalSerializer!(typeof(this));

		@optional Nullable!string name;
		@optional int type = -1;
		@optional int bitrate = -1;
		@optional int user_limit = -1;
		@optional Overwrite[] permission_overwrites;
		@optional Nullable!Snowflake parent_id;
		@optional Nullable!bool nsfw;
	}

	@(Permissions.MANAGE_CHANNELS)
	Channel createChannel(ChannelArgs args) const @safe
	{
		return simpleJsonRequest(HTTPMethod.POST, args, "/channels").deserializeJson!Channel;
	}

	@(Permissions.MANAGE_CHANNELS)
	void moveChannel(Snowflake channel, int position) const @safe
	{
		simpleJsonRequest(HTTPMethod.PATCH, ["id" : channel.toJson, "position"
				: Json(position)], "/channels");
	}

	GuildMember guildMember(Snowflake userID) const @safe
	{
		return simpleNullRequest(HTTPMethod.GET, "/members/" ~ userID.toString, "/members")
			.deserializeJson!GuildMember;
	}

	GuildMember[] members(int limit = 1, Snowflake after = Snowflake.init) const @safe
	{
		string query = "?";
		if (limit != 1)
			query ~= "limit=" ~ limit.to!string ~ "&";
		if (after != Snowflake.init)
			query ~= "after=" ~ after.toString ~ "&";
		query.length--;
		return simpleNullRequest(HTTPMethod.GET, "/members" ~ query, "/members").deserializeJson!(
				GuildMember[]);
	}

	struct AddGuildMemberArgs
	{
		mixin OptionalSerializer!(typeof(this));

		@optional Nullable!string access_token;
		@optional Nullable!string nick;
		@optional Snowflake[] roles;
		@optional Nullable!bool mute;
		@optional Nullable!bool deaf;
	}

	GuildMember addMember(Snowflake userID, AddGuildMemberArgs args) const @safe
	{
		return simpleJsonRequest(HTTPMethod.PUT, args, "/members/" ~ userID.toString, "/members")
			.deserializeJson!GuildMember;
	}

	struct ChangeGuildMemberArgs
	{
		mixin OptionalSerializer!(typeof(this));

		@optional Nullable!string nick;
		@optional Snowflake[] roles;
		@optional Nullable!bool mute;
		@optional Nullable!bool deaf;
		@optional Nullable!Snowflake channel_id;
	}

	void modifyMember(Snowflake userID, ChangeGuildMemberArgs args) const @safe
	{
		simpleJsonRequest(HTTPMethod.PATCH, args, "/members/" ~ userID.toString, "/members");
	}

	@(Permissions.CHANGE_NICKNAME)
	string changeNickname(string nickname) const @safe
	{
		return simpleJsonRequest(HTTPMethod.PATCH, ["nick" : nickname], "/members/@me/nick")
			.deserializeJson!string;
	}

	@(Permissions.MANAGE_ROLES)
	void addMemberRole(Snowflake user, Snowflake role) const @safe
	{
		simpleNullRequest(HTTPMethod.PUT,
				"/members/" ~ user.toString ~ "/roles/" ~ role.toString, "/members/roles");
	}

	@(Permissions.MANAGE_ROLES)
	void removeMemberRole(Snowflake user, Snowflake role) const @safe
	{
		simpleNullRequest(HTTPMethod.DELETE,
				"/members/" ~ user.toString ~ "/roles/" ~ role.toString, "/members/roles");
	}

	@(Permissions.KICK_MEMBERS)
	void kickUser(Snowflake user) const @safe
	{
		simpleNullRequest(HTTPMethod.DELETE, "/members/" ~ user.toString, "/members");
	}

	@(Permissions.BAN_MEMBERS)
	Ban[] bans() const @safe
	{
		return simpleNullRequest(HTTPMethod.GET, "/bans").deserializeJson!(Ban[]);
	}

	@(Permissions.BAN_MEMBERS)
	void banUser(Snowflake user, string reason = "", int deleteMessageDays = 0) const @safe
	{
		string query = "";
		if (deleteMessageDays != 0)
			query ~= "&delete-message-days=" ~ deleteMessageDays.to!string;
		if (reason.length)
			query ~= "&reason=" ~ (() @trusted => reason.encodeComponent)();
		if (query.length)
			(() @trusted => (cast(char[]) query)[0] = '?')();
		simpleNullRequest(HTTPMethod.PUT, "/bans/" ~ user.toString ~ query, "/bans");
	}

	@(Permissions.BAN_MEMBERS)
	void unbanUser(Snowflake user) const @safe
	{
		simpleNullRequest(HTTPMethod.DELETE, "/bans/" ~ user.toString, "/bans");
	}

	Role[] roles() const @safe
	{
		return simpleNullRequest(HTTPMethod.GET, "/roles").deserializeJson!(Role[]);
	}

	struct RoleCreateArgs
	{
		mixin OptionalSerializer!(typeof(this));

		string name;
		int color;
		bool hoist;
		uint permissions;
		bool mentionable;
	}

	@(Permissions.MANAGE_ROLES)
	Role createRole(RoleCreateArgs role) const @safe
	{
		return simpleJsonRequest(HTTPMethod.POST, role, "/roles").deserializeJson!Role;
	}

	@(Permissions.MANAGE_ROLES)
	Role[] moveRole(Snowflake role, int position) const @safe
	{
		return simpleJsonRequest(HTTPMethod.PATCH, ["id" : role.toJson, "position"
				: Json(position)], "/roles").deserializeJson!(Role[]);
	}

	@(Permissions.MANAGE_ROLES)
	Role updateRole(Snowflake id, RoleCreateArgs role) const @safe
	{
		return simpleJsonRequest(HTTPMethod.PATCH, role, "/roles/" ~ id.toString, "/roles")
			.deserializeJson!Role;
	}

	@(Permissions.MANAGE_ROLES)
	void removeRole(Snowflake id) const @safe
	{
		simpleNullRequest(HTTPMethod.DELETE, "/roles/" ~ id.toString, "/roles");
	}

	@(Permissions.KICK_MEMBERS)
	int checkPrune(int days) const @safe
	{
		return simpleNullRequest(HTTPMethod.GET, "/prune?days=" ~ days.to!string)["pruned"]
			.deserializeJson!int;
	}

	@(Permissions.KICK_MEMBERS)
	int pruneMembers(int days) const @safe
	{
		return simpleNullRequest(HTTPMethod.POST, "/prune?days=" ~ days.to!string)["pruned"]
			.deserializeJson!int;
	}

	VoiceRegion[] voiceRegions() const @safe
	{
		return simpleNullRequest(HTTPMethod.GET, "/regions").deserializeJson!(VoiceRegion[]);
	}

	@(Permissions.MANAGE_GUILD)
	Invite[] invites() const @safe
	{
		return simpleNullRequest(HTTPMethod.GET, "/invites").deserializeJson!(Invite[]);
	}

	@(Permissions.MANAGE_GUILD)
	Integration[] integration() const @safe
	{
		return simpleNullRequest(HTTPMethod.GET, "/integrations").deserializeJson!(Integration[]);
	}

	@(Permissions.MANAGE_GUILD)
	void createIntegration(string type, Snowflake id) const @safe
	{
		simpleJsonRequest(HTTPMethod.POST, ["type" : Json(type), "id" : id.toJson], "/integrations");
	}

	@(Permissions.MANAGE_GUILD)
	void updateGuildIntegration(Snowflake id, int expireBehavior,
			int expireGracePeriod, bool enableEmoticons) const @safe
	{
		simpleJsonRequest(HTTPMethod.PATCH, ["expire_behavior" : Json(expireBehavior), "expire_grace_period"
				: Json(expireGracePeriod), "enable_emoticons" : Json(enableEmoticons)],
				"/integrations/" ~ id.toString, "/integrations");
	}

	@(Permissions.MANAGE_GUILD)
	void deleteIntegration(Snowflake id) const @safe
	{
		simpleNullRequest(HTTPMethod.DELETE, "/integrations/" ~ id.toString, "/integrations");
	}

	@(Permissions.MANAGE_GUILD)
	void syncIntegration(Snowflake id) const @safe
	{
		simpleNullRequest(HTTPMethod.POST, "/integrations/" ~ id.toString ~ "/sync",
				"/integrations/sync");
	}

	@(Permissions.MANAGE_GUILD)
	GuildEmbed embed(Snowflake id) const @safe
	{
		return simpleNullRequest(HTTPMethod.GET, "/embed").deserializeJson!GuildEmbed;
	}

	@(Permissions.MANAGE_GUILD)
	GuildEmbed updateEmbed(GuildEmbed embed) const @safe
	{
		return simpleJsonRequest(HTTPMethod.PATCH, embed, "/embed").deserializeJson!GuildEmbed;
	}

	@(Permissions.MANAGE_GUILD)
	string vanityUrl() const @safe
	{
		return simpleNullRequest(HTTPMethod.GET, "/vanity-url")["code"].opt!string(null);
	}
}
