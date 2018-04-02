module discord.w.types;

import std.algorithm;
import std.conv;
import std.datetime;
import std.string;
import std.typecons;
import std.utf;

import discord.w.minietf;
import discord.w.json;

import vibe.data.json;
import vibe.inet.url;

alias SafeTime = Nullable!SysTime;

enum DiscordCDN = "https://cdn.discordapp.com/";

/// typesafe alias to ulong
struct Snowflake
{
	private ulong id;

	this(ulong id) @safe
	{
		this.id = id;
	}

	void erlpack(ref ETFBuffer buffer)
	{
		buffer.putULong(id);
	}

	static Snowflake erlunpack(ref ETFBuffer buffer)
	{
		if (buffer.peek(1)[0] == ETFHeader.binaryExt)
			return Snowflake((cast(string) buffer.readBinary()).to!ulong);
		return Snowflake(buffer.readULong);
	}

	Json toJson() const @safe
	{
		return Json(id.to!string);
	}

	static Snowflake fromJson(Json src) @safe
	{
		return Snowflake(src.get!string.to!ulong);
	}

	string toString() const @safe
	{
		return id.to!string;
	}

	static Snowflake fromString(string src) @safe
	{
		return Snowflake(src.to!ulong);
	}
}

/// https://discordapp.com/developers/docs/topics/permissions
enum Permissions : uint
{
	CREATE_INSTANT_INVITE = 0x00000001, /// Allows creation of instant invites	T, V
	KICK_MEMBERS = 0x00000002, /// Allows kicking members	
	BAN_MEMBERS = 0x00000004, /// Allows banning members	
	ADMINISTRATOR = 0x00000008, /// Allows all permissions and bypasses channel permission overwrites	
	MANAGE_CHANNELS = 0x00000010, /// Allows management and editing of channels	T, V
	MANAGE_GUILD = 0x00000020, /// Allows management and editing of the guild	
	ADD_REACTIONS = 0x00000040, /// Allows for the addition of reactions to messages	T
	VIEW_AUDIT_LOG = 0x00000080, /// Allows for viewing of audit logs	
	VIEW_CHANNEL = 0x00000400, /// Allows guild members to view a channel, which includes reading messages in text channels	T, V
	SEND_MESSAGES = 0x00000800, /// Allows for sending messages in a channel	T
	SEND_TTS_MESSAGES = 0x00001000, /// Allows for sending of /tts messages	T
	MANAGE_MESSAGES = 0x00002000, /// Allows for deletion of other users messages	T
	EMBED_LINKS = 0x00004000, /// Links sent by users with this permission will be auto-embedded	T
	ATTACH_FILES = 0x00008000, /// Allows for uploading images and files	T
	READ_MESSAGE_HISTORY = 0x00010000, /// Allows for reading of message history	T
	MENTION_EVERYONE = 0x00020000, /// Allows for using the @everyone tag to notify all users in a channel, and the @here tag to notify all online users in a channel	T
	USE_EXTERNAL_EMOJIS = 0x00040000, /// Allows the usage of custom emojis from other servers	T
	CONNECT = 0x00100000, /// Allows for joining of a voice channel	V
	SPEAK = 0x00200000, /// Allows for speaking in a voice channel	V
	MUTE_MEMBERS = 0x00400000, /// Allows for muting members in a voice channel	V
	DEAFEN_MEMBERS = 0x00800000, /// Allows for deafening of members in a voice channel	V
	MOVE_MEMBERS = 0x01000000, /// Allows for moving of members between voice channels	V
	USE_VAD = 0x02000000, /// Allows for using voice-activity-detection in a voice channel	V
	CHANGE_NICKNAME = 0x04000000, /// Allows for modification of own nickname	
	MANAGE_NICKNAMES = 0x08000000, /// Allows for modification of other users nicknames	
	MANAGE_ROLES = 0x10000000, /// Allows management and editing of roles	T, V
	MANAGE_WEBHOOKS = 0x20000000, /// Allows management and editing of webhooks	T, V
	MANAGE_EMOJIS = 0x40000000, /// Allows management and editing of emojis	
}

/// https://discordapp.com/developers/docs/resources/user#user-object
struct User
{
	mixin OptionalSerializer!(typeof(this));

	Snowflake id;
	string username;
	string discriminator;
	Nullable!string avatar;
	@optional bool bot;
	@optional bool mfa_enabled;
	@optional bool verified;
	@optional Nullable!string email;

	URL avatarURL(string format = "png") const @safe
	{
		if (avatar.isNull)
			return URL(DiscordCDN ~ "embed/avatars/" ~ (discriminator.to!int % 5).to!string ~ ".png");
		else
			return URL(DiscordCDN ~ "avatars/" ~ id.toString ~ "/" ~ avatar.get ~ "." ~ format);
	}
}

struct PartialUser
{
	mixin OptionalSerializer!(typeof(this));

	Snowflake id;
}

/// https://discordapp.com/developers/docs/resources/channel#channel-object
struct Channel
{
	mixin OptionalSerializer!(typeof(this));

	enum Type
	{
		guildText,
		dm,
		guildVoice,
		groupDM,
		guildCategory
	}

	Snowflake id;
	Type type;
	@optional Snowflake guild_id;
	@optional int position;
	@optional Overwrite[] permission_overwrites;
	@optional Nullable!string name;
	@optional Nullable!string topic;
	@optional bool nsfw;
	@optional Nullable!string last_message_id;
	@optional int bitrate;
	@optional int user_limit;
	@optional User[] recipients;
	@optional Nullable!string icon;
	@optional Snowflake owner_id;
	@optional Snowflake application_id;
	@optional Nullable!Snowflake parent_id;
	@optional SafeTime last_pin_timestamp;
}

/// https://discordapp.com/developers/docs/resources/channel#overwrite-object
struct Overwrite
{
	mixin OptionalSerializer!(typeof(this));

	enum Type : Atom
	{
		role = atom("role"),
		member = atom("member")
	}

	Snowflake id;
	Type type;
	uint allow;
	uint deny;
}

/// https://discordapp.com/developers/docs/resources/guild#unavailable-guild-object
struct UnavailableGuild
{
	mixin OptionalSerializer!(typeof(this));

	Snowflake id;
	@optional bool unavailable;
}

/// https://discordapp.com/developers/docs/resources/guild#guild-object-verification-level
enum VerificationLevel
{
	none, ///
	low, /// verified email
	medium, /// 5 minute registration
	high, /// 10 minute server member
	veryHigh /// verified phone number
}

/// https://discordapp.com/developers/docs/resources/guild#guild-object-default-message-notification-level
enum MessageNotificationLevel
{
	allMessages,
	onlyMentions
}

/// https://discordapp.com/developers/docs/resources/guild#guild-object-explicit-content-filter-level
enum ExplicitContentFilterLevel
{
	disabled,
	membersWithoutRoles,
	allMembers
}

/// https://discordapp.com/developers/docs/resources/guild#guild-object-mfa-level
enum MFALevel
{
	none,
	elevated
}

/// https://discordapp.com/developers/docs/topics/permissions#role-object
struct Role
{
	mixin OptionalSerializer!(typeof(this));

	Snowflake id;
	string name;
	int color;
	bool hoist;
	int position;
	uint permissions;
	bool managed;
	bool mentionable;
}

/// https://discordapp.com/developers/docs/resources/emoji#emoji-object
struct Emoji
{
	mixin OptionalSerializer!(typeof(this));

	static Emoji builtin(string emoji) @safe
	{
		Emoji ret;
		ret.name = emoji;
		return ret;
	}

	static Emoji named(Snowflake id, string name, bool animated = false) @safe
	{
		Emoji ret;
		ret.id = id;
		ret.name = name;
		ret.animated = animated;
		return ret;
	}

	string toAPIString() @safe
	{
		import std.uri : encodeComponent;

		if (id.isNull)
			return (() @trusted => encodeComponent(name))();
		else
		{
			auto s = name ~ ":" ~ id.get.toString;
			return (() @trusted => encodeComponent(s))();
		}
	}

	Nullable!Snowflake id;
	string name;
	@optional Snowflake[] roles;
	@optional User user;
	@optional bool require_colons;
	@optional bool managed;
	@optional bool animated;

	bool opEquals(in Emoji other) const @safe
	{
		if (!id.isNull && other.id.isNull && id == other.id)
			return true;
		if (id != other.id)
			return false;
		return name == other.name;
	}

	URL imageURL() const @safe
	{
		if (id.isNull) // TODO: replace with local URL
			return URL("https://cdnjs.cloudflare.com/ajax/libs/emojione/2.2.7/assets/png/" ~ name.byDchar.map!(
					a => (cast(ushort) a).to!string(16)).join('-') ~ ".png");
		if (animated)
			return URL(DiscordCDN ~ "emojis/" ~ id.get.toString ~ ".gif");
		else
			return URL(DiscordCDN ~ "emojis/" ~ id.get.toString ~ ".png");
	}
}

/// https://discordapp.com/developers/docs/resources/voice#voice-state-object
struct VoiceState
{
	mixin OptionalSerializer!(typeof(this));

	// must start with 3 snowflakes because of data.d!
	@optional Snowflake guild_id;
	Snowflake channel_id;
	Snowflake user_id;
	string session_id;
	bool deaf;
	bool mute;
	bool self_deaf;
	bool self_mute;
	bool suppress;
}

/// https://discordapp.com/developers/docs/resources/guild#guild-member-object
struct GuildMember
{
	mixin OptionalSerializer!(typeof(this));

	User user;
	@optional Nullable!string nick;
	Snowflake[] roles;
	SafeTime joined_at;
	bool deaf;
	bool mute;
}

/// https://discordapp.com/developers/docs/topics/gateway#activity-object
struct Activity
{
	mixin OptionalSerializer!(typeof(this));

	struct Timestamps
	{
		mixin OptionalSerializer!(typeof(this));

		long start, end;
	}

	struct Party
	{
		mixin OptionalSerializer!(typeof(this));

		string id;
		int[2] size;
	}

	struct Assets
	{
		mixin OptionalSerializer!(typeof(this));

		string large_image;
		string large_text;
		string small_image;
		string small_text;
	}

	enum Type : int
	{
		game,
		streaming,
		listening
	}

	string name;
	Type type;
	@optional Nullable!string url;
	@optional Timestamps timestamps;
	@optional Snowflake application_id;
	@optional Nullable!string details;
	@optional Nullable!string state;
	@optional Party party;
	@optional Assets assets;
}

struct UpdateStatus
{
	mixin OptionalSerializer!(typeof(this));

	enum StatusType : Atom
	{
		online = atom("online"),
		dnd = atom("dnd"),
		idle = atom("idle"),
		invisible = atom("invisible"),
		offline = atom("offline")
	}

	Nullable!long since;
	Nullable!Activity game;
	StatusType status;
	bool afk;
}

unittest
{
	UpdateStatus u;
	u.status = UpdateStatus.StatusType.online;
	u.afk = false;
	u.game = Activity.init;
	u.game.name = "Bob";
	assert(serializeToJson(u) == Json(["since" : Json(null), "status"
			: Json("online"), "afk" : Json(false), "game" : Json(["name" : Json("Bob"), "type" : Json(0)])]));
}

/// https://discordapp.com/developers/docs/topics/gateway#presence-update
struct PresenceUpdate
{
	mixin OptionalSerializer!(typeof(this));

	enum Status : Atom
	{
		idle = atom("idle"),
		dnd = atom("dnd"),
		online = atom("online"),
		offline = atom("offline")
	}

	PartialUser user;
	Snowflake[] roles;
	Activity game;
	Snowflake guild_id;
	Status status;
}

/// https://discordapp.com/developers/docs/resources/guild#guild-object
struct Guild
{
	mixin OptionalSerializer!(typeof(this));

	Snowflake id;
	string name;
	Nullable!string icon;
	Nullable!string splash;
	@optional bool owner;
	Snowflake owner_id;
	@optional uint permissions;
	string region;
	Snowflake afk_channel_id;
	int afk_timeout;
	@optional bool embed_enabled;
	@optional Snowflake embed_channel_id;
	VerificationLevel verification_level;
	MessageNotificationLevel default_message_notifications;
	ExplicitContentFilterLevel explicit_content_filter;
	Role[] roles;
	Emoji[] emojis;
	string[] features;
	MFALevel mfa_level;
	Nullable!Snowflake application_id;
	@optional bool widget_enabled;
	@optional Snowflake widget_channel_id;
	@optional Nullable!Snowflake system_channel_id;
	@optional SafeTime joined_at;
	@optional bool large;
	@optional bool unavailable;
	@optional int member_count;
	@optional VoiceState[] voice_states;
	@optional GuildMember[] members;
	@optional Channel[] channels;
	@optional PresenceUpdate[] presences;

	URL iconURL(string format = "png")() const @safe 
			if (format == "png" || format == "jpg" || format == "jpeg" || format == "webp")
	{
		if (icon.isNull)
			return URL.init;
		return URL(DiscordCDN ~ "icons/" ~ id.toString ~ "/" ~ icon.get ~ "." ~ format);
	}

	URL splashURL(string format = "png")() const @safe 
			if (format == "png" || format == "jpg" || format == "jpeg" || format == "webp")
	{
		if (splash.isNull)
			return URL.init;
		return URL(DiscordCDN ~ "splashes/" ~ id.toString ~ "/" ~ splash.get ~ "." ~ format);
	}
}

/// https://discordapp.com/developers/docs/resources/channel#attachment-object
struct Attachment
{
	mixin OptionalSerializer!(typeof(this));

	Snowflake id;
	string filename;
	long size;
	string url;
	string proxy_url;
	Nullable!uint height;
	Nullable!uint width;
}

/// https://discordapp.com/developers/docs/resources/channel#embed-object
struct Embed
{
	mixin OptionalSerializer!(typeof(this));

@optional: // not in the docs

	struct Thumbnail
	{
		mixin OptionalSerializer!(typeof(this));

	@optional: // not in the docs

		string url;
		string proxy_url;
		int height;
		int width;
	}

	struct Video
	{
		mixin OptionalSerializer!(typeof(this));

	@optional: // not in the docs

		string url;
		int height;
		int width;
	}

	struct Image
	{
		mixin OptionalSerializer!(typeof(this));

	@optional: // not in the docs

		string url;
		string proxy_url;
		int height;
		int width;
	}

	struct Provider
	{
		mixin OptionalSerializer!(typeof(this));

	@optional: // not in the docs

		string name;
		string url;
	}

	struct Author
	{
		mixin OptionalSerializer!(typeof(this));

	@optional: // not in the docs

		string name;
		string url;
		string icon_url;
		string proxy_icon_url;
	}

	struct Footer
	{
		mixin OptionalSerializer!(typeof(this));

	@optional: // not in the docs

		string text;
		string icon_url;
		string proxy_icon_url;
	}

	struct Field
	{
		mixin OptionalSerializer!(typeof(this));

	@optional: // not in the docs

		string name;
		string value;
		bool inline;
	}

	string title;
	string type;
	string description;
	string url;
	SafeTime timestamp;
	Nullable!int color;
	Footer footer;
	Image image;
	Thumbnail thumbnail;
	Video video;
	Provider provider;
	Author author;
	Field[] fields;
}

/// https://discordapp.com/developers/docs/resources/guild#guild-embed-object
struct GuildEmbed
{
	mixin OptionalSerializer!(typeof(this));

	bool enabled;
	Nullable!Snowflake channel_id;
}

/// https://discordapp.com/developers/docs/resources/channel#reaction-object
struct Reaction
{
	mixin OptionalSerializer!(typeof(this));

	int count;
	bool me;
	Emoji emoji;

	// custom:
	@ignore Snowflake[] users;
}

/// https://discordapp.com/developers/docs/resources/channel#message-object
struct Message
{
	mixin OptionalSerializer!(typeof(this));

	enum Type
	{
		default_,
		recipientAdd,
		recipientRemove,
		call,
		channelNameChange,
		channelIconChange,
		channelPinnedMessage,
		guildMemberJoin
	}

	Snowflake id;
	Snowflake channel_id;
	User author;
	string content;
	SafeTime timestamp;
	SafeTime edited_timestamp;
	bool tts;
	bool mention_everyone;
	User[] mentions;
	Snowflake[] mention_roles;
	Attachment[] attachments;
	Embed[] embeds;
	@optional Reaction[] reactions;
	@optional Nullable!Snowflake nonce;
	bool pinned;
	@optional Snowflake webhook_id;
	Type type;
	@optional Activity activity;
}

struct ApplicationInformation
{
	mixin OptionalSerializer!(typeof(this));

	Snowflake id;
	string name;
	@optional Nullable!string icon;
	@optional Nullable!string description;
	@optional Nullable!string[] rpc_origins;
	bool bot_public;
	bool bot_require_code_grant;
	User owner;

	URL iconURL(string format = "png")() const @safe 
			if (format == "png" || format == "jpg" || format == "jpeg" || format == "webp")
	{
		if (!icon.length)
			return URL.init;
		return URL(DiscordCDN ~ "app-icons/" ~ id.toString ~ "/" ~ icon ~ "." ~ format);
	}
}

/// https://discordapp.com/developers/docs/resources/invite#invite-object
struct Invite
{
	mixin OptionalSerializer!(typeof(this));

	struct Guild
	{
		mixin OptionalSerializer!(typeof(this));

		Snowflake id;
		string name;
		Nullable!string icon;
		Nullable!string splash;
	}

	struct Channel
	{
		mixin OptionalSerializer!(typeof(this));

		Snowflake id;
		.Channel.Type type;
		@optional Nullable!string name;
	}

	struct InviteMetadata
	{
		mixin OptionalSerializer!(typeof(this));

		User inviter;
		int uses;
		int max_uses;
		int max_age;
		bool temporary;
		SafeTime created_at;
		bool revoked;
	}

	string code;
	Guild guild;
	Channel channel;
	@optional InviteMetadata metadata;
}

/// https://discordapp.com/developers/docs/resources/guild#ban-object
struct Ban
{
	mixin OptionalSerializer!(typeof(this));

	Nullable!string reason;
	User user;
}

/// https://discordapp.com/developers/docs/resources/guild#integration-object
struct Integration
{
	/// https://discordapp.com/developers/docs/resources/guild#integration-account-object
	struct Account
	{
		mixin OptionalSerializer!(typeof(this));

		string id;
		string name;
	}

	mixin OptionalSerializer!(typeof(this));

	Snowflake id;
	string name;
	string type;
	bool enabled;
	bool syncing;
	Snowflake role_id;
	int expire_behavior;
	int expire_grace_period;
	User user;
	Account account;
	SafeTime synced_at;
}

// https://discordapp.com/developers/docs/resources/voice#voice-region-object
struct VoiceRegion
{
	mixin OptionalSerializer!(typeof(this));

	string id;
	string name;
	bool vip;
	bool optimal;
	bool deprecated_;
	bool custom;
}
