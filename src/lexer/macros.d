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

alias MacroPrefixRange = BufferedStack!(PpcToken[], string[]);
alias MacroRange(InputRange) = PrefixedRange!(MacroPrefixRange, InputRange);

// Data structure to store a macro definition
struct Macro
{
    string name;
    bool predefined;
    bool withArgs;
    string[] args;
    PpcToken[] content;
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

    auto idTokenValue(PpcToken token)
    {
        return token.value.get!PpcIdentifierTokenValue.name;
    }

    auto numberTokenValue(PpcToken token)
    {
        return token.value.get!PpcNumberTokenValue.content;
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

            // Simple predefined macro without parameters
            // Supposed to not be recursive
            if(m.predefined)
            {
                input.popFront();
                input._prefixRange.put(tuple(m.content, currState));
                break;
            }

            // Check for recursive substitution
            if(currState.retro.canFind(m.name))
                break;

            // Track the name of the macro for later recursive substitutions
            currState ~= m.name;

            // Parametric macro case
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
                auto stateGroups = appender!(string[][][]);

                // Argument parsing
                do
                {
                    auto tokenAcc = appender!(PpcToken[]);
                    auto stateAcc = appender!(string[][]);
                    int level = 0;

                    while(!input.empty)
                    {
                        auto e = input.front;

                        if(e.type == COMMA && level == 0
                                || e.type == RPAREN && level-- <= 0)
                            break;
                        else if(e.type == LPAREN)
                            level++;

                        if(m.withPrescan)
                        {
                            if(!input._prefixRange.empty)
                                stateAcc.put(input._prefixRange.state);
                            else
                                stateAcc.put(cast(string[])[]);
                        }

                        tokenAcc.put(e);
                        input.popFront();
                    }

                    if(input.empty)
                        return epicFailure("unterminated macro", startLoc);

                    // Strip space on both sides
                    auto left = tokenAcc.data.countUntil!(a => a.type != SPACING);
                    auto right = tokenAcc.data.retro.countUntil!(a => a.type != SPACING);
                    left = max(left, 0);
                    right = max(right, 0);

                    if(m.withPrescan)
                        stateGroups.put(stateAcc.data[left..$-right]);
                    params.put(tokenAcc.data[left..$-right]);
                }
                while(input.skipIf!(a => a.type == COMMA));

                if(!input.skipIf!(a => a.type == RPAREN))
                    return epicFailure("internal error", startLoc);

                // First scan: recursive substitution of arguments
                // Note: prescan is not done when an argument is stringified/concatenated
                if(m.withPrescan)
                {
                    foreach(i ; 0..params.data.length)
                    {
                        auto tokenAcc = appender!(PpcToken[]);
                        auto stateAcc = appender!(string[][]);

                        auto param = params.data[i];
                        auto states = stateGroups.data[i];
                        auto subInput = MacroRange!(PpcToken[])();

                        foreach_reverse(j ; 0..param.length)
                            subInput._prefixRange.put(tuple([param[j]], states[j]));

                        while(true)
                        {
                            macroSubstitution(subInput, macros, errorHandler);

                            if(subInput.empty)
                                break;

                            tokenAcc.put(subInput.front);
                            if(!subInput._prefixRange.empty)
                                stateAcc.put(subInput._prefixRange.state);
                            else
                                stateAcc.put(currState[0..max($-1,0)]);
                            subInput.popFront();
                        }

                        assert(tokenAcc.data.length == stateAcc.data.length);
                        params.data[i] = tokenAcc.data;
                        stateGroups.data[i] = stateAcc.data;
                    }

                    assert(params.data.length == stateGroups.data.length);
                }

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
                    auto newStates = appender!(string[][]);

                    foreach(mToken ; m.content)
                    {
                        auto stringify(PpcToken[] tokens)
                        {
                            auto stringified = tokens.map!((a) => a.toString!false).join;
                            auto value = PpcTokenValue(PpcStringTokenValue(false, stringified));
                            return PpcToken(STRING, token.location, value);
                        }

                        auto handleToken(PpcToken token, 
                                                ref Appender!(PpcToken[]) tokenAcc, 
                                                ref Appender!(string[][]) stateAcc)
                        {
                            assert(token.type != TOKEN_CONCAT
                                    || !token.value.get!PpcConcatTokenValue.isInMacro);

                            if(token.type == MACRO_PARAM)
                            {
                                auto pos = token.value.get!PpcParamTokenValue.id;

                                if(token.value.get!PpcParamTokenValue.toStringify)
                                {
                                    if(m.withPrescan)
                                        stateAcc.put(currState);
                                    tokenAcc.put(stringify(params.data[pos]));
                                }
                                else
                                {
                                    if(m.withPrescan)
                                        stateAcc.put(stateGroups.data[pos]);
                                    tokenAcc.put(params.data[pos]);
                                }
                            }
                            else
                            {
                                if(m.withPrescan)
                                    stateAcc.put(currState);
                                tokenAcc.put(token);
                            }
                        }

                        void mergeTokens(ref Appender!(PpcToken[]) leftTokensAcc, 
                                            ref Appender!(string[][]) leftStatesAcc, 
                                            ref Appender!(PpcToken[]) rightTokensAcc, 
                                            ref Appender!(string[][]) rightStatesAcc)
                        {
                            auto leftTokens = leftTokensAcc.data;
                            auto leftStates = leftStatesAcc.data;
                            auto rightTokens = rightTokensAcc.data;
                            auto rightStates = rightStatesAcc.data;
                            assert(!m.withPrescan || leftTokens.length == leftStates.length);
                            assert(!m.withPrescan || rightTokens.length == rightStates.length);

                            if(rightTokens.empty)
                                return;

                            if(leftTokens.empty)
                            {
                                if(m.withPrescan)
                                    leftStatesAcc.put(rightStates);
                                leftTokensAcc.put(rightTokens);
                                return;
                            }

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
                                    value = PpcTokenValue(PpcIdentifierTokenValue(content));
                                else
                                    value = PpcTokenValue(PpcNumberTokenValue(content));

                                res = PpcToken(left.type, left.location, value);
                            }

                            leftTokens[$-1] = res;
                            if(m.withPrescan)
                                leftStates[$-1] = []; // Ok ?

                            leftTokensAcc.put(rightTokens[1..$]);
                            if(m.withPrescan)
                                leftStatesAcc.put(rightStates[1..$]);
                        }

                        if(mToken.type == TOKEN_CONCAT
                            && mToken.value.get!PpcConcatTokenValue.isInMacro)
                        {
                            auto tokenValue = mToken.value.get!PpcConcatTokenValue;
                            assert(tokenValue.children.length >= 2);
                            auto left = tokenValue.children[0];
                            auto newLeftTokens = appender!(PpcToken[]);
                            auto newLeftStates = appender!(string[][]);
                            auto newRightTokens = appender!(PpcToken[]);
                            auto newRightStates = appender!(string[][]);

                            handleToken(left, newLeftTokens, newLeftStates);

                            foreach(right ; tokenValue.children[1..$])
                            {
                                newRightTokens.clear();
                                newRightStates.clear();
                                handleToken(right, newRightTokens, newRightStates);
                                mergeTokens(newLeftTokens, newLeftStates, 
                                            newRightTokens, newRightStates);
                            }

                            if(m.withPrescan)
                                newStates.put(newLeftStates.data);
                            newTokens.put(newLeftTokens.data);
                        }
                        else
                        {
                            handleToken(mToken, newTokens, newStates);
                        }
                    }

                    assert(!m.withPrescan || newTokens.data.length == newStates.data.length);

                    if(m.withPrescan)
                        foreach_reverse(i ; 0..newTokens.data.length)
                            input._prefixRange.put(tuple([newTokens.data[i]], newStates.data[i]));
                    else
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

