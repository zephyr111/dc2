import std.stdio;
import std.range;
import std.range.primitives;
import std.algorithm.comparison;
import std.algorithm.searching;
import std.typecons;
import std.conv;
import std.datetime;
import interfaces : IErrorHandler;
import types;
import utils;


struct PrefixedRange(R1, R2)
    if(isInputRange!R1 && isInputRange!R2 && is(ElementType!R1 == ElementType!R2))
{
    R1 _prefixRange;
    R2 _input;

    this(R2 input, R1 prefixRange = R1())
    {
        _prefixRange = prefixRange;
        _input = input;
    }

    @property bool empty()
    {
        return _prefixRange.empty && _input.empty;
    }

    void popFront()
    {
        if(_prefixRange.empty)
            _input.popFront();
        else
            _prefixRange.popFront();
    }

    @property auto ref front()
    {
        if(_prefixRange.empty)
            return _input.front;
        return _prefixRange.front;
    }

    static if(isForwardRange!R1 && isForwardRange!R2)
    {
        @property auto save()
        {
            typeof(this) result = this;
            result._prefixRange = _prefixRange.save;
            result._input = _input.save;
            return result;
        }
    }
}

alias MacroPrefixRange = BufferedStack!(PpcToken[], string[]);
alias MacroRange(InputRange) = PrefixedRange!(MacroPrefixRange, InputRange);

struct Macro
{
    string name;
    bool predefined;
    bool withArgs;
    string[] args;
    PpcToken[] content;

    bool opEquals()(auto ref const Macro m) const
    {
        alias sameToken = (PpcToken a, PpcToken b) => a.type == b.type && a.value == b.value;
        return name == m.name
                && withArgs == m.withArgs 
                && args == m.args
                && content.equal!sameToken(m.content);
    }
};

pragma(msg, "[OPTIM] put methods const when it is possible (impact the whole code)");
final class MacroDb
{
    private Macro[string] _db;
    private DateTime _now;

    // QUID: copy
    this()
    {
        _now = cast(DateTime)Clock.currTime();
    }

    this(MacroDb rhs)
    {
        _db = rhs._db.dup;
        _now = rhs._now;
    }

    @property typeof(this) dup()
    {
        return new MacroDb(this);
    }

    Nullable!Macro get(PpcToken token)
    {
        assert(token.type == PpcTokenType.IDENTIFIER);
        auto macroName = token.value.get!PpcIdentifierTokenValue.name;
        return get(macroName, token.location);
    }

    Nullable!Macro get(string macroName, TokenLocation loc)
    {
        with(PpcTokenType)
        {
            Macro* mPtr = macroName in _db;

            if(mPtr !is null)
                return (*mPtr).nullable;

            if(!macroName.startsWith("__") || !macroName.endsWith("__"))
                return Nullable!Macro();

            PpcToken result;

            switch(macroName[2..$-2])
            {
                case "STDC":
                    auto val = PpcTokenValue(PpcNumberTokenValue("1"));
                    result = PpcToken(NUMBER, loc, val);
                    break;

                case "LINE":
                    auto val = PpcTokenValue(PpcNumberTokenValue(loc.line.to!string));
                    result = PpcToken(NUMBER, loc, val);
                    break;

                case "FILE":
                    auto val = PpcTokenValue(PpcStringTokenValue(false, loc.filename));
                    result = PpcToken(STRING, loc, val);
                    break;

                case "TIME":
                    import std.datetime;
                    auto currTime = _now.timeOfDay.toISOExtString;
                    auto val = PpcTokenValue(PpcStringTokenValue(false, currTime));
                    result = PpcToken(STRING, loc, val);
                    break;

                case "DATE":
                    auto currDate = _now.date.toISOExtString;
                    auto val = PpcTokenValue(PpcStringTokenValue(false, currDate));
                    result = PpcToken(STRING, loc, val);
                    break;

                default:
                    return Nullable!Macro();
            }

            return Macro(macroName, true, false, [], [result]).nullable;
        }
    }

    void set(Macro m)
    {
        _db[m.name] = m;
    }

    void remove(Macro m)
    {
        _db.remove(m.name);
    }

    bool canFind(string macroName)
    {
        return !get(macroName, TokenLocation()).isNull;
    }
};

// Apply macro substitution on the front tokens of the input so that 
// the next token can be safely read
void macroSubstitution(Range)(ref Range input, MacroDb macros, IErrorHandler errorHandler)
    if(isForwardRange!Range && is(ElementType!Range == PpcToken))
{
    void error(string msg, TokenLocation loc)
    {
        errorHandler.error(msg, loc.filename, loc.line, loc.col);
    }

    void epicFailure(string msg, TokenLocation loc)
    {
        errorHandler.error(msg, loc.filename, loc.line, loc.col);
        input.walkLength;
    }

    with(PpcTokenType)
    {
        while(!input.empty)
        {
            PpcToken token = input.front;

            if(token.type != IDENTIFIER)
                break;

            auto tmp = macros.get(token);

            if(tmp.isNull)
                break;

            auto m = tmp.get;

            auto currState = !input._prefixRange.empty ? input._prefixRange.state : [];

            if(m.predefined)
            {
                input.popFront();
                input._prefixRange.put(tuple(m.content, currState));
                break;
            }

            if(currState.retro.canFind(m.name))
                break;

            currState ~= m.name;

            if(m.withArgs)
            {
                auto lookAhead = input.save;
                lookAhead.popFront();
                lookAhead.findSkip!(a => a.type == SPACING);

                auto startLoc = input.front.location;

                if(!lookAhead.skipIf!(a => a.type == LPAREN))
                    break;

                input = lookAhead;

                pragma(msg, "[OPTIM] avoid allocations");

                auto params = appender!(PpcToken[][]);

                // Argument parsing
                do
                {
                    auto param = appender!(PpcToken[]);
                    int level = 0;

                    input.forwardWhile!((a) {
                        if(a.type == COMMA && level == 0)
                            return false; // 1 param
                        else if(a.type == LPAREN)
                            level++;
                        else if(a.type == RPAREN && level-- <= 0)
                            return false; // end
                        return true;
                    })(param);

                    if(input.empty)
                        epicFailure("unterminated macro", startLoc);

                    params.put(param.data);
                }
                while(input.skipIf!(a => a.type == COMMA));

                if(!input.skipIf!(a => a.type == RPAREN))
                    return epicFailure("internal error", startLoc);

                // Macro argument matching & substitution
                if(m.args.empty && params.data == [[]])
                    input._prefixRange.put(tuple(m.content, currState));
                else if(m.args.length > params.data.length)
                    error("too few parameters", startLoc);
                else if(m.args.length < params.data.length)
                    error("too many parameters", startLoc);
                else
                {
                    auto newTokens = appender!(PpcToken[]);

                    foreach(PpcToken mToken ; m.content)
                    {
                        pragma(msg, "[OPTIM] precomputation with a PARAM token type (with tokenValue = param pos)");

                        if(mToken.type == IDENTIFIER)
                        {
                            auto param = mToken.value.get!PpcIdentifierTokenValue.name;
                            long pos = -1;

                            foreach(ulong i ; 0..m.args.length)
                                if(param == m.args[i])
                                    pos = i;

                            if(pos >= 0)
                                newTokens.put(params.data[pos]);
                            else
                                newTokens.put(mToken);
                        }
                        else
                        {
                            newTokens.put(mToken);
                        }
                    }

                    input._prefixRange.put(tuple(newTokens.data, currState));
                }
            }
            else
            {
                input.popFront();
                input._prefixRange.put(tuple(m.content, currState));
            }
        }
    }
}

