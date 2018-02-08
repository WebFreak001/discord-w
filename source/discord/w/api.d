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

	void call(string endpoint) @safe
	{
		if (globalRatelimit)
		{
			auto left = globalReset - Clock.currTime;
			sleep(left);
		}
		while (true)
		{
			auto info = endpoint in infos;
			if (!info)
				return;
			auto now = Clock.currTime;
			if (info.reset == SysTime.init || info.reset <= now)
			{
				info.remaining = info.limit;
				info.reset = now + 10.minutes;
			}
			if (info.remaining == 0)
			{
				sleep(info.reset - now);
				continue;
			}
			info.remaining--;
			break;
		}
	}

	bool update(string endpoint, scope HTTPClientResponse res) @safe
	{
		const limit = res.headers.get("X-RateLimit-Limit", "");
		const remaining = res.headers.get("X-RateLimit-Remaining", "");
		const reset = res.headers.get("X-RateLimit-Reset", "");
		const global = res.headers.get("X-RateLimit-Global", "");
		const retryAfter = res.headers.get("Retry-After", "");
		if (global.length)
		{
			auto dur = retryAfter.length ? retryAfter.to!int.msecs : 5.seconds;
			globalReset = Clock.currTime + dur;
			globalRatelimit = true;
			sleep(dur);
			return false;
		}
		if (!reset.length || !limit.length || !remaining.length)
		{
			if (res.statusCode == HTTPStatus.tooManyRequests)
			{
				sleep(1.seconds);
				return false;
			}
			return true;
		}
		Info info;
		info.limit = limit.to!long;
		info.remaining = remaining.to!long;
		info.reset = SysTime.fromUnixTime(reset.to!long);
		infos[endpoint] = info;
		bool ret = res.statusCode != HTTPStatus.tooManyRequests;
		if (!ret)
		{
			auto now = Clock.currTime;
			if (info.reset > now)
				sleep(info.reset - now);
		}
		return ret;
	}
}

HTTPRateLimit httpRateLimit;

Json requestDiscordEndpoint(string route, string endpoint = "",
		void delegate(scope HTTPClientRequest req) @safe requester = null) @safe
{
	(() @trusted => logDebug("Requesting Discord API Route %s (with rate limit endpoint %s)",
			route, endpoint))();
	if (!endpoint.length)
		endpoint = route;
	assert(route.length && route[0] == '/');
	assert(endpoint.length && endpoint[0] == '/');
	URL url = URL(discordEndpointBase ~ route);
	Json ret;
	bool haveRet;
	httpRateLimit.call(endpoint);
	while (!haveRet)
	{
		requestHTTP(url, (scope req) {
			req.headers.addField("User-Agent",
				"DiscordBot (https://github.com/WebFreak001/discord-w, " ~ discordwVersion ~ ")");
			if (requester)
				requester(req);
		}, (scope res) {
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
					url = url.parentURL ~ Path(loc);
				}
			}
			else
			{
				httpRateLimit.update(endpoint, res);
				if (res.statusCode == HTTPStatus.tooManyRequests)
					return;
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
	return ret;
}

void delegate(scope HTTPClientRequest req) @safe authBot(string token,
		scope void delegate(scope HTTPClientRequest req) @safe then = null) @safe
{
	return (scope req) @safe{
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

		@optional string name;
		@optional int position = -1;
		@optional string topic;
		@optional Nullable!bool nsfw;
		@optional int bitrate;
		@optional int user_limit = -1;
		@optional Overwrite[] permission_overwrites;
		@optional Nullable!Snowflake parent_id;
	}

	Channel get() const @safe
	{
		return requestDiscordEndpoint(endpoint, endpoint, (scope req) {
			if (requester)
				requester(req);
			req.method = HTTPMethod.GET;
			req.writeBody(null, null);
		}).deserializeJson!Channel;
	}

	@(Permissions.MANAGE_CHANNELS)
	void updateChannel(Update update) const @safe
	{
		requestDiscordEndpoint(endpoint, endpoint, (scope req) {
			if (requester)
				requester(req);
			req.method = HTTPMethod.PATCH;
			req.writeJsonBody(serializeToJson(update));
		});
	}

	@(Permissions.MANAGE_CHANNELS)
	void deleteChannel() const @safe
	{
		requestDiscordEndpoint(endpoint, endpoint, (scope req) {
			if (requester)
				requester(req);
			req.method = HTTPMethod.DELETE;
			req.writeBody(null, null);
		});
	}

	@(Permissions.READ_MESSAGE_HISTORY)
	Message[] getMessages(int limit = 50, Nullable!Snowflake around = Nullable!Snowflake.init,
			Nullable!Snowflake before = Nullable!Snowflake.init,
			Nullable!Snowflake after = Nullable!Snowflake.init) const @safe
	{
		auto route = endpoint ~ "/messages";
		string query = "?limit=" ~ limit.to!string;
		if (!around.isNull)
			query ~= "&around=" ~ around.get.toString;
		if (!before.isNull)
			query ~= "&before=" ~ before.get.toString;
		if (!after.isNull)
			query ~= "&after=" ~ after.get.toString;
		return requestDiscordEndpoint(route ~ query, route, (scope req) {
			if (requester)
				requester(req);
			req.method = HTTPMethod.GET;
			req.writeBody(null, null);
		}).deserializeJson!(Message[]);
	}

	@(Permissions.READ_MESSAGE_HISTORY)
	Message getMessage(Snowflake id) const @safe
	{
		auto route = endpoint ~ "/messages";
		return requestDiscordEndpoint(route ~ "/" ~ id.toString, route, (scope req) {
			if (requester)
				requester(req);
			req.method = HTTPMethod.GET;
			req.writeBody(null, null);
		}).deserializeJson!Message;
	}

	@(Permissions.SEND_MESSAGES)
	void sendMessage(string content, Nullable!Snowflake nonce = Nullable!Snowflake.init,
			bool tts = false, Nullable!Embed embed = Nullable!Embed.init) const @safe
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
		requestDiscordEndpoint(route, route, (scope req) {
			// waiting for https://github.com/vibe-d/vibe.d/pull/1876
			// or https://github.com/vibe-d/vibe.d/pull/1178
			// to get merged to support file/image upload
			if (requester)
				requester(req);
			req.method = HTTPMethod.POST;
			req.writeJsonBody(json);
		});
	}

	@(Permissions.SEND_MESSAGES)
	void updateOwnMessage(Snowflake message, string content = null,
			Nullable!Embed embed = Nullable!Embed.init) const @safe
	{
		auto route = endpoint ~ "/messages";
		Json json = Json.emptyObject;
		if (content.length)
			json["content"] = Json(content);
		if (!embed.isNull)
			json["embed"] = serializeToJson(embed.get);
		requestDiscordEndpoint(route ~ "/" ~ message.toString, route, (scope req) {
			if (requester)
				requester(req);
			req.method = HTTPMethod.PATCH;
			req.writeJsonBody(json);
		});
	}

	@(Permissions.MANAGE_MESSAGES)
	void deleteMessage(Snowflake message) const @safe
	{
		auto route = endpoint ~ "/messages";
		requestDiscordEndpoint(route ~ "/" ~ message.toString, route, (scope req) {
			if (requester)
				requester(req);
			req.method = HTTPMethod.DELETE;
			req.writeBody(null, null);
		});
	}

	@(Permissions.MANAGE_MESSAGES)
	void deleteMessages(Snowflake[] message) const @safe
	{
		if (message.length < 2)
			throw new Exception("Need to delete at least 2 messages");
		if (message.length > 100)
			throw new Exception("Can delete at most 100 messages");
		auto route = endpoint ~ "/messages";
		requestDiscordEndpoint(route ~ "/bulk-delete", route, (scope req) {
			if (requester)
				requester(req);
			req.method = HTTPMethod.POST;
			req.writeJsonBody(message);
		});
	}

	@(Permissions.READ_MESSAGE_HISTORY | Permissions.ADD_REACTIONS)
	void react(Snowflake message, Emoji emoji) const @trusted
	{
		auto route = endpoint ~ "/messages";
		string path = route ~ "/" ~ message.toString ~ "/reactions/"
			~ emoji.toAPIString ~ "/" ~ "@me".encodeComponent;
		requestDiscordEndpoint(path, route, (scope req) {
			if (requester)
				requester(req);
			req.method = HTTPMethod.PUT;
			req.writeBody(null, null);
		});
	}

	@(Permissions.READ_MESSAGE_HISTORY | Permissions.ADD_REACTIONS)
	void unreact(Snowflake message, Emoji emoji) const @trusted
	{
		auto route = endpoint ~ "/messages";
		string path = route ~ "/" ~ message.toString ~ "/reactions/"
			~ emoji.toAPIString ~ "/" ~ "@me".encodeComponent;
		requestDiscordEndpoint(path, route, (scope req) {
			if (requester)
				requester(req);
			req.method = HTTPMethod.DELETE;
			req.writeBody(null, null);
		});
	}

	@(Permissions.READ_MESSAGE_HISTORY | Permissions.MANAGE_MESSAGES)
	void deleteReaction(Snowflake message, Emoji emoji, Snowflake author) const @trusted
	{
		auto route = endpoint ~ "/messages";
		string path = route ~ "/" ~ message.toString ~ "/reactions/"
			~ emoji.toAPIString ~ "/" ~ author.toString;
		requestDiscordEndpoint(path, route, (scope req) {
			if (requester)
				requester(req);
			req.method = HTTPMethod.DELETE;
			req.writeBody(null, null);
		});
	}

	@(Permissions.READ_MESSAGE_HISTORY)
	User[] getReactionsByEmoji(Snowflake message, Emoji emoji, Nullable!Snowflake before = Nullable!Snowflake.init,
			Nullable!Snowflake after = Nullable!Snowflake.init, int limit = 100) const @trusted
	{
		auto route = endpoint ~ "/messages";
		string query = "?limit=" ~ limit.to!string;
		if (!before.isNull)
			query ~= "&before=" ~ before.get.toString;
		if (!after.isNull)
			query ~= "&after=" ~ after.get.toString;
		string path = route ~ "/" ~ message.toString ~ "/reactions/" ~ emoji.toAPIString ~ query;
		return requestDiscordEndpoint(path, route, (scope req) {
			if (requester)
				requester(req);
			req.method = HTTPMethod.GET;
			req.writeBody(null, null);
		}).deserializeJson!(User[]);
	}

	@(Permissions.MANAGE_MESSAGES)
	void clearReactions(Snowflake message) const @trusted
	{
		auto route = endpoint ~ "/messages";
		string path = route ~ "/" ~ message.toString ~ "/reactions";
		requestDiscordEndpoint(path, route, (scope req) {
			if (requester)
				requester(req);
			req.method = HTTPMethod.DELETE;
			req.writeBody(null, null);
		});
	}

	@(Permissions.MANAGE_ROLES)
	void editChannelPermissions(Snowflake overwrite, uint allow, uint deny, string type) const @trusted
	{
		auto route = endpoint ~ "/permissions";
		string path = route ~ "/" ~ overwrite.toString;
		requestDiscordEndpoint(path, route, (scope req) {
			if (requester)
				requester(req);
			req.method = HTTPMethod.PUT;
			Json json = Json.emptyObject;
			json["allow"] = Json(allow);
			json["deny"] = Json(deny);
			json["type"] = Json(type);
			req.writeJsonBody(json);
		});
	}

	@(Permissions.MANAGE_ROLES)
	void deleteChannelPermissions(Snowflake overwrite) const @trusted
	{
		auto route = endpoint ~ "/permissions";
		string path = route ~ "/" ~ overwrite.toString;
		requestDiscordEndpoint(path, route, (scope req) {
			if (requester)
				requester(req);
			req.method = HTTPMethod.DELETE;
			req.writeBody(null, null);
		});
	}

	@(Permissions.MANAGE_CHANNELS)
	Invite[] getInvites() const @trusted
	{
		auto route = endpoint ~ "/invites";
		return requestDiscordEndpoint(route, route, (scope req) {
			if (requester)
				requester(req);
			req.method = HTTPMethod.GET;
			req.writeBody(null, null);
		}).deserializeJson!(Invite[]);
	}

	@(Permissions.CREATE_INSTANT_INVITE)
	Invite createInvite(Duration maxAge = 24.hours, int maxUses = 0,
			bool temporary = false, bool unique = false) const @trusted
	{
		auto route = endpoint ~ "/invites";
		return requestDiscordEndpoint(route, route, (scope req) {
			if (requester)
				requester(req);
			req.method = HTTPMethod.POST;
			Json json;
			if (maxAge != 24.hours)
				json["max_age"] = Json(maxAge.total!"seconds");
			if (maxUses)
				json["max_uses"] = Json(maxUses);
			if (temporary)
				json["temporary"] = Json(temporary);
			if (unique)
				json["unique"] = Json(unique);
			req.writeJsonBody(json);
		}).deserializeJson!Invite;
	}

	void triggerTypingIndicator() const @trusted
	{
		auto route = endpoint ~ "/typing";
		requestDiscordEndpoint(route, route, (scope req) {
			if (requester)
				requester(req);
			req.method = HTTPMethod.POST;
			req.writeBody(null, null);
		});
	}

	Message[] getPinnedMessages() const @trusted
	{
		auto route = endpoint ~ "/pins";
		return requestDiscordEndpoint(route, route, (scope req) {
			if (requester)
				requester(req);
			req.method = HTTPMethod.GET;
			req.writeBody(null, null);
		}).deserializeJson!(Message[]);
	}

	@(Permissions.MANAGE_MESSAGES)
	void pinMessage(Snowflake id) const @trusted
	{
		auto route = endpoint ~ "/pins";
		requestDiscordEndpoint(route ~ "/" ~ id.toString, route, (scope req) {
			if (requester)
				requester(req);
			req.method = HTTPMethod.PUT;
			req.writeBody(null, null);
		});
	}

	@(Permissions.MANAGE_MESSAGES)
	void unpinMessage(Snowflake id) const @trusted
	{
		auto route = endpoint ~ "/pins";
		requestDiscordEndpoint(route ~ "/" ~ id.toString, route, (scope req) {
			if (requester)
				requester(req);
			req.method = HTTPMethod.DELETE;
			req.writeBody(null, null);
		});
	}

	void addToGroupDM(Snowflake user) const @trusted
	{
		auto route = endpoint ~ "/recipients";
		requestDiscordEndpoint(route ~ "/" ~ user.toString, route, (scope req) {
			if (requester)
				requester(req);
			req.method = HTTPMethod.PUT;
			req.writeBody(null, null);
		});
	}

	void removeFromGroupDM(Snowflake user) const @trusted
	{
		auto route = endpoint ~ "/recipients";
		requestDiscordEndpoint(route ~ "/" ~ user.toString, route, (scope req) {
			if (requester)
				requester(req);
			req.method = HTTPMethod.DELETE;
			req.writeBody(null, null);
		});
	}
}
