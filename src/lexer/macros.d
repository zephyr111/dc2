import std.stdio;
import std.range;
import std.range.primitives;
import std.algorithm.comparison;
import std.algorithm.searching;
import std.algorithm.iteration;
import std.typecons;
import std.conv;
import std.datetime;
import interfaces : IErrorHandler;
import types;
import utils;


// Range type resulting of the merge of two ranges
// (use to perform fast macro substitutions)
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

alias MacroPrefixRange = Stack!PpcToken;
alias MacroRange(InputRange) = PrefixedRange!(MacroPrefixRange, InputRange);

// Data structure to store a macro definition
struct Macro
{
    string name;
    bool predefined;
    bool withArgs;
    immutable(string)[] args;
    immutable(PpcToken)[] content;
    bool withPrescan;

    bool opEquals()(auto ref const Macro m) const
    {
        alias sameToken = (PpcToken a, PpcToken b) => a.type == b.type && a.value == b.value;
        return name == m.name
                && withArgs == m.withArgs 
                && args == m.args
                && content.equal!sameToken(m.content);
    }
};

// Data structure use to contain and lookup all defined 
// macros during the preprocessing phase
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

struct MacroSubstitution(Range)
    if(isForwardRange!Range && is(ElementType!Range == PpcToken))
{
    Range* _input;
    MacroDb _macros;
    IErrorHandler _errorHandler;

    this(ref Range input, MacroDb macros, IErrorHandler errorHandler)
    {
        _input = &input;
        _macros = macros;
        _errorHandler = errorHandler;
    }

    private void error(string msg, TokenLocation loc)
    {
        _errorHandler.error(msg, loc.filename, loc.line, loc.col);
    }

    private void epicFailure(string msg, TokenLocation loc)
    {
        _errorHandler.error(msg, loc.filename, loc.line, loc.col);
        _input.walkLength;
    }

    static private auto idTokenValue(PpcToken token)
    {
        return token.value.get!PpcIdentifierTokenValue.name;
    }

    static private auto idTokenState(PpcToken token)
    {
        return token.value.get!PpcIdentifierTokenValue.state;
    }

    static private PpcToken pushToState(PpcToken token, string added)
    {
        assert(token.type != PpcTokenType.MACRO_PARAM);
        if(token.type != PpcTokenType.IDENTIFIER)
            return token;

        assert(token.value.peek!PpcIdentifierTokenValue !is null);
        token.value.peek!PpcIdentifierTokenValue.state ~= added;
        return token;
    }

    static private auto numberTokenValue(PpcToken token)
    {
        return token.value.get!PpcNumberTokenValue.content;
    }

    static private PpcToken resetState(PpcToken token, PpcMacroState state)
    {
        if(token.type != PpcTokenType.IDENTIFIER)
            return token;

        assert(token.value.peek!PpcIdentifierTokenValue !is null);
        token.value.peek!PpcIdentifierTokenValue.state = state;
        return token;
    }

    static private auto stringify(const PpcToken[] tokens, TokenLocation loc)
    {
        auto stringified = tokens.map!((a) => a.toString!false).join;
        auto value = PpcTokenValue(PpcStringTokenValue(false, stringified));
        return PpcToken(PpcTokenType.STRING, loc, value);
    }

    static private void handleToken(T)(PpcToken token,
                                        ref T acc,
                                        const PpcToken[][] params)
        if(is(T == Appender!(PpcToken[])) || is(T == Stack!PpcToken))
    {
        with(PpcTokenType)
        {
            assert(token.type != TOKEN_CONCAT
                    || !token.value.get!PpcConcatTokenValue.isInMacro);

            if(token.type == MACRO_PARAM)
            {
                auto pos = token.value.get!PpcParamTokenValue.id;

                if(token.value.get!PpcParamTokenValue.toStringify)
                    acc.put(stringify(params[pos], token.location));
                else static if(is(T == Stack!PpcToken))
                    acc.putChunk(params[pos]);
                else
                    acc.put(params[pos]);
            }
            else
            {
                acc.put(token);
            }
        }
    }

    private void mergeTokens(ref Appender!(PpcToken[]) leftTokensAcc, 
                                ref Appender!(PpcToken[]) rightTokensAcc,
                                PpcMacroState state)
    {
        with(PpcTokenType)
        {
            auto leftTokens = leftTokensAcc.data;
            auto rightTokens = rightTokensAcc.data;

            if(rightTokens.empty)
                return;

            if(leftTokens.empty)
                return leftTokensAcc.put(rightTokens);

            auto left = leftTokens[$-1];
            auto right = rightTokens[0];

            if(!left.type.among(IDENTIFIER, NUMBER)
                    || !right.type.among(IDENTIFIER, NUMBER, STRING))
                return error("tokens cannot be merged", left.location);

            if((left.type != IDENTIFIER || idTokenValue(left) != "L")
                    && right.type.among(CHARACTER, STRING))
                return error("tokens cannot be merged", left.location);

            PpcToken res;
            PpcTokenValue value;

            if(right.type.among(CHARACTER, STRING))
            {
                if(right.type == CHARACTER)
                {
                    auto oldValue = right.value.get!PpcCharTokenValue;
                    if(oldValue.isWide)
                        return error("tokens cannot be merged", left.location);
                    value = PpcTokenValue(PpcCharTokenValue(true, oldValue.content));
                }
                else
                {
                    auto oldValue = right.value.get!PpcStringTokenValue;
                    if(oldValue.isWide)
                        return error("tokens cannot be merged", left.location);
                    value = PpcTokenValue(PpcStringTokenValue(true, oldValue.content));
                }

                res = PpcToken(right.type, left.location, value);
            }
            else
            {
                string content;

                if(left.type == IDENTIFIER)
                    content = idTokenValue(left);
                else
                    content = numberTokenValue(left);

                if(right.type == IDENTIFIER)
                    content ~= idTokenValue(right);
                else
                    content ~= numberTokenValue(right);

                if(left.type == IDENTIFIER)
                    value = PpcTokenValue(PpcIdentifierTokenValue(content, state));
                else
                    value = PpcTokenValue(PpcNumberTokenValue(content));

                res = PpcToken(left.type, left.location, value);
            }

            leftTokens[$-1] = res;
            leftTokensAcc.put(rightTokens[1..$]);
        }
    }

    private void substituteComplexMacro(Macro m, PpcMacroState state, TokenLocation loc)
    {
        with(PpcTokenType)
        {
            pragma(msg, "[OPTIM] avoid allocations");

            auto params = appender!(PpcToken[][]);

            // For each argument
            do
            {
                auto tokenAcc = appender!(PpcToken[]);
                int level = 0;

                // Argument parsing
                while(!_input.empty)
                {
                    auto e = _input.front;

                    if(e.type == COMMA && level == 0
                            || e.type == RPAREN && level-- <= 0)
                        break;
                    else if(e.type == LPAREN)
                        level++;

                    tokenAcc.put(e);
                    _input.popFront();
                }

                if(_input.empty)
                    return epicFailure("unterminated macro", loc);

                // Strip space on both sides
                auto left = tokenAcc.data.countUntil!(a => a.type != SPACING);
                auto right = tokenAcc.data.retro.countUntil!(a => a.type != SPACING);
                left = max(left, 0);
                right = max(right, 0);

                // First scan: recursive substitution of arguments
                // Note: prescan is not done when an argument is stringified/concatenated
                if(m.withPrescan)
                {
                    auto subInput = MacroRange!(PpcToken[])(tokenAcc.data[left..$-right].dup);

                    tokenAcc.clear();

                    while(true)
                    {
                        macroSubstitution(subInput, _macros, _errorHandler);

                        if(subInput.empty)
                            break;

                        tokenAcc.put(pushToState(subInput.front, m.name));
                        subInput.popFront();
                    }

                    params.put(tokenAcc.data);
                }
                else
                {
                    auto tmp = tokenAcc.data[left..$-right];
                    tmp = tmp.map!(a => resetState(a, state)).array;
                    params.put(tmp);
                }
            }
            while(_input.skipIf!(a => a.type == COMMA));

            if(!_input.skipIf!(a => a.type == RPAREN))
                return epicFailure("internal error", loc);

            // Macro argument matching & substitution
            if(m.args.empty && params.data == [[]])
            {
                auto tmp = m.content.map!(a => resetState(a, state)).array;
                _input._prefixRange.putChunk(tmp);
            }
            else if(m.args.length > params.data.length)
                error("too few parameters", loc);
            else if(m.args.length < params.data.length)
                error("too many parameters", loc);
            else
            {
                foreach_reverse(ref mToken ; m.content)
                {
                    if(mToken.type == TOKEN_CONCAT
                            && mToken.value.get!PpcConcatTokenValue.isInMacro)
                    {
                        auto tokenValue = mToken.value.get!PpcConcatTokenValue;
                        assert(tokenValue.children.length >= 2);
                        auto left = resetState(tokenValue.children[0], state);
                        auto leftTokens = appender!(PpcToken[]);
                        auto rightTokens = appender!(PpcToken[]);

                        handleToken(left, leftTokens, params.data);

                        foreach(ref right ; tokenValue.children[1..$])
                        {
                            auto finalRight = resetState(right, state);
                            handleToken(finalRight, rightTokens, params.data);
                            mergeTokens(leftTokens, rightTokens, state);
                            rightTokens.clear();
                        }

                        _input._prefixRange.putChunk(leftTokens.data);
                    }
                    else
                    {
                        auto finalToken = resetState(mToken, state);
                        handleToken(finalToken, _input._prefixRange, params.data);
                    }
                }
            }
        }
    }

    private void substituteBasicMacro(Macro m, PpcMacroState state)
    {
        _input.popFront();
        auto res = m.content.map!(a => resetState(a, state));
        _input._prefixRange.putChunk(res);
    }

    private bool substituteMacro(Macro m)
    {
        PpcMacroState currState = [];

        if(!_input.empty)
            currState = idTokenState(_input.front);

        // Simple predefined macro without parameters
        // Supposed to not be recursive
        if(m.predefined)
        {
            _input.popFront();
            _input._prefixRange.putChunk(m.content);
            return false;
        }

        // Check for recursive substitution
        if(currState.retro.canFind(m.name))
            return false;

        // Track the name of the macro for later substitutions
        currState ~= m.name;

        if(!m.withArgs)
        {
            substituteBasicMacro(m, currState);
            return true;
        }

        auto lookAhead = _input.save;
        lookAhead.popFront();
        lookAhead.findSkip!(a => a.type == PpcTokenType.SPACING);

        auto startLoc = _input.front.location;

        if(!lookAhead.skipIf!(a => a.type == PpcTokenType.LPAREN))
            return false;

        *_input = lookAhead;

        substituteComplexMacro(m, currState, startLoc);
        return true;
    }

    void substituteFirstTokens()
    {
        while(!_input.empty)
        {
            PpcToken token = _input.front;

            if(token.type != PpcTokenType.IDENTIFIER)
                break;

            auto m = _macros.get(token);

            if(m.isNull)
                break;

            if(!substituteMacro(m.get))
                break;
        }
    }
}

// Apply macro substitution on the front tokens of the input so that 
// the next token can be safely read
void macroSubstitution(Range)(ref Range input, MacroDb macros, IErrorHandler errorHandler)
    if(isForwardRange!Range && is(ElementType!Range == PpcToken))
{
    MacroSubstitution!Range(input, macros, errorHandler).substituteFirstTokens();
}

