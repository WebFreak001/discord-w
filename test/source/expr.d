module expr;

import std.algorithm;
import std.conv;
import std.format;
import std.string;
import std.uni;

string stringFormatter(string format, int i) @safe
{
	if (!format.canFind('{') && !format.canFind('%'))
		return format;

	string ret;
	string op;

	foreach (c; format)
	{
		if (op.length)
		{
			if (c == '{' && op == "{")
			{
				ret ~= '{';
				op = "";
			}
			else if (c == '%' && op == "%")
			{
				ret ~= '%';
				op = "";
			}
			else if (op[0] == '{')
			{
				if (c == '}' && op.count!"a == '{'" == op.count!"a == '}'" + 1)
				{
					ret ~= processExpr(op, i);
					op = "";
				}
				else
					op ~= c;
			}
			else if (op[0] == '%')
			{
				if ((c >= '0' && c <= '9') || c == ' ')
					op ~= c;
				else
				{
					ret ~= .format(op ~ c, i);
					op = "";
				}
			}
		}
		else if (c == '{' || c == '%')
			op ~= c;
		else
			ret ~= c;
	}

	return ret ~ op;
}

string processExpr(string expr, int i) nothrow @safe
{
	import std.random;

	expr = expr.stripNothrow;

	if (!expr.length || expr[0] != '{')
		return expr;

	expr = expr[1 .. $].stripLeftNothrow;

	if (expr.length && expr[$ - 1] == '}')
	{
		expr.length--;
		expr = expr.stripRightNothrow;
	}

	if (!expr.length)
		return "";

	auto nestedEnd = expr.lastIndexOfNothrow('}');

	auto fmtIndex = expr.lastIndexOfNothrow(";fmt=%");
	string fmt = "";
	if (fmtIndex != -1 && fmtIndex > nestedEnd)
	{
		fmt = expr[fmtIndex + ";fmt=".length .. $];
		expr = expr[0 .. fmtIndex];
	}

	string ret;

	int math;
	try
	{
		math = expr.asLowerCase.startsWith("mul", "add", "sub", "div");
	}
	catch (Exception)
	{
		math = 0;
	}

	if (math && expr[3 .. $].stripLeftNothrow.canFindOutsideExpr(' '))
	{
		auto parts = expr[3 .. $].stripLeftNothrow.findSplitOutsideExpr(' ');
		try
		{
			auto a = parts[0].processExpr(i).to!long;
			auto b = parts[2].processExpr(i).to!long;
			switch (math)
			{
			case 1:
				ret = (a * b).to!string;
				break;
			case 2:
				ret = (a + b).to!string;
				break;
			case 3:
				ret = (a - b).to!string;
				break;
			case 4:
				ret = (a / b).to!string;
				break;
			default:
				assert(false);
			}
		}
		catch (Exception)
		{
			ret = expr;
		}
	}
	else if (expr == "i" || expr == "I")
	{
		ret = i.to!string;
	}
	else
	{
		try
		{
			if (expr.asLowerCase.startsWith("rand"))
			{
				auto rest = expr["rand".length .. $].stripLeft;
				try
				{
					if (!rest.length)
						ret = uniform(0, 100).to!string;
					else if (rest.canFindOutsideExpr(' '))
					{
						auto parts = rest.findSplitOutsideExpr(' ');
						auto min = parts[0].processExpr(i).to!long;
						auto max = parts[2].processExpr(i).to!long;
						if (max < min)
							ret = min.to!string;
						else
							ret = uniform(min, max).to!string;
					}
					else
					{
						auto max = rest.processExpr(i).to!long;
						if (max <= 0)
							ret = "0";
						else
							ret = uniform(0, max).to!string;
					}
				}
				catch (Exception)
				{
					ret = uniform(0, 100).to!string;
				}
			}
			else if (expr.canFind('|'))
			{
				auto index = expr.indexOfOutsideExpr(";i=");
				if (index != -1 && index > nestedEnd)
				{
					try
					{
						auto val = expr[index + ";i=".length .. $].processExpr(i).to!int;

						ret = expr[0 .. index].split('|')[val % $].processExpr(i);
					}
					catch (Exception)
					{
						ret = expr[0 .. index].processExpr(i);
					}
				}
				else
					ret = expr.split('|')[i % $].processExpr(i);
			}
			else
				ret = expr;
		}
		catch (Exception)
		{
			ret = expr;
		}
	}

	if (!fmt.length)
		return ret;
	else
	{
		try
		{
			return format(fmt, ret.to!long);
		}
		catch (Exception)
		{
			try
			{
				return format(fmt, ret);
			}
			catch (Exception)
			{
				return ret;
			}
		}
	}
}

bool canFindOutsideExpr(string s, char check) nothrow @safe
{
	int level = 0;
	foreach (c; s)
	{
		if (c == check && level <= 0)
			return true;
		else if (c == '{')
			level++;
		else if (c == '}')
			level--;
	}
	return false;
}

string[3] findSplitOutsideExpr(string s, char split) nothrow @safe
{
	int level = 0;
	foreach (i, c; s)
	{
		if (c == split && level <= 0)
			return [s[0 .. i], s[i .. i + 1], s[i + 1 .. $]];
		else if (c == '{')
			level++;
		else if (c == '}')
			level--;
	}
	return [s, null, null];
}

ptrdiff_t indexOfOutsideExpr(string s, string search) nothrow @safe
{
	int level = 0;
	for (int i = 0; i < s.length - cast(int) search.length; i++)
	{
		if (level == 0)
		{
			try
			{
				if (s[i] == '{')
				{
					level++;
					continue;
				}
				if (s[i .. $].startsWith(search))
					return i;
			}
			catch (Exception)
			{
			}
		}
		else if (s[i] == '{')
			level++;
		else if (s[i] == '}')
			level--;
	}
	return -1;
}

string stripNothrow(string s) nothrow @safe
{
	try
	{
		return s.strip;
	}
	catch (Exception)
	{
		return s;
	}
}

string stripLeftNothrow(string s) nothrow @safe
{
	try
	{
		return s.stripLeft;
	}
	catch (Exception)
	{
		return s;
	}
}

string stripRightNothrow(string s) nothrow @safe
{
	try
	{
		return s.stripRight;
	}
	catch (Exception)
	{
		return s;
	}
}

auto lastIndexOfNothrow(Search)(string s, Search search) nothrow @safe
{
	try
	{
		return s.lastIndexOf(search);
	}
	catch (Exception)
	{
		return -1;
	}
}

unittest
{
	import std.stdio;

	assert(processExpr("{rand 1}", 0) == "0");
	assert(processExpr("{rand 1;fmt=%04d}", 0) == "0000");
	assert(processExpr("{add 1 1}", 0) == "2");
	assert(processExpr("{add 1 {rand 0}}", 0) == "1");
	assert(processExpr("{a|b}", 0) == "a");
	assert(processExpr("{a|b}", 1) == "b");
	assert(processExpr("{a|b;i=1}", 0) == "b");

	writeln(stringFormatter("{bzw|owo|wtf|fml;i={rand}} #{rand 100;fmt=%03d}", 0));
}
