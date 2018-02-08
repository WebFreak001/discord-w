module discord.w.minietf;

import std.bigint;
import std.bitmanip;
import std.conv;
import std.datetime;
import std.math;
import std.meta;
import std.range;
import std.traits;
import std.typecons;
import std.utf;
import std.variant;

import vibe.core.log;

class BufferResizeAttemptException : Exception
{
	this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @nogc @safe
	{
		super(msg, file, line);
	}
}

enum ETFHeader : ubyte
{
	// see https://github.com/discordapp/erlpack
	// and http://erlang.org/doc/apps/erts/erl_ext_dist.html

	formatVersion = 131, /// first byte of buffer
	newFloatExt = 'F', /// 70  [Float64:IEEE float]
	bitBinaryExt = 'M', /// 77  [UInt32:Len, UInt8:Bits, Len:Data]
	smallIntegerExt = 'a', /// 97  [UInt8:Int]
	integerExt = 'b', /// 98  [Int32:Int]
	floatExt = 'c', /// 99  [31:Float String] Float in string format (formatted "%.20e", sscanf "%lf"). Superseded by newFloatExt
	atomExt = 'd', /// 100 [UInt16:Len, Len:AtomName] max Len is 255
	referenceExt = 'e', /// 101 [atom:Node, UInt32:ID, UInt8:Creation]
	portExt = 'f', /// 102 [atom:Node, UInt32:ID, UInt8:Creation]
	pidExt = 'g', /// 103 [atom:Node, UInt32:ID, UInt32:Serial, UInt8:Creation]
	smallTupleExt = 'h', /// 104 [UInt8:Arity, N:Elements]
	largeTupleExt = 'i', /// 105 [UInt32:Arity, N:Elements]
	nilExt = 'j', /// 106 empty list
	stringExt = 'k', /// 107 [UInt16:Len, Len:Characters]
	listExt = 'l', /// 108 [UInt32:Len, Elements, Tail]
	binaryExt = 'm', /// 109 [UInt32:Len, Len:Data]
	smallBigExt = 'n', /// 110 [UInt8:n, UInt8:Sign, n:nums]
	largeBigExt = 'o', /// 111 [UInt32:n, UInt8:Sign, n:nums]
	newFunExt = 'p', /// 112 [UInt32:Size, UInt8:Arity, 16*Uint6-MD5:Uniq, UInt32:Index, UInt32:NumFree, atom:Module, int:OldIndex, int:OldUniq, pid:Pid, NunFree*ext:FreeVars]
	exportExt = 'q', /// 113 [atom:Module, atom:Function, smallint:Arity]
	newReferenceExt = 'r', /// 114 [UInt16:Len, atom:Node, UInt8:Creation, Len*UInt32:ID]
	smallAtomExt = 's', /// 115 [UInt8:Len, Len:AtomName]
	mapExt = 't', /// 116 [UInt32:Airty, N:Pairs]
	funExt = 'u', /// 117 [UInt4:NumFree, pid:Pid, atom:Module, int:Index, int:Uniq, NumFree*ext:FreeVars]
	atomUTF8Ext = 'v', /// 118 [UInt16:Len, Len:AtomName (UTF-8)]
	smallAtomUTF8Ext = 'w', /// 119 [UInt8:Len, Len:AtomName (UTF-8)]
	compressed = 'P', /// 80  [UInt4:UncompressedSize, N:ZlibCompressedData]
}

/// typesafe alias for Atom
enum Atom : string
{
	empty = ""
}

Atom atom(string s) @safe
{
	return cast(Atom) s;
}

struct EncodeFunc
{
	string func;
}

EncodeFunc encodeFunc(string func)
{
	return EncodeFunc(func);
}

struct DecodeFunc
{
	string func;
}

DecodeFunc decodeFunc(string func)
{
	return DecodeFunc(func);
}

struct EncodeName
{
	string name;
}

EncodeName encodeName(string name)
{
	return EncodeName(name);
}

struct KeyValuePair(K, V)
{
	K key;
	V value;
}

template isKeyValueArray(T)
{
	enum isKeyValueArray = is(T : KeyValuePair!(K, V), K, V);
}

KeyValuePair!(K, V) kv(K, V)(K key, V value)
{
	return KeyValuePair!(K, V)(key, value);
}

struct ETFBuffer
{
	// unused if allowResize is true
	ubyte[] full;
	ubyte[] buffer;
	size_t index;
	bool allowResize;

	inout(ubyte[]) bytes() inout @property @safe
	{
		return buffer;
	}

	void put(T)(auto ref T data)
	{
		unsafeReserveBuffer(data.length);
		putUnsafe(data);
	}

	void unsafeReserveBuffer(size_t extra)
	{
		assert(buffer.length == index, "buffer length mismatch (finish putUnsafe before call)");
		if (allowResize)
			buffer.length += extra;
		else
		{
			if (buffer.length + extra > full.length)
				throw new BufferResizeAttemptException("Buffer resize attempt");
			buffer = full[0 .. buffer.length + extra];
		}
	}

	void putUnsafe(T)(auto ref T data)
	{
		assert(index + data.length <= buffer.length,
				"invalid putUnsafe call (call unsafeReserveBuffer first)");
		buffer[index .. index += data.length] = data;
	}

	inout(ubyte[]) peek(size_t n, size_t offset = 0) inout
	{
		if (offset + n > buffer.length)
			throw new Exception("Attempted to peek over buffer length");
		return buffer[offset .. offset + n];
	}

	ubyte[] read(size_t n)
	{
		if (n > buffer.length)
			throw new Exception("Attempted to read over buffer length");
		auto ret = buffer[0 .. n];
		buffer = buffer[n .. $];
		return ret;
	}

	void putVersion()
	{
		put([cast(ubyte) ETFHeader.formatVersion]);
	}

	void readVersion()
	{
		auto header = cast(ETFHeader) peek(1)[0];
		if (header != cast(ubyte) ETFHeader.formatVersion)
			throw new Exception("Expected ETF header but got " ~ header.to!string);
		read(1);
	}

	void putBool(bool value)
	{
		if (value)
			put(cast(ubyte[])[cast(ubyte) ETFHeader.smallAtomExt, 4, 't', 'r', 'u', 'e']);
		else
			put(cast(ubyte[])[cast(ubyte) ETFHeader.smallAtomExt, 5, 'f', 'a', 'l', 's', 'e']);
	}

	bool readBool()
	{
		auto saved = buffer;
		scope (failure)
			buffer = saved; // PogChamp

		auto a = readAtom();

		if (a != atom("true") && a != atom("false"))
			throw new Exception("Expected boolean atom but got " ~ cast(string) a);

		return a == atom("true");
	}

	void putNull()
	{
		put(cast(ubyte[])[cast(ubyte) ETFHeader.smallAtomExt, 3, 'n', 'i', 'l']);
	}

	auto readNull()
	{
		auto header = cast(ETFHeader) peek(1)[0];

		if (header == ETFHeader.nilExt)
		{
			read(1);
			return null;
		}
		auto saved = buffer;
		scope (failure)
			buffer = saved; // PogChamp

		auto a = readAtom();
		if (a != "nil")
			throw new Exception("Expected nil atom but got " ~ cast(string) a);
		return null;
	}

	void putEmptyList()
	{
		put([cast(ubyte) ETFHeader.nilExt]);
	}

	auto readEmptyList()
	{
		return readNull();
	}

	void putByte(ubyte v)
	{
		put([cast(ubyte) ETFHeader.smallIntegerExt, v]);
	}

	ubyte readByte()
	{
		auto header = cast(ETFHeader) peek(1)[0];
		if (header == ETFHeader.smallIntegerExt)
			return read(2)[1];
		else
			return cast(ubyte) readInt();
	}

	void putInt(int v)
	{
		ubyte[1 + 4] data;
		data[0] = cast(ubyte) ETFHeader.integerExt;
		data[1 .. 5] = nativeToBigEndian(v);
		put(data[]);
	}

	int readInt()
	{
		auto header = cast(ETFHeader) peek(1)[0];
		if (header == ETFHeader.smallIntegerExt)
			return readByte();
		else if (header == ETFHeader.integerExt)
			return read(5)[1 .. 5].bigEndianToNative!int;
		else
			return cast(int) readLong();
	}

	void putULong(ulong v)
	{
		ubyte[1 + 2 + ulong.sizeof] data;
		data[0] = cast(ubyte) ETFHeader.smallBigExt;
		ubyte len;
		while (v > 0)
		{
			data[3 + len] = v & 0xFF;
			v >>= 8;
			len++;
		}
		data[1] = len;
		put(data[0 .. 1 + 2 + len]);
	}

	ulong readULong()
	{
		auto header = cast(ETFHeader) peek(1)[0];
		if (header == ETFHeader.integerExt || header == ETFHeader.smallIntegerExt)
			return cast(long) readInt();
		static if (is(typeof(readBigInt)))
			if (header == ETFHeader.largeBigExt)
				return readBigInt().toLong;
		if (header != ETFHeader.smallBigExt)
			throw new Exception("Expected smallBigExt header + 1 byte length but got " ~ header
					.to!string);
		auto info = peek(2, 1);
		if (info[0] > 8)
			throw new Exception("Can't read more than 8 bytes into a ulong");
		if (info[1] == 1)
			throw new Exception("Received negative bignum when reading ulong");
		auto data = read(3 + info[0])[3 .. $];
		ulong ret;
		foreach (i, b; data)
			ret |= (cast(ulong) b) << (8UL * i);
		return ret;
	}

	void putLong(long v)
	{
		ubyte[1 + 2 + ulong.sizeof] data;
		data[0] = cast(ubyte) ETFHeader.smallBigExt;
		if (v < 0)
		{
			data[2] = 1;
			v = -v;
		}
		ubyte len;
		while (v > 0)
		{
			data[3 + len] = v & 0xFF;
			v >>= 8;
			len++;
		}
		data[1] = len;
		put(data[0 .. 1 + 2 + len]);
	}

	long readLong()
	{
		auto header = cast(ETFHeader) peek(1)[0];
		if (header == ETFHeader.integerExt || header == ETFHeader.smallIntegerExt)
			return cast(long) readInt();
		static if (is(typeof(readBigInt)))
			if (header == ETFHeader.largeBigExt)
				return readBigInt().toLong;
		if (header != ETFHeader.smallBigExt)
			throw new Exception("Expected smallBigExt header + 1 byte length but got " ~ header
					.to!string);
		auto info = peek(2, 1);
		if (info[1] > 8)
			throw new Exception("Can't read more than 8 bytes into a long");
		bool negative = info[1] == 1;
		auto data = read(3 + info[0])[3 .. $];
		long ret;
		foreach (i, b; data)
			ret |= (cast(long) b) << (8UL * i);
		return negative ? -ret : ret;
	}

	static if (is(typeof(BigInt.init.getDigit)))
	{
		void putBigInt(BigInt v)
		{
			auto l = v.ulongLength;
			assert(l > 0);
			auto lastDigit = v.getDigit(l - 1);
			ubyte bytesInLastBlock = lastDigit == 0 ? 1
				: 8 - lastDigit.nativeToBigEndian.countUntil!(a => a != 0);
			auto len = (l - 1) * 8 + bytesInLastBlock;
			ubyte sign = v.isNegative ? 1 : 0;
			if (len <= ubyte.max)
			{
				unsafeReserveBuffer(3 + len);
				putUnsafe([cast(ubyte) ETFHeader.smallBigExt, cast(ubyte) len, sign]);
			}
			else
			{
				if (len > uint.max)
					throw new Exception("BigInt too large");
				unsafeReserveBuffer(6 + len);
				ubyte[6] header;
				header[0] = cast(ubyte) ETFHeader.largeBigExt;
				header[1 .. 5] = nativeToBigEndian(cast(uint) len);
				header[5] = sign;
				putUnsafe(header);
			}
			foreach (i; 0 .. l - 1)
				putUnsafe(nativeToLittleEndian(v.getDigit(i)));
			ubyte[8] last = nativeToLittleEndian(v.getDigit(l - 1));
			putUnsafe(last[0 .. 8 - bytesInLastBlock]);
		}

		BigInt readBigInt()
		{
			auto header = cast(ETFHeader) peek(1)[0];
			if (header == ETFHeader.integerExt)
				return cast(long) readInt();
			static if (is(typeof(readBigInt)))
				if (header == ETFHeader.largeBigExt)
					return readBigInt().toLong;
			if (header != ETFHeader.smallBigExt)
				throw new Exception(
						"Expected smallBigExt header + 1 byte length but got " ~ header.to!string);
			auto info = peek(2, 1);
			if (info[1] > 8)
				throw new Exception("Can't read more than 8 bytes into a long");
			auto data = read(3 + info[1])[3 .. $];
			char[] str = new char[info[0] + 2 + data.length * 2];
			size_t i;
			if (info[0] == 1)
				str[i++] = '-';
			str[i++] = '0';
			str[i++] = 'x';

			char toHexChar(ubyte b)
			{
				if (b >= 0 && b <= 9)
					return '0' + b;
				else
					return 'a' - 10 + b;
			}

			foreach (i, b; data)
			{
				str[$ - (i + 1) * 2] = toHexChar(b & 0xF);
				str[$ - (i + 1) * 2 + 1] = toHexChar((b >> 4) & 0xF);
			}
			return BigInt(data);
		}
	}

	void putDouble(double d)
	{
		ubyte[1 + 8] data;
		data[0] = cast(ubyte) ETFHeader.newFloatExt;
		data[1 .. 9] = nativeToBigEndian(d);
		put(data[]);
	}

	double readDouble()
	{
		auto header = cast(ETFHeader) peek(1)[0];
		if (header != ETFHeader.newFloatExt)
			throw new Exception("Expected newFloatExt header but got " ~ header.to!string);

		return read(9)[1 .. 9].bigEndianToNative!double;
	}

	void putAtom(Atom atom)
	{
		if (atom.length <= ubyte.max)
		{
			unsafeReserveBuffer(2 + atom.length);
			putUnsafe([cast(ubyte) ETFHeader.smallAtomExt, cast(ubyte) atom.length]);
			putUnsafe(cast(ubyte[]) atom);
		}
		else
		{
			if (atom.length > ushort.max)
				throw new Exception("Attempted to put too long atom");
			unsafeReserveBuffer(3 + atom.length);
			putUnsafe([cast(ubyte) ETFHeader.atomExt]);
			putUnsafe(nativeToBigEndian(cast(ushort) atom.length));
			putUnsafe(cast(ubyte[]) atom);
		}
	}

	Atom readAtom()
	{
		auto header = cast(ETFHeader) peek(1)[0];
		if (header == ETFHeader.smallAtomUTF8Ext || header == ETFHeader.smallAtomExt)
		{
			auto len = peek(1, 1)[0];
			return cast(Atom) read(2 + len)[2 .. $].idup;
		}
		else if (header == ETFHeader.atomUTF8Ext || header == ETFHeader.atomExt)
		{
			auto len = peek(2, 1)[0 .. 2].bigEndianToNative!ushort;
			return cast(Atom) read(3 + len)[3 .. $].idup;
		}
		else if (header == ETFHeader.binaryExt)
			return cast(Atom) readBinary;
		else if (header == ETFHeader.stringExt)
			return cast(Atom) readString;
		else if (header == ETFHeader.nilExt)
			return cast(Atom) null;
		else
			throw new Exception("Expected atom header + length but got " ~ header.to!string);
	}

	void putBinary(ubyte[] data)
	{
		unsafeReserveBuffer(5 + data.length);
		putUnsafe([cast(ubyte) ETFHeader.binaryExt]);
		putUnsafe(nativeToBigEndian(cast(uint) data.length));
		putUnsafe(data);
	}

	ubyte[] readBinaryUnsafe()
	{
		auto header = cast(ETFHeader) peek(1)[0];
		if (header == ETFHeader.binaryExt)
		{
			auto len = peek(4, 1)[0 .. 4].bigEndianToNative!uint;
			return read(5 + len)[5 .. $];
		}
		else if (header == ETFHeader.stringExt)
			return readString();
		else if (header == ETFHeader.atomExt || header == ETFHeader.atomUTF8Ext
				|| header == ETFHeader.smallAtomExt || header == ETFHeader.smallAtomUTF8Ext)
			return cast(ubyte[]) readAtom();
		else if (header == ETFHeader.nilExt)
			return null;
		else
			throw new Exception("Expected binaryExt header but got " ~ header.to!string);
	}

	ubyte[] readBinary()
	{
		return readBinaryUnsafe.dup;
	}

	void putString(ubyte[] data)
	{
		unsafeReserveBuffer(3 + data.length);
		putUnsafe([cast(ubyte) ETFHeader.stringExt]);
		putUnsafe(nativeToBigEndian(cast(ushort) data.length));
		putUnsafe(data);
	}

	ubyte[] readString()
	{
		auto header = cast(ETFHeader) peek(1)[0];
		if (header == ETFHeader.stringExt)
		{
			auto len = peek(2, 1)[0 .. 2].bigEndianToNative!ushort;
			return read(3 + len)[3 .. $].dup;
		}
		else if (header == ETFHeader.atomExt || header == ETFHeader.atomUTF8Ext
				|| header == ETFHeader.smallAtomExt || header == ETFHeader.smallAtomUTF8Ext)
			return cast(ubyte[]) readAtom();
		else if (header == ETFHeader.binaryExt)
			return readBinary();
		else if (header == ETFHeader.nilExt)
			return null;
		else
			throw new Exception("Expected stringExt header but got " ~ header.to!string);
	}

	void startTuple(size_t length)
	{
		if (length <= ubyte.max)
		{
			put([cast(ubyte) ETFHeader.smallTupleExt, cast(ubyte) length]);
		}
		else
		{
			ubyte[1 + 4] data;
			data[0] = cast(ubyte) ETFHeader.largeTupleExt;
			data[1 .. 5] = nativeToBigEndian(cast(uint) length);
			put(data[]);
		}
	}

	size_t readTupleLength()
	{
		auto header = cast(ETFHeader) peek(1)[0];
		if (header == ETFHeader.smallTupleExt)
			return cast(size_t) read(2)[1];
		else if (header == ETFHeader.largeTupleExt)
			return read(5)[1 .. 5].bigEndianToNative!int;
		else
			throw new Exception("Expected tuple header but got " ~ header.to!string);
	}

	void startList(size_t length)
	{
		ubyte[1 + 4] data;
		data[0] = cast(ubyte) ETFHeader.listExt;
		data[1 .. 5] = nativeToBigEndian(cast(uint) length);
		put(data[]);
	}

	size_t readListLength(out bool needsNil)
	{
		auto header = cast(ETFHeader) peek(1)[0];
		needsNil = header == ETFHeader.listExt;
		if (header == ETFHeader.listExt || header == ETFHeader.largeTupleExt)
			return read(5)[1 .. 5].bigEndianToNative!int;
		else if (header == ETFHeader.smallTupleExt)
			return read(2)[1];
		else if (header == ETFHeader.nilExt)
		{
			read(1);
			return 0;
		}
		else
			throw new Exception("Expected listExt header but got " ~ header.to!string);
	}

	void startMap(size_t length)
	{
		ubyte[1 + 4] data;
		data[0] = cast(ubyte) ETFHeader.mapExt;
		data[1 .. 5] = nativeToBigEndian(cast(uint) length);
		put(data[]);
	}

	size_t readMapLength()
	{
		auto header = cast(ETFHeader) peek(1)[0];
		if (header == ETFHeader.mapExt)
			return read(5)[1 .. 5].bigEndianToNative!int;
		else
			throw new Exception("Expected mapExt header but got " ~ header.to!string);
	}

	alias EncodableSimpleTypes = AliasSeq!(Atom, bool, byte, ubyte, ubyte[],
			string, wstring, dstring, BigInt, short, ushort, int, uint, long, ulong,
			float, double, real, Variant[], Variant[Variant], Variant[string],
			KeyValuePair!(Variant, Variant)[], typeof(null), string[], int[],
			ulong[], SysTime, Nullable!SysTime);

	void encode(T)(T value)
	{
		static if (is(T == typeof(null)))
			putNull();
		else static if (is(T : Nullable!U, U))
		{
			if (value.isNull)
				putNull();
			else
				encode!U(value.get);
		}
		else static if (is(T : Atom))
			putAtom(value);
		else static if (is(T : bool))
			putBool(value);
		else static if (is(T == byte) || is(T == ubyte))
			putByte(cast(ubyte) value);
		else static if (is(T : ubyte[]))
			putBinary(value);
		else static if (is(T : SysTime))
			putBinary(cast(ubyte[]) value.toISOExtString);
		else static if (is(T : string))
			putBinary(cast(ubyte[]) value);
		else static if (is(T : wstring) || is(T : dstring))
			putBinary(cast(ubyte[]) value.toUTF8);
		else static if (isAssociativeArray!T)
		{
			startMap(value.length);
			foreach (ref key, ref item; value)
			{
				encode(key);
				encode(item);
			}
		}
		else static if (is(T : KeyValuePair!(K, V)[], K, V))
		{
			startMap(value.length);
			foreach (ref v; value)
			{
				encode(v.key);
				encode(v.value);
			}
		}
		else static if (isArray!T)
		{
			if (value.length)
				startList(value.length);
			static if (is(ElementType!T : void))
				assert(value.length == 0);
			else
				foreach (ref elem; value)
					encode(elem);
			putEmptyList();
		}
		else static if (is(T : Tuple!U, U...))
		{
			startTuple(value.expand.length);
			foreach (i, V; value.expand)
				encode(value[i]);
		}
		else static if (is(T : BigInt) && is(typeof(putBigInt)))
			putBigInt(value);
		else static if (isFloatingPoint!T)
			putDouble(cast(double) value);
		else static if (isIntegral!T)
		{
			if (value <= ubyte.max && value >= 0)
				putByte(cast(ubyte) value);
			else if (value <= int.max && value >= int.min)
				putInt(cast(int) value);
			else if (value > 0)
				putULong(cast(ulong) value);
			else
				putLong(cast(ulong) value);
		}
		else static if (is(T : VariantN!(size, Allowed), size_t size, Allowed...))
		{
			static if (__traits(compiles, value == null))
				if (value == null)
					{
					putNull();
					return;
				}
			if (!value.hasValue)
			{
				putNull();
				return;
			}
			static if (Allowed.length > 0)
			{
				static foreach (T; Allowed)
						static if (__traits(compiles, encode!T))
							{
							if (value.convertsTo!T)
								{
								encode(value.get!T);
								return;
							}
						}
						else
							pragma(msg, __FILE__, "(", __LINE__,
									"): Warning: allowed variant type ", T.stringof, " is not encodable");
				throw new Exception("Attempted to encode unencodable variant " ~ (cast() value).toString);
			}
			else
			{
				static foreach (T; EncodableSimpleTypes)
						{
						if (value.convertsTo!T)
							{
							encode(value.get!T);
							return;
						}
					}
				throw new Exception("Attempted to encode unencodable variant " ~ (cast() value).toString);
			}
		}
		else static if (is(T == struct))
		{
			static if (is(typeof(value.erlpack)))
			{
				value.erlpack(this);
			}
			else
			{
				size_t numMembers;
				foreach (member; FieldNameTuple!T)
					static if (__traits(compiles, mixin("value." ~ member)))
						numMembers++;
				startMap(numMembers);
				foreach (member; FieldNameTuple!T)
					static if (__traits(compiles, mixin("value." ~ member)))
					{
						alias names = getUDAs!(__traits(getMember, T, member), EncodeName);
						alias funcs = getUDAs!(__traits(getMember, T, member), EncodeFunc);

						static assert(names.length == 0 || names.length == 1);
						static assert(funcs.length == 0 || funcs.length == 1);

						static if (names.length == 1)
							const string name = names[0].name;
						else
							const string name = member;

						putBinary(cast(ubyte[]) name);
						static if (funcs.length == 1)
							mixin(funcs[0].func ~ "(value." ~ member ~ ");");
						else
							encode(mixin("value." ~ member));
					}
			}
		}
		else
			static assert(false, "Can't serialize " ~ T.stringof);
	}

	T decode(T = Variant)(lazy string debugInfo = "")
	{
		scope (failure)
			logDebugV("Error when decoding " ~ T.stringof ~ " " ~ debugInfo);
		static if (is(T == typeof(null)))
			return readNull();
		else static if (is(T : Nullable!U, U))
		{
			try
			{
				readNull();
				return Nullable!U.init;
			}
			catch (Exception)
			{
				return Nullable!U(decode!U);
			}
		}
		else static if (is(T : Atom))
			return cast(T) readAtom();
		else static if (is(T : bool))
			return cast(T) readBool();
		else static if (is(T == byte) || is(T == ubyte))
			return cast(T) readByte();
		else static if (is(T : ubyte[]))
			return cast(T) readBinary();
		else static if (is(T : string))
			return cast(T) readBinary().idup;
		else static if (is(T : SysTime))
			return cast(T) SysTime.fromISOExtString(cast(string) readBinary());
		else static if (is(T : wstring))
			return cast(T)(cast(string) readBinary().idup).toUTF16;
		else static if (is(T : dstring))
			return cast(T)(cast(string) readBinary().idup).toUTF32;
		else static if (isAssociativeArray!T)
		{
			ubyte[] saved = buffer;
			scope (failure)
				buffer = saved;
			auto len = readMapLength();
			T ret;
			foreach (i; 0 .. len)
			{
				auto key = decode!(KeyType!T)("key #" ~ i.to!string);
				auto item = decode!(ValueType!T)("value #" ~ i.to!string);
				ret[key] = item;
			}
			return ret;
		}
		else static if (is(T : KeyValuePair!(K, V)[], K, V))
		{
			ubyte[] saved = buffer;
			scope (failure)
				buffer = saved;
			auto len = readMapLength();
			T ret;
			foreach (i; 0 .. len)
			{
				auto key = decode!K("key #" ~ i.to!string);
				auto item = decode!V("value #" ~ i.to!string);
				ret ~= kv(key, item);
			}
			return ret;
		}
		else static if (isArray!T)
		{
			ubyte[] saved = buffer;
			scope (failure)
				buffer = saved;
			bool needsNil;
			auto len = readListLength(needsNil);
			T ret;
			if (len != 0)
			{
				static if (is(ElementType!T : void))
				{
					throw new Exception("Expected empty list but got " ~ len.to!string ~ " Elements");
				}
				else
				{
					static if (isDynamicArray!T)
						ret = new ElementType!T[len];
					foreach (i; 0 .. len)
						ret[i] = decode!(ElementType!T)("element #" ~ i.to!string);
				}
			}
			if (needsNil)
				readEmptyList();
			return ret;
		}
		else static if (is(T : Tuple!U, U...))
		{
			ubyte[] saved = buffer;
			scope (failure)
				buffer = saved;
			auto len = readTupleLength;
			T ret;
			if (len != T.expand.length)
				throw new Exception(
						"Expected tuple of length " ~ T.expand.length.to!string ~ ", but got " ~ len.to!string);
			foreach (i, T; T.Types)
				ret[i] = decode!T("element #" ~ i.to!string);
			return ret;
		}
		else static if (is(T : BigInt) && is(typeof(readBigInt)))
			return cast(T) readBigInt();
		else static if (isFloatingPoint!T)
			return cast(T) readDouble();
		else static if (is(T : long))
			return cast(T) readLong();
		else static if (is(T : ulong))
			return cast(T) readULong();
		else static if (isIntegral!T)
			return cast(T) readInt();
		else static if (is(T : VariantN!(size, Allowed), size_t size, Allowed...))
		{
			auto type = cast(ETFHeader) peek(1)[0];
			switch (type)
			{
			case ETFHeader.atomExt:
			case ETFHeader.atomUTF8Ext:
			case ETFHeader.smallAtomExt:
			case ETFHeader.smallAtomUTF8Ext:
				auto a = readAtom;
				static if (__traits(compiles, T(true)))
				{
					if (a == atom("true"))
						return T(true);
					else if (a == atom("false"))
						return T(false);
				}
				static if (__traits(compiles, T(null)))
				{
					if (a == atom("nil"))
						return T(null);
				}

				static if (__traits(compiles, T(Atom.init)))
					return T(a);
				else static if (__traits(compiles, T(Variant.init)))
					return T(Variant(a));
				else
					throw new Exception("Got an atom where it isn't allowed");
			case ETFHeader.binaryExt:
				static if (__traits(compiles, T(cast(ubyte[])[])))
					return T(readBinary);
				else static if (__traits(compiles, T(Variant.init)))
					return T(Variant(readBinary));
				else
					throw new Exception("Got binary where it isn't allowed");
			case ETFHeader.stringExt:
				static if (__traits(compiles, T(cast(ubyte[])[])))
					return T(readString);
				else static if (__traits(compiles, T(cast(string)[])))
					return T(cast(string) readString);
				else static if (__traits(compiles, T(Variant.init)))
					return T(Variant(readString));
				else
					throw new Exception("Got binary where it isn't allowed");
			case ETFHeader.newFloatExt:
				static if (__traits(compiles, T(double.init)))
					return T(readDouble);
				else static if (__traits(compiles, T(Variant.init)))
					return T(Variant(readDouble));
				else
					throw new Exception("Got double where it isn't allowed");
			case ETFHeader.integerExt:
			case ETFHeader.smallIntegerExt:
				static if (__traits(compiles, T(long.init)))
					return T(readLong);
				else static if (__traits(compiles, T(int.init)))
					return T(readInt);
				else static if (__traits(compiles, T(ubyte.init)))
					return T(readByte);
				else static if (__traits(compiles, T(Variant.init)))
					return T(Variant(readLong));
				else
					throw new Exception("Got integer where it isn't allowed");
			case ETFHeader.smallBigExt:
			case ETFHeader.largeBigExt:
				static if (is(typeof(readBigInt)) && __traits(compiles, T(BigInt.init)))
					return T(readBigInt);
				else static if (__traits(compiles, T(long.init)))
					return T(readLong);
				else static if (is(typeof(readBigInt)) && __traits(compiles, T(Variant.init)))
					return T(Variant(readBigInt));
				else static if (__traits(compiles, T(Variant.init)))
					return T(Variant(readLong));
				else
					throw new Exception("Got integer where it isn't allowed");
			case ETFHeader.listExt:
			case ETFHeader.smallTupleExt:
			case ETFHeader.largeTupleExt:
				static foreach (V; Allowed)
						static if (__traits(compiles, T(V.init)) && __traits(compiles, decode!V) && isArray!V)
							try
							{
								return T(decode!V);
							}
				catch (Exception)
				{
				}
				static if (__traits(compiles, T(cast(Variant[])[])))
					return T(decode!(Variant[]));
				else static if (__traits(compiles, T(Variant.init)))
					return T(Variant(decode!(Variant[])));
				else
					throw new Exception("Got list where it isn't allowed");
			case ETFHeader.mapExt:
				static foreach (V; Allowed)
						static if (__traits(compiles, T(V.init)) && __traits(compiles,
								decode!V) && (isAssociativeArray!V || (isArray!V
								&& isKeyValueArray!(ElementType!V))))
							try
							{
								return T(decode!V);
							}
				catch (Exception)
				{
				}
				static if (__traits(compiles, T(cast(Variant[Variant])[])))
					return T(decode!(Variant[Variant]));
				else static if (__traits(compiles, T(Variant.init)))
					return T(Variant(decode!(Variant[Variant])));
				else
					throw new Exception("Got map where it isn't allowed");
			case ETFHeader.nilExt:
				readNull();
				return T.init;
			default:
				throw new Exception("Invalid ETF header type for " ~ T.stringof ~ ": " ~ type.to!string);
			}
		}
		else static if (is(T == struct))
		{
			static if (is(typeof(T.erlunpack)))
			{
				return T.erlunpack(this);
			}
			else
			{
				auto len = readMapLength;
				T value;
				foreach (i; 0 .. len)
				{
					bool found;
					auto str = cast(string) readBinaryUnsafe;
					foreach (member; FieldNameTuple!T)
						static if (__traits(compiles, mixin("value." ~ member)))
						{
							alias names = getUDAs!(__traits(getMember, T, member), EncodeName);
							alias funcs = getUDAs!(__traits(getMember, T, member), DecodeFunc);

							static assert(names.length == 0 || names.length == 1);
							static assert(funcs.length == 0 || funcs.length == 1);

							static if (names.length == 1)
								const string name = names[0].name;
							else
								const string name = member;

							if (!found && str == name)
							{
								static if (funcs.length == 1)
									mixin("value." ~ member ~ " = " ~ funcs[0].func ~ "();");
								else
									mixin("value." ~ member) = decode!(typeof(mixin("value." ~ member)))(
											"member " ~ member ~ " (name=" ~ name ~ ")");
								found = true;
							}
						}
				}
				return value;
			}
		}
		else
			static assert(false, "Can't deserialize " ~ T.stringof);
	}

	static ETFBuffer serialize(T)(T value, size_t buffer = 1024, bool allowResize = true) @trusted
	{
		ETFBuffer ret;
		if (allowResize)
			ret.buffer.reserve(buffer);
		else
			ret.full.length = buffer;
		ret.allowResize = allowResize;
		ret.putVersion();
		ret.encode(value);
		return ret;
	}

	static T deserialize(T = Variant)(ubyte[] buffer, bool start = true) @trusted
	{
		ETFBuffer ret;
		ret.buffer = buffer;
		ret.allowResize = false;
		if (start)
			ret.readVersion();
		return ret.decode!T;
	}

	static ETFNode deserialzeTree()(auto ref ubyte[] buffer) @trusted
	{
		ETFNode root;
		root.bufferStart = buffer;
		root.type = cast(ETFHeader) 0;
		if (buffer.length && buffer[0] == ETFHeader.formatVersion)
		{
			root.type = ETFHeader.formatVersion;
			buffer = buffer[1 .. $];
		}
		while (buffer.length)
		{
			ubyte[] start = buffer;
			ETFHeader type = cast(ETFHeader) buffer[0];
			buffer = buffer[1 .. $];
			ETFNode[] keys, children;
			size_t length;
			switch (type)
			{
			case ETFHeader.nilExt:
				length = 0;
				break;
			case ETFHeader.smallIntegerExt:
				length = 1;
				break;
			case ETFHeader.integerExt:
				length = 4;
				break;
			case ETFHeader.newFloatExt:
				length = 8;
				break;
			case ETFHeader.floatExt:
				length = 31;
				break;
			case ETFHeader.smallAtomExt:
			case ETFHeader.smallAtomUTF8Ext:
				if (buffer.length < 1)
					break;
				length = buffer[0];
				buffer = buffer[1 .. $];
				break;
			case ETFHeader.atomExt:
			case ETFHeader.atomUTF8Ext:
			case ETFHeader.stringExt:
				if (buffer.length < 2)
					break;
				length = buffer[0 .. 2].bigEndianToNative!ushort;
				buffer = buffer[2 .. $];
				break;
			case ETFHeader.binaryExt:
				if (buffer.length < 4)
					break;
				length = buffer[0 .. 4].bigEndianToNative!uint;
				buffer = buffer[4 .. $];
				break;
			case ETFHeader.smallTupleExt:
				if (buffer.length < 1)
					break;
				auto elems = buffer[0];
				buffer = buffer[1 .. $];
				length = 0;
				foreach (i; 0 .. elems)
					children ~= deserialzeTree(buffer);
				break;
			case ETFHeader.largeTupleExt:
				if (buffer.length < 4)
					break;
				auto elems = buffer[0 .. 4].bigEndianToNative!uint;
				buffer = buffer[4 .. $];
				length = 0;
				foreach (i; 0 .. elems)
					children ~= deserialzeTree(buffer);
				break;
			case ETFHeader.listExt:
				if (buffer.length < 4)
					break;
				auto elems = buffer[0 .. 4].bigEndianToNative!uint;
				buffer = buffer[4 .. $];
				length = 1;
				foreach (i; 0 .. elems)
					children ~= deserialzeTree(buffer);
				break;
			case ETFHeader.smallBigExt:
				if (buffer.length < 1)
					break;
				length = cast(int) buffer[0] + 1;
				buffer = buffer[1 .. $];
				break;
			case ETFHeader.largeBigExt:
				if (buffer.length < 4)
					break;
				length = cast(size_t) buffer[0 .. 4].bigEndianToNative!uint + 1;
				buffer = buffer[4 .. $];
				break;
			case ETFHeader.mapExt:
				if (buffer.length < 4)
					break;
				auto elems = buffer[0 .. 4].bigEndianToNative!uint;
				buffer = buffer[4 .. $];
				length = 0;
				foreach (i; 0 .. elems)
				{
					keys ~= deserialzeTree(buffer);
					children ~= deserialzeTree(buffer);
				}
				break;
			case ETFHeader.newFunExt:
			case ETFHeader.exportExt:
			case ETFHeader.newReferenceExt:
			case ETFHeader.funExt:
			case ETFHeader.portExt:
			case ETFHeader.pidExt:
			case ETFHeader.compressed:
			case ETFHeader.referenceExt:
			case ETFHeader.bitBinaryExt:
			default:
				length = 0;
				break;
			}

			auto data = buffer[0 .. length > $ ? $ : length];
			buffer = buffer[data.length .. $];

			root.children ~= ETFNode(type, start, data, keys, children);

			if (root.type == cast(ETFHeader) 0)
				break;
		}
		if (root.type == cast(ETFHeader) 0 && root.children.length)
			return root.children[0];
		else
			return root;
	}
}

private string indent(string s)
{
	import std.algorithm;
	import std.string;

	return s.lineSplitter!(KeepTerminator.yes).map!(a => '\t' ~ a).join();
}

string binToString(in ubyte[] b)
{
	import std.format;

	string s;
	foreach (c; b)
	{
		if (c < 128 && c >= 32)
			s ~= cast(char) c;
		else
			s ~= "\\x" ~ format("%02x", c);
	}
	return s;
}

struct ETFNode
{
	ETFHeader type;
	ubyte[] bufferStart;
	ubyte[] data;
	ETFNode[] keys;
	ETFNode[] children;

	ETFNode opIndex(T)(T index)
	{
		if (keys.length)
		{
			foreach (i, key; keys)
			{
				try
				{
					if (key.get!T == index)
						return children[i];
				}
				catch (Exception)
				{
				}
			}
			throw new Exception("Index out of bounds");
		}
		else
		{
			static if (isIntegral!T)
			{
				if (index < 0 || index >= children.length)
					throw new Exception("Index out of bounds");
				return children[index];
			}
			throw new Exception("Index out of bounds");
		}
	}

	T get(T)()
	{
		static if (is(T == ETFNode))
			return this;
		else
		{
			switch (type)
			{
			case ETFHeader.smallIntegerExt:
				static if (isIntegral!T
						|| isFloatingPoint!T)
					return cast(T) data[0];
				else
					break;
			case ETFHeader.integerExt:
				static if (isIntegral!T
						|| isFloatingPoint!T)
					return cast(T) data[0 .. 4].bigEndianToNative!int;
				else
					break;
			case ETFHeader.atomExt:
			case ETFHeader.atomUTF8Ext:
			case ETFHeader.smallAtomExt:
			case ETFHeader.smallAtomUTF8Ext:
			case ETFHeader.binaryExt:
			case ETFHeader.stringExt:
				static if (isSomeString!T)
					return (cast(string) data).to!T;
				else
					break;
			case ETFHeader.newFloatExt:
				static if (isIntegral!T
						|| isFloatingPoint!T)
					return cast(T) data[0 .. 8].bigEndianToNative!double;
				else
					break;
			case ETFHeader.nilExt:
				static if (__traits(compiles, { T a = null; }))
					return null;
				else
					break;
			case ETFHeader.smallTupleExt:
			case ETFHeader.largeTupleExt:
			case ETFHeader.listExt:
				static if (isArray!T && !isSomeString!T)
				{
					T ret;
					static if (isDynamicArray!T)
						ret.length = children.length;
					else if (children.length != ret.length)
						throw new Exception("List does not have expected number of elements");
					foreach (i, ref elem; ret)
						elem = children[i].get!(ElementType!T);
					return ret;
				}
				else static if (is(T : Tuple!U, U...))
				{
					T ret;
					if (children.length != U.length)
						throw new Exception("List does not have expected number of elements");
					foreach (i, T; U)
						ret[i] = children[i].get!T;
					return ret;
				}
				else
					break;
			case ETFHeader.mapExt:
				static if (isAssociativeArray!T)
				{
					T ret;
					foreach (i; 0 .. keys.length < children.length ? keys.length : children.length)
						ret[keys[i].get!(KeyType!T)] = children[i].get!(ValueType!T);
					return ret;
				}
				else static if (isArray!T && !isSomeString!T)
				{
					T ret;
					static if (isDynamicArray!T)
						ret.length = children.length;
					foreach (i, ref elem; ret)
						elem = children[i].get!(ElementType!T);
					return ret;
				}
				else
					break;
			default:
				break;
			}
			throw new Exception("Can't convert " ~ type.to!string ~ " to " ~ T.stringof);
		}
	}

	string toString() const
	{
		string s;
		if (type == ETFHeader.binaryExt)
			s = "b";
		else
			s = type.to!string;
		string dataStr;
		switch (type)
		{
		case ETFHeader.smallIntegerExt:
			dataStr = data[0].to!string;
			break;
		case ETFHeader.integerExt:
			dataStr = data[0 .. 4].bigEndianToNative!int.to!string;
			break;
		case ETFHeader.atomExt:
		case ETFHeader.atomUTF8Ext:
		case ETFHeader.smallAtomExt:
		case ETFHeader.smallAtomUTF8Ext:
		case ETFHeader.binaryExt:
		case ETFHeader.stringExt:
			dataStr = '"' ~ binToString(data) ~ '"';
			break;
		case ETFHeader.newFloatExt:
			dataStr = data[0 .. 8].bigEndianToNative!double.to!string;
			break;
		case ETFHeader.nilExt:
			dataStr = "<empty list>";
			break;
		case ETFHeader.listExt:
			dataStr = (data == [cast(ubyte) ETFHeader.nilExt])
				? "valid" : ("invalid - " ~ data.to!string);
			break;
		default:
			dataStr = data.to!string;
			break;
		}
		if (children.length > 0)
		{
			s ~= "[" ~ children.length.to!string ~ "]";
			if (data.length)
				s ~= "(" ~ dataStr ~ ")";
			s ~= ":\n";
			foreach (i, child; children)
			{
				if (i < keys.length)
					s ~= (keys[i].toString[0 .. $ - 1] ~ ": " ~ child.toString).indent;
				else
					s ~= child.toString.indent;
			}
		}
		else if (data.length)
			s ~= "(" ~ dataStr ~ ")\n";
		else
			s ~= '\n';
		assert(s[$ - 1] == '\n');
		return s;
	}
}

unittest
{
	import std.exception;

	ETFBuffer buffer;
	buffer.full.length = 64;

	assertNotThrown!BufferResizeAttemptException(buffer.putLong(long.max)); // now 11
	assertNotThrown!BufferResizeAttemptException(buffer.putLong(long.max)); // now 22
	assertNotThrown!BufferResizeAttemptException(buffer.putLong(long.max)); // now 33
	assertNotThrown!BufferResizeAttemptException(buffer.putLong(long.max)); // now 44
	assertNotThrown!BufferResizeAttemptException(buffer.putLong(long.max)); // now 55
	assertThrown!BufferResizeAttemptException(buffer.putLong(long.max)); // should throw
	assertNotThrown!BufferResizeAttemptException(buffer.putInt(6)); // now 60
	assertNotThrown!BufferResizeAttemptException(buffer.putByte(7)); // now 62
	assertNotThrown!BufferResizeAttemptException(buffer.putByte(8)); // now 64
	assertThrown!BufferResizeAttemptException(buffer.putByte(9)); // should throw
}

unittest
{
	import std.exception;

	assert(ETFBuffer.serialize(atom("Hello World")).bytes == cast(ubyte[]) "\x83s\x0BHello World");

	KeyValuePair!(Variant, Variant)[] map;
	map ~= kv(Variant("a"), Variant(1));
	map ~= kv(Variant(2), Variant(2));
	map ~= kv(Variant(3), Variant(variantArray(1, 2, 3)));
	import std.stdio;

	assert(ETFBuffer.serialize(map)
			.bytes == cast(ubyte[]) "\x83t\x00\x00\x00\x03m\x00\x00\x00\x01aa\x01a\x02a\x02a\x03l\x00\x00\x00\x03a\x01a\x02a\x03j");

	struct S
	{
		void erlpack(ref ETFBuffer b)
		{
			b.encode([kv(atom("name"), Variant("jake")), kv(atom("age"), Variant(23))]);
		}
	}

	assert(ETFBuffer.serialize(S.init)
			.bytes == cast(ubyte[]) "\x83t\x00\x00\x00\x02s\x04namem\x00\x00\x00\x04jakes\x03agea\x17");

	assert(ETFBuffer.serialize(false).bytes == cast(ubyte[]) "\x83s\x05false");

	assert(ETFBuffer.serialize(2.5).bytes == cast(ubyte[]) "\x83F@\x04\x00\x00\x00\x00\x00\x00");
	assert(ETFBuffer.serialize(51_512_123_841_234.31423412341435123412341342)
			.bytes == cast(ubyte[]) "\x83FB\xc7l\xcc\xeb\xedi(");

	assert(ETFBuffer.serialize("string").bytes == cast(ubyte[]) "\x83m\x00\x00\x00\x06string");
	assert(assertNotThrown(ETFBuffer.deserialize(
			cast(ubyte[]) "\x83m\x00\x00\x00\x06string") == Variant(cast(ubyte[]) "string")));
	assert(assertNotThrown(ETFBuffer.deserialize!string(
			cast(ubyte[]) "\x83m\x00\x00\x00\x06string") == "string"));
	assert(assertNotThrown(ETFBuffer.deserialize!wstring(
			cast(ubyte[]) "\x83m\x00\x00\x00\x06string") == "string"w));
	assert(assertNotThrown(ETFBuffer.deserialize!dstring(
			cast(ubyte[]) "\x83m\x00\x00\x00\x06string") == "string"d));
	assertThrown(ETFBuffer.deserialize!int(cast(ubyte[]) "\x83m\x00\x00\x00\x06string"));
	assertThrown(ETFBuffer.deserialize!string(cast(ubyte[]) "\x83"));
	assertThrown(ETFBuffer.deserialize!(typeof(null))(cast(ubyte[]) "\x83"));

	assert(ETFBuffer.serialize([]).bytes == cast(ubyte[]) "\x83j");
	assert(ETFBuffer.deserialize!(void[])(cast(ubyte[]) "\x83j") == []);

	assert(ETFBuffer.serialize(127552384489488384L)
			.bytes == cast(ubyte[]) "\x83n\x08\x00\x00\x00\xc0\xc77(\xc5\x01");
	assert(ETFBuffer.deserialize!long(
			cast(ubyte[]) "\x83n\x08\x00\x00\x00\xc0\xc77(\xc5\x01") == 127552384489488384L);

	assert(ETFBuffer.serialize(atom("hi")).bytes == cast(ubyte[]) "\x83s\x02hi");
	assert(ETFBuffer.deserialize!Atom(cast(ubyte[]) "\x83w\x02hi") == atom("hi"));
	assert(ETFBuffer.deserialize!Atom(cast(ubyte[]) "\x83s\x02hi") == atom("hi"));

	assert(ETFBuffer.serialize(123.45).bytes == cast(ubyte[]) "\x83F@^\xdc\xcc\xcc\xcc\xcc\xcd");
	assert(ETFBuffer.deserialize!double(cast(ubyte[]) "\x83F@^\xdc\xcc\xcc\xcc\xcc\xcd") == 123.45);

	assert(ETFBuffer.serialize(cast(ubyte[]) "alsdjaljf")
			.bytes == cast(ubyte[]) "\x83m\x00\x00\x00\talsdjaljf");
	assert(ETFBuffer.deserialize!(ubyte[])(
			cast(ubyte[]) "\x83m\x00\x00\x00\talsdjaljf") == cast(ubyte[]) "alsdjaljf");

	assert(ETFBuffer.serialize(12345).bytes == cast(ubyte[]) "\x83b\x00\x0009");
	assert(ETFBuffer.deserialize!int(cast(ubyte[]) "\x83b\x00\x0009") == 12345);

	assert(ETFBuffer.serialize(tuple()).bytes == cast(ubyte[]) "\x83h\x00");
	assertNotThrown(ETFBuffer.deserialize!(Tuple!())(cast(ubyte[]) "\x83h\x00"));

	struct MyObject
	{
		struct Child
		{
			string a;
			Tuple!(string, string[], string[]) also;
			ubyte[] with_;

			string[Variant] map;
		}

		Atom e1;
		Tuple!(Atom, Atom, string) e2;
		Variant[] e3;
		Tuple!(string, Tuple!(Atom, string[]), typeof(null)) e4;
		long e5;
		double e6;
		int e7;
		int e8;
		double e9;
		long e10;
		Child e11;
	}

	MyObject obj;
	obj.e1 = atom("someatom");
	obj.e2 = tuple(atom("some"), atom("other"), "tuple");
	obj.e3 = variantArray(cast(ubyte[])("maybe"), 1, null);
	obj.e4 = tuple("with", tuple(atom("embedded"), ["tuples and lists"]), null);
	obj.e5 = 127542384389482384L;
	obj.e6 = 5334.32;
	obj.e7 = 102;
	obj.e8 = -1394;
	obj.e9 = -349.2;
	obj.e10 = -498384595043;
	obj.e11.a = "map";
	obj.e11.also = tuple("tuples", ["and"], ["lists"]);
	obj.e11.with_ = cast(ubyte[]) "binaries";
	obj.e11.map = [Variant(cast(ubyte[])("a")) : "anotherone", Variant(3)
		: "int keys", Variant(atom("something")) : "else"];

	assert(ETFBuffer.serialize(obj).bytes == cast(ubyte[]) "\x83t\x00\x00\x00\x0bm\x00\x00\x00\x02e1s\x08someatomm\x00\x00\x00\x02e2h\x03s\x04somes\x05otherm\x00\x00\x00\x05tuplem\x00\x00\x00\x02e3l\x00\x00\x00\x03m\x00\x00\x00\x05maybea\x01s\x03niljm\x00\x00\x00\x02e4h\x03m\x00\x00\x00\x04withh\x02s\x08embeddedl\x00\x00\x00\x01m\x00\x00\x00\x10tuples and listsjs\x03nilm\x00\x00\x00\x02e5n\x08\x00\x90gWs\x1f\x1f\xc5\x01m\x00\x00\x00\x02e6F@\xb4\xd6Q\xeb\x85\x1e\xb8m\x00\x00\x00\x02e7afm\x00\x00\x00\x02e8b\xff\xff\xfa\x8em\x00\x00\x00\x02e9F\xc0u\xd333333m\x00\x00\x00\x03e10n\x05\x01ch\x09\x0atm\x00\x00\x00\x03e11t\x00\x00\x00\x04m\x00\x00\x00\x01am\x00\x00\x00\x03mapm\x00\x00\x00\x04alsoh\x03m\x00\x00\x00\x06tuplesl\x00\x00\x00\x01m\x00\x00\x00\x03andjl\x00\x00\x00\x01m\x00\x00\x00\x05listsjm\x00\x00\x00\x05with_m\x00\x00\x00\x08binariesm\x00\x00\x00\x03mapt\x00\x00\x00\x03l\x00\x00\x00\x01aajm\x00\x00\x00\x0aanotheronea\x03m\x00\x00\x00\x08int keyss\x09somethingm\x00\x00\x00\x04else");
	auto obj2 = ETFBuffer.deserialize!MyObject(cast(ubyte[]) "\x83t\x00\x00\x00\x0bm\x00\x00\x00\x02e1s\x08someatomm\x00\x00\x00\x02e2h\x03s\x04somes\x05otherm\x00\x00\x00\x05tuplem\x00\x00\x00\x02e3l\x00\x00\x00\x03m\x00\x00\x00\x05maybea\x01s\x03niljm\x00\x00\x00\x02e4h\x03m\x00\x00\x00\x04withh\x02s\x08embeddedl\x00\x00\x00\x01m\x00\x00\x00\x10tuples and listsjs\x03nilm\x00\x00\x00\x02e5n\x08\x00\x90gWs\x1f\x1f\xc5\x01m\x00\x00\x00\x02e6F@\xb4\xd6Q\xeb\x85\x1e\xb8m\x00\x00\x00\x02e7afm\x00\x00\x00\x02e8b\xff\xff\xfa\x8em\x00\x00\x00\x02e9F\xc0u\xd333333m\x00\x00\x00\x03e10n\x05\x01ch\x09\x0atm\x00\x00\x00\x03e11t\x00\x00\x00\x04m\x00\x00\x00\x01am\x00\x00\x00\x03mapm\x00\x00\x00\x04alsoh\x03m\x00\x00\x00\x06tuplesl\x00\x00\x00\x01m\x00\x00\x00\x03andjl\x00\x00\x00\x01m\x00\x00\x00\x05listsjm\x00\x00\x00\x05with_m\x00\x00\x00\x08binariesm\x00\x00\x00\x03mapt\x00\x00\x00\x03l\x00\x00\x00\x01aajm\x00\x00\x00\x0aanotheronea\x03m\x00\x00\x00\x08int keyss\x09somethingm\x00\x00\x00\x04else");
	assert(obj.e1 == obj2.e1);
	assert(obj.e2 == obj2.e2);
	assert(obj.e3 == obj2.e3);
	assert(obj.e4 == obj2.e4);
	assert(obj.e5 == obj2.e5);
	assert(obj.e6 == obj2.e6);
	assert(obj.e7 == obj2.e7);
	assert(obj.e8 == obj2.e8);
	assert(obj.e9 == obj2.e9);
	assert(obj.e10 == obj2.e10);
	assert(obj.e11.a == obj2.e11.a);
	assert(obj.e11.also == obj2.e11.also);
	assert(obj.e11.with_ == obj2.e11.with_);
	assert(obj.e11.map.length == obj2.e11.map.length);

	/*alias Var3 = Algebraic!(string, Tuple!(string, string[], string[]));
	alias Var2 = Algebraic!(Tuple!(Variant, Variant, string),
			Variant, Tuple!(string, Tuple!(Variant, string[]), typeof(null)), long,
			double, int, KeyValuePair!(Variant,
			string)[], string[Tuple!Variant], KeyValuePair!(Variant, Var3)[], Variant[]);
	alias Var = Algebraic!(Var2[], Tuple!(Variant, Variant, string), Variant,
			Tuple!(string, Tuple!(Variant, string[]), typeof(null)), long, double, int,
			KeyValuePair!(Variant, string)[],
			string[Tuple!Variant], Variant[], KeyValuePair!(Variant, Variant)[]);
	//dfmt off
	Var[] obj = [
		Var(Variant(atom("someatom"))),
		Var(tuple(Variant(atom("some")),
			Variant(atom("other")), "tuple")),
		Var(variantArray("maybe", 1, null)),
		Var(tuple("with", tuple(Variant(atom("embedded")), ["tuples and lists"]), null)),
		Var(127542384389482384L),
		Var(5334.32),
		Var(102),
		Var(-1394),
		Var(-349.2),
		Var(-498384595043),
		Var([
			Var2([
				kv(Variant(atom("a")), Var3("map")),
				kv(Variant(atom("also")), Var3(tuple("tuples", ["and"], ["lists"]))),
				kv(Variant(atom("with")), Var3("binaries"))
			]),
			Var2([
				kv(Variant(Variant(atom("a"))), "anotherone"),
				kv(Variant(3), "int keys")
			]),
			Var2([tuple(Variant(atom("something"))) : "else"])
		])
	];
	//dfmt on
	assert(ETFBuffer.serialize(obj).bytes == "\x83l\x00\x00\x00\x0bs\x08someatomh\x03s\x04somes\x05otherm\x00\x00\x00\x05tuplel\x00\x00\x00\x03m\x00\x00\x00\x05maybea\x01s\x03niljh\x03m\x00\x00\x00\x04withh\x02s\x08embeddedl\x00\x00\x00\x01m\x00\x00\x00\x10tuples and listsjs\x03niln\x08\x00\x90gWs\x1f\x1f\xc5\x01F@\xb4\xd6Q\xeb\x85\x1e\xb8afb\xff\xff\xfa\x8eF\xc0u\xd333333n\x05\x01ch\x09\x0atl\x00\x00\x00\x03t\x00\x00\x00\x03s\x01am\x00\x00\x00\x03maps\x04alsoh\x03m\x00\x00\x00\x06tuplesl\x00\x00\x00\x01m\x00\x00\x00\x03andjl\x00\x00\x00\x01m\x00\x00\x00\x05listsjs\x04withm\x00\x00\x00\x08binariest\x00\x00\x00\x02s\x01am\x00\x00\x00\x0aanotheronea\x03m\x00\x00\x00\x08int keyst\x00\x00\x00\x01h\x01s\x09somethingm\x00\x00\x00\x04elsejj");
	assert(obj == ETFBuffer.deserialize!(Var[])(cast(ubyte[]) "\x83l\x00\x00\x00\x0bs\x08someatomh\x03s\x04somes\x05otherm\x00\x00\x00\x05tuplel\x00\x00\x00\x03m\x00\x00\x00\x05maybea\x01s\x03niljh\x03m\x00\x00\x00\x04withh\x02s\x08embeddedl\x00\x00\x00\x01m\x00\x00\x00\x10tuples and listsjs\x03niln\x08\x00\x90gWs\x1f\x1f\xc5\x01F@\xb4\xd6Q\xeb\x85\x1e\xb8afb\xff\xff\xfa\x8eF\xc0u\xd333333n\x05\x01ch\x09\x0atl\x00\x00\x00\x03t\x00\x00\x00\x03s\x01am\x00\x00\x00\x03maps\x04alsoh\x03m\x00\x00\x00\x06tuplesl\x00\x00\x00\x01m\x00\x00\x00\x03andjl\x00\x00\x00\x01m\x00\x00\x00\x05listsjs\x04withm\x00\x00\x00\x08binariest\x00\x00\x00\x02s\x01am\x00\x00\x00\x0aanotheronea\x03m\x00\x00\x00\x08int keyst\x00\x00\x00\x01h\x01s\x09somethingm\x00\x00\x00\x04elsejj"));*/

	foreach (i; 0 .. 256)
	{
		assert(ETFBuffer.serialize(i).bytes == cast(ubyte[]) "\x83a" ~ cast(ubyte) i);
		assert(ETFBuffer.deserialize!ubyte(cast(ubyte[]) "\x83a" ~ cast(ubyte) i) == i);
	}
	assert(ETFBuffer.serialize(1024).bytes == cast(ubyte[]) "\x83b\x00\x00\x04\x00");
	assert(ETFBuffer.serialize(-2147483648).bytes == cast(ubyte[]) "\x83b\x80\x00\x00\x00");
	assert(ETFBuffer.serialize(2147483647).bytes == cast(ubyte[]) "\x83b\x7f\xff\xff\xff");
	assert(ETFBuffer.serialize(2147483648UL).bytes == cast(ubyte[]) "\x83n\x04\x00\x00\x00\x00\x80");
	assert(ETFBuffer.serialize(1230941823049123411UL)
			.bytes == cast(ubyte[]) "\x83n\x08\x00S\xc6\x03\xf6\x10/\x15\x11");
	assert(ETFBuffer.serialize(-2147483649L).bytes == cast(ubyte[]) "\x83n\x04\x01\x01\x00\x00\x80");
	assert(ETFBuffer.serialize(-123094182304912341L)
			.bytes == cast(ubyte[]) "\x83n\x08\x01\xd5\x933\xb2\x81Q\xb5\x01");

	assert(ETFBuffer.serialize(variantArray(1, "two", 3.0, "four", ["five"])).bytes == cast(ubyte[]) "\x83l\x00\x00\x00\x05a\x01m\x00\x00\x00\x03twoF@\x08\x00\x00\x00\x00\x00\x00m\x00\x00\x00\x04fourl\x00\x00\x00\x01m\x00\x00\x00\x04fivejj");

	assert(ETFBuffer.serialize(null).bytes == cast(ubyte[]) "\x83s\x03nil");
	assert(ETFBuffer.serialize(true).bytes == cast(ubyte[]) "\x83s\x04true");
	assert(ETFBuffer.serialize(false).bytes == cast(ubyte[]) "\x83s\x05false");

	assert(ETFBuffer.serialize("hello world").bytes == cast(ubyte[]) "\x83m\x00\x00\x00\x0bhello world");
	assert(ETFBuffer.serialize("hello\0 world")
			.bytes == cast(ubyte[]) "\x83m\x00\x00\x00\x0chello\0 world");

	assert(ETFBuffer.serialize(tuple(1, 2, 3)).bytes == cast(ubyte[]) "\x83h\x03a\x01a\x02a\x03");

	assert(ETFBuffer.serialize("hello world").bytes == cast(ubyte[]) "\x83m\x00\x00\x00\x0bhello world");
	assert(ETFBuffer.serialize("hello world\u202e")
			.bytes == cast(ubyte[]) "\x83m\x00\x00\x00\x0ehello world\xe2\x80\xae");

	struct Message
	{
		enum Type
		{
			text,
			image
		}

		string text;
		string url;
		Type type;
	}

	Message msg;
	msg.text = "Hello";
	msg.type = Message.Type.image;
	assert(ETFBuffer.serialize(msg).bytes == cast(ubyte[]) "\x83t\x00\x00\x00\x03m\x00\x00\x00\x04textm\x00\x00\x00\x05Hellom\x00\x00\x00\x03urlm\x00\x00\x00\x00m\x00\x00\x00\x04typea\x01");
}

unittest
{
	import discord.w.gateway;
	import discord.w.types;

	struct TestFrame(T)
	{
		T d;
	}

	//ETFBuffer.deserialize!(TestFrame!PresenceUpdate)(cast(ubyte[]) "\x83t\x00\x00\x00\x04d\x00\x01dt\x00\x00\x00\x06d\x00\x04gamet\x00\x00\x00\x0ad\x00\x06assetst\x00\x00\x00\x02d\x00\x0blarge_imagem\x00\x00\x000spotify:ee4bc034f20c9681516cb4c1e62d2c7ac273483bd\x00\x0alarge_textm\x00\x00\x00\x10Metal Resistanced\x00\x07detailsm\x00\x00\x00\x12Road of Resistanced\x00\x05flagsa0d\x00\x04namem\x00\x00\x00\x07Spotifyd\x00\x05partyt\x00\x00\x00\x01d\x00\x02idm\x00\x00\x00\x1aspotify:142041528875876352d\x00\x0asession_idm\x00\x00\x00 8e2664f120d92d911731afcddf5551b2d\x00\x05statem\x00\x00\x00 BABYMETAL; Herman Li; Sam Totmand\x00\x07sync_idm\x00\x00\x00\x161A41ABZ7cZsujSRJZYLMold\x00\x0atimestampst\x00\x00\x00\x02d\x00\x03endn\x06\x00\xb3\x16uma\x01d\x00\x05startn\x06\x00A2pma\x01d\x00\x04typea\x02d\x00\x08guild_idn\x08\x00\x00\x00\x82\xe3\xa8L\xb5\x04d\x00\x04nickm\x00\x00\x00\x07repskekd\x00\x05rolesl\x00\x00\x00\x07n\x08\x00\x00\x00B\x87\xa2M\xb5\x04n\x08\x00\x01\x00\xc0\xbcaC\xce\x04n\x08\x00\x00\x00\xc0\xcd\x03>\x0c\x05n\x08\x00\x0a\x00D*\x8c\x8b\x1d\x05n\x08\x00\x00\x00@]|O/\x05n\x08\x00\x1e\x00BN\x91E\xa9\x05n\x08\x00\x00\x00\x82^\xa1\x82\xaa\x05jd\x00\x06statusd\x00\x06onlined\x00\x04usert\x00\x00\x00\x01d\x00\x02idn\x08\x00\x00\x00\x00\x98\x04\xa2\xf8\x01d\x00\x02opa\x00d\x00\x01sa\xccd\x00\x01td\x00\x0fPRESENCE_UPDATE");
	//ETFBuffer.deserialize!(TestFrame!Message)(cast(ubyte[]) "\x83t\x00\x00\x00\x04d\x00\x01dt\x00\x00\x00\x10m\x00\x00\x00\x08activityt\x00\x00\x00\x02m\x00\x00\x00\x08party_idm\x00\x00\x00\x1aspotify:142041528875876352m\x00\x00\x00\x04typea\x03m\x00\x00\x00\x0battachmentsjm\x00\x00\x00\x06authort\x00\x00\x00\x04m\x00\x00\x00\x06avatarm\x00\x00\x00 ee07fc538dfa22501cccdd49afc6dbe5m\x00\x00\x00\x0ddiscriminatorm\x00\x00\x00\x040001m\x00\x00\x00\x02idn\x08\x00\x00\x00\x00\x98\x04\xa2\xf8\x01m\x00\x00\x00\x08usernamem\x00\x00\x00\x0arespektivem\x00\x00\x00\x0achannel_idn\x08\x00\x00\x00\x82\xe3\xa8L\xb5\x04m\x00\x00\x00\x07contentm\x00\x00\x00\x00m\x00\x00\x00\x10edited_timestampd\x00\x03nilm\x00\x00\x00\x06embedsjm\x00\x00\x00\x02idn\x08\x00\x0c\x00@1f\xa9\xb2\x05m\x00\x00\x00\x10mention_everyoned\x00\x05falsem\x00\x00\x00\x0dmention_rolesjm\x00\x00\x00\x08mentionsjm\x00\x00\x00\x05noncem\x00\x00\x00\x12410576769154809856m\x00\x00\x00\x06pinnedd\x00\x05falsem\x00\x00\x00\x09timestampm\x00\x00\x00 2018-02-06T23:25:30.693000+00:00m\x00\x00\x00\x03ttsd\x00\x05falsem\x00\x00\x00\x04typea\x00d\x00\x02opa\x00d\x00\x01sa\xcdd\x00\x01td\x00\x0eMESSAGE_CREATE");
}
