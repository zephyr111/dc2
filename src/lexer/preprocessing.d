import std.stdio;
import std.range;
import std.range.primitives;
import std.traits;
import std.algorithm.comparison;
import std.algorithm.searching;
import std.algorithm.iteration;
import std.algorithm.mutation;
import std.typecons;
import std.exception;
import std.format;
import std.string;
import std.conv;
import std.container;
import std.file; // for #include
import std.utf; // for #include
import std.path; // for #include
import std.datetime; // for predefined macros
import interfaces : IErrorHandler;
import types;
import utils;
import locationTracking; // for #include
import trigraphSubstitution; // for #include
import lineSplicing; // for #include
import ppcTokenization; // for #include
import parsing;


private auto bestLoc(Range)(Range input, TokenLocation fallbackLocation)
    if(isInputRange!Range && is(ElementType!Range : PpcToken))
{
    if(!input.empty)
        return input.front.location;
    return fallbackLocation;
}


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


private template Preprocess(InputRange)
{
    static struct Result
    {
        struct ConditionalState
        {
            bool ifPart; // include #if, #ifdef, #ifndef and #elif
            bool evaluated;
        };

        alias MacroPrefixRange = BufferedStack!(PpcToken[], string[]);
        pragma(msg, "[WTF] using BufferedStack!Result cause the LDC compiler to crash...");
        alias IncludeRange = Result[];
        alias WorkingRange = PrefixedRange!(MacroPrefixRange, InputRange);

        private WorkingRange _workingRange;
        private IncludeRange _includeRange;
        private IErrorHandler _errorHandler;
        private Nullable!PpcToken _result;
        private Macro[string]* _macros;
        private Macro[string] _masterMacros;
        private bool _isIncluded;
        private bool _lineStart = true;
        private SList!ConditionalState _conditionalStates;
        private DateTime now;

        this(InputRange input, IErrorHandler errorHandler, Macro[string]* parentMacros)
        {
            _workingRange = WorkingRange(input);
            _errorHandler = errorHandler;

            _isIncluded = parentMacros !is null;
            if(_isIncluded)
                _macros = parentMacros;
            else
            {
                _masterMacros["__STDC__"] = Macro("__STDC__", true, false, [], []);
                _masterMacros["__LINE__"] = Macro("__LINE__", true, false, [], []);
                _masterMacros["__FILE__"] = Macro("__FILE__", true, false, [], []);
                _masterMacros["__TIME__"] = Macro("__TIME__", true, false, [], []);
                _masterMacros["__DATE__"] = Macro("__DATE__", true, false, [], []);
                _macros = &_masterMacros;
            }

            pragma(msg, "[BUG] time should not be different in included file...");
            now = cast(DateTime)Clock.currTime();

            if(!_workingRange.empty)
                computeNext();
        }

        private auto idTokenValue(PpcToken a)
        {
            return a.value.get!PpcIdentifierTokenValue.name;
        }

        private void error(string msg, TokenLocation loc)
        {
            _errorHandler.error(msg, loc.filename, loc.line, loc.col);
        }

        private void directiveFailure(string msg, TokenLocation loc)
        {
            _errorHandler.error(msg, loc.filename, loc.line, loc.col);
            _workingRange.findSkip!(a => a.type != PpcTokenType.NEWLINE);
        }

        private void epicFailure(string msg, TokenLocation loc)
        {
            _errorHandler.error(msg, loc.filename, loc.line, loc.col);
            _workingRange.walkLength;
            _result = Nullable!PpcToken();
        }

        private auto currLoc(TokenLocation fallbackLocation)
        {
            if(!_workingRange.empty)
                return _workingRange.front.location;
            return fallbackLocation;
        }

        // Apply macro substitution on the front tokens of the input so that 
        // the next token can be safely read
        void replaceFrontTokens()
        {
            with(PpcTokenType)
            {
                while(!_workingRange.empty)
                {
                    PpcToken token = _workingRange.front;

                    if(token.type != IDENTIFIER)
                        break;

                    Macro* mPtr = idTokenValue(token) in *_macros;

                    if(mPtr is null)
                        break;

                    auto m = *mPtr;

                    auto currState = !_workingRange._prefixRange.empty ? _workingRange._prefixRange.state : [];

                    if(m.predefined)
                    {
                        PpcToken[] newTokens;
                        auto loc = currLoc(TokenLocation());

                        switch(m.name)
                        {
                            case "__STDC__":
                                auto val = PpcTokenValue(PpcNumberTokenValue("1"));
                                newTokens = [PpcToken(NUMBER, loc, val)];
                                break;

                            case "__LINE__":
                                auto val = PpcTokenValue(PpcNumberTokenValue(loc.line.to!string));
                                newTokens = [PpcToken(NUMBER, loc, val)];
                                break;

                            case "__FILE__":
                                auto val = PpcTokenValue(PpcStringTokenValue(false, loc.filename));
                                newTokens = [PpcToken(STRING, loc, val)];
                                break;

                            case "__TIME__":
                                import std.datetime;
                                auto currTime = now.timeOfDay.toISOExtString;
                                auto val = PpcTokenValue(PpcStringTokenValue(false, currTime));
                                newTokens = [PpcToken(NUMBER, loc, val)];
                                break;

                            case "__DATE__":
                                auto currDate = now.date.toISOExtString;
                                auto val = PpcTokenValue(PpcStringTokenValue(false, currDate));
                                newTokens = [PpcToken(NUMBER, loc, val)];
                                break;

                            default:
                                throw new Exception("programming error");
                        }

                        _workingRange.popFront();
                        _workingRange._prefixRange.put(tuple(newTokens, currState));
                        break;
                    }

                    if(currState.retro.canFind(m.name))
                        break;

                    currState ~= m.name;

                    if(m.withArgs)
                    {
                        auto lookAhead = _workingRange.save;
                        lookAhead.popFront();
                        lookAhead.findSkip!(a => a.type == SPACING);

                        auto startLoc = _workingRange.front.location;

                        if(!lookAhead.skipIf!(a => a.type == LPAREN))
                            break;

                        _workingRange = lookAhead;

                        pragma(msg, "[OPTIM] avoid allocations");

                        auto params = appender!(PpcToken[][]);

                        // Argument parsing
                        do
                        {
                            auto param = appender!(PpcToken[]);
                            int level = 0;

                            _workingRange.forwardWhile!((a) {
                                if(a.type == COMMA && level == 0)
                                    return false; // 1 param
                                else if(a.type == LPAREN)
                                    level++;
                                else if(a.type == RPAREN && level-- <= 0)
                                    return false; // end
                                return true;
                            })(param);

                            if(_workingRange.empty)
                                epicFailure("unterminated macro", startLoc);

                            params.put(param.data);
                        }
                        while(_workingRange.skipIf!(a => a.type == COMMA));

                        if(!_workingRange.skipIf!(a => a.type == RPAREN))
                            return epicFailure("internal error", startLoc);

                        // Macro argument matching & substitution
                        if(m.args.empty && params.data == [[]])
                            _workingRange._prefixRange.put(tuple(m.content, currState));
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
                                    string param = idTokenValue(mToken);
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

                            _workingRange._prefixRange.put(tuple(newTokens.data, currState));
                        }
                    }
                    else
                    {
                        _workingRange.popFront();
                        _workingRange._prefixRange.put(tuple(m.content, currState));
                    }
                }
            }
        }

        private void parseInclude(TokenLocation loc)
        {
            with(PpcTokenType)
            {
                _workingRange.findSkip!(a => a.type == SPACING);
                replaceFrontTokens();

                PpcHeaderTokenValue value;

                if(!_workingRange.forwardIf!(a => a.type == HEADER_NAME, (a) {value = a.value.get!PpcHeaderTokenValue;}))
                    return directiveFailure("expecting header name", currLoc(loc));

                string filename;

                if(!value.isGlobal)
                {
                    pragma(msg, "[OPTION] check the CPATH environment variable");
                    pragma(msg, "[OPTION] check user-specified additional include paths");
                    if(value.name.exists && (value.name.isFile || value.name.isSymlink))
                        filename = value.name;
                }

                if(filename.empty)
                {
                    enum includePaths = ["/usr/include/x86_64-linux-musl/"];
                    // ["/usr/include/", "/usr/include/x86_64-linux-gnu/"]

                    // search the file in the include paths
                    foreach(includePath ; includePaths)
                    {
                        auto tmp = chainPath(includePath, value.name);

                        if(tmp.exists && (tmp.isFile || tmp.isSymlink))
                        {
                            filename = tmp.array;
                            break;
                        }
                    }
                }

                if(filename.empty)
                    return directiveFailure(format!"unable to find the file `%s`"(value.name), currLoc(loc));

                dstring dstr;

                try
                    dstr = readText(filename).byDchar.array;
                catch(FileException)
                    return directiveFailure(format!"unable to open the file `%s`"(filename), currLoc(loc));
                catch(UTFException)
                    return directiveFailure(format!"unable to decode the file `%s` using UTF-8"(filename), currLoc(loc));

                auto range = dstr.trackLocation(filename)
                                    .substituteTrigraph
                                    .spliceLines
                                    .ppcTokenize(_errorHandler)
                                    .preprocess(_errorHandler, _macros);

                if(!range.empty)
                    _includeRange ~= range;
            }
        }

        private void parseDefine(TokenLocation loc)
        {
            with(PpcTokenType)
            {
                Macro m;

                _workingRange.findSkip!(a => a.type == SPACING);

                if(!_workingRange.forwardIf!(a => a.type == IDENTIFIER, (a) {m.name = idTokenValue(a);}))
                    return directiveFailure("expecting identifier", currLoc(loc));

                m.predefined = false;
                m.withArgs = _workingRange.skipIf!(a => a.type == LPAREN);

                auto noSpaceInput = refRange(&_workingRange).filter!(a => a.type != SPACING);

                if(m.withArgs && !noSpaceInput.skipIf!(a => a.type == RPAREN))
                {
                    auto acc = appender!(string[]);

                    if(!noSpaceInput.forwardIf!(a => a.type == IDENTIFIER, a => acc.put(idTokenValue(a))))
                        return directiveFailure("expecting identifier or `)`", currLoc(loc));

                    while(noSpaceInput.skipIf!(a => a.type == COMMA))
                        if(!noSpaceInput.forwardIf!(a => a.type == IDENTIFIER, a => acc.put(idTokenValue(a))))
                            return directiveFailure("expecting identifier", currLoc(loc));

                    if(!noSpaceInput.skipIf!(a => a.type == RPAREN))
                        return directiveFailure("expecting `,` or `)`", currLoc(loc));

                    m.args = acc.data;

                    if(!m.args.replicates.empty)
                        error(format!"duplicated macro parameter name `%s`"(m.args.replicates.front), loc);
                }

                auto acc = appender!(PpcToken[]);
                _workingRange.findSkip!(a => a.type == SPACING);
                _workingRange.forwardWhile!(a => a.type != NEWLINE)(acc);
                m.content = acc.data.stripRight!(a => a.type == SPACING);

                auto withSharp = m.content.find!(a => a.type == SHARP);
                if(!withSharp.empty)
                    error("`#` and `##` not yet supported", withSharp.front.location);

                if(m.name in *_macros && (*_macros)[m.name] != m)
                    error(format!"macro `%s` redefined differently"(m.name), loc);

                (*_macros)[m.name] = m;
            }
        }

        private void parseUndef(TokenLocation loc)
        {
            with(PpcTokenType)
            {
                auto noSpaceInput = refRange(&_workingRange).filter!(a => a.type != SPACING);
                loc = currLoc(loc);

                if(noSpaceInput.empty || noSpaceInput.front.type != IDENTIFIER)
                    return directiveFailure("expecting identifier", loc);

                string macroName = idTokenValue(noSpaceInput.front);

                Macro* mPtr = macroName in *_macros;

                if(mPtr !is null && (*mPtr).predefined)
                    _errorHandler.warning("undefining builtin macro", loc.filename, loc.line, loc.col);

                (*_macros).remove(macroName);
                noSpaceInput.popFront();
            }
        }

        // Skip a group of token enclosed by #if directives
        private void skipGroup(TokenLocation loc)
        {
            with(PpcTokenType)
            {
                int level = 0;

                while(!_workingRange.empty)
                {
                    auto tokenType = _workingRange.front.type;

                    if(!_lineStart || tokenType != SHARP)
                    {
                        _lineStart = tokenType == NEWLINE || _lineStart && tokenType == SPACING;
                        _workingRange.popFront();
                        continue;
                    }

                    auto lookAhead = _workingRange.save;
                    auto startLoc = lookAhead.front.location;
                    lookAhead.popFront();
                    lookAhead.findSkip!(a => a.type == SPACING);

                    if(lookAhead.empty)
                        return epicFailure("unterminated directive", loc);

                    auto tmp = lookAhead.front;

                    if(tmp.type != IDENTIFIER)
                    {
                        _lineStart = false;
                        continue;
                    }

                    string name = idTokenValue(tmp);
                    lookAhead.popFront();

                    pragma(msg, "[FIXME] to probably adapt when file inclusion will be implemented");
                    pragma(msg, "[FIXME] check else/elif have a matching if (per level)");
                    pragma(msg, "[FIXME] check elif are before else (per level)");
                    switch(name)
                    {
                        case "if": level++; break;
                        case "ifdef": level++; break;
                        case "ifndef": level++; break;
                        case "else": if(level <= 0) return; break;
                        case "elif": if(level <= 0) return; break;
                        case "endif": if(level-- <= 0) return; break;
                        default: break;
                    }

                    _workingRange = lookAhead;
                    _workingRange.findSkip!(a => a.type != NEWLINE);

                    if(_workingRange.empty)
                        return epicFailure("unterminated group", loc);
                }
            }
        }

        private void parseConditional(string type)(TokenLocation loc)
            if(["if", "ifdef", "ifndef", "else", "elif", "endif"].canFind(type))
        {
            with(PpcTokenType)
            {
                enum extraTokMsg = format!"extra tokens at end of the #%s directive"(type);
                bool keepGroup;

                static if(type == "if" || type == "elif")
                {
                    auto acc = appender!(PpcToken[]);
                    bool macroSubstitution = true;

                    while(!_workingRange.empty)
                    {
                        auto token = _workingRange.front;

                        if(token.type == NEWLINE)
                            break;

                        // Prefilter the range before evaluation
                        // Another solution is to write an macro-range that can enabled on-demand
                        if(token.type == IDENTIFIER)
                        {
                            if(idTokenValue(token) == "defined")
                                macroSubstitution = false;
                            else if(macroSubstitution)
                                replaceFrontTokens();
                            else
                                macroSubstitution = true;
                        }

                        _workingRange.forwardIf!(a => a.type != SPACING)(acc);
                        _workingRange.skipIf!(a => a.type == SPACING);
                    }

                    auto expr = acc.data;
                    keepGroup = expr.evalConstantExpression(_errorHandler, *_macros, expr.bestLoc(loc));

                    static if(type == "if")
                    {
                        _conditionalStates.insertFront(ConditionalState(true, keepGroup));
                    }
                    else
                    {
                        if(_conditionalStates.empty || !_conditionalStates.front.ifPart)
                        {
                            directiveFailure("#else without #if", expr.bestLoc(loc));
                        }
                        else
                        {
                            keepGroup &= !_conditionalStates.front.evaluated;
                            _conditionalStates.front.evaluated |= keepGroup;
                        }
                    }

                    if(!_workingRange.empty && _workingRange.front.type != NEWLINE)
                        directiveFailure(extraTokMsg, currLoc(loc));

                    if(!keepGroup)
                        skipGroup(currLoc(loc));
                }
                else static if(type == "ifdef" || type == "ifndef")
                {
                    _workingRange.findSkip!(a => a.type == SPACING);
                    
                    if(_workingRange.empty)
                        return epicFailure("unterminated directive", currLoc(loc));

                    auto token = _workingRange.front;

                    if(token.type == IDENTIFIER)
                    {
                        auto name = idTokenValue(token);

                        static if(type == "ifdef")
                            keepGroup = (name in *_macros) !is null;
                        else
                            keepGroup = (name in *_macros) is null;

                        _workingRange.popFront();
                        _workingRange.findSkip!(a => a.type == SPACING);

                        if(!_workingRange.empty && _workingRange.front.type != NEWLINE)
                            directiveFailure(extraTokMsg, currLoc(loc));
                    }
                    else
                    {
                        directiveFailure("expecting identifier", currLoc(loc));
                        keepGroup = true;
                    }

                    _conditionalStates.insertFront(ConditionalState(true, keepGroup));

                    if(!keepGroup)
                        skipGroup(currLoc(loc));
                }
                else static if(type == "else")
                {
                    _workingRange.findSkip!(a => a.type == SPACING);

                    if(!_workingRange.empty && _workingRange.front.type != NEWLINE)
                        directiveFailure(extraTokMsg, currLoc(loc));

                    if(_conditionalStates.empty || !_conditionalStates.front.ifPart)
                    {
                        directiveFailure("#else without #if", loc);
                    }
                    else
                    {
                        _conditionalStates.front.ifPart = false;

                        if(_conditionalStates.front.evaluated)
                            skipGroup(currLoc(loc));
                    }
                }
                else static if(type == "endif")
                {
                    _workingRange.findSkip!(a => a.type == SPACING);
                    if(!_workingRange.empty && _workingRange.front.type != NEWLINE)
                        directiveFailure(extraTokMsg, currLoc(loc));
                    if(_conditionalStates.empty)
                        directiveFailure("#endif without #if", loc);
                    else
                        _conditionalStates.removeFront();
                }
                else
                {
                    static assert(false, format!"unsupported type `%s`"(type));
                }
            }
        }

        private void parseMessage(string type)(TokenLocation loc)
            if(type == "warning" || type == "error")
        {
            with(PpcTokenType)
            {
                auto toPrint = refRange(&_workingRange).until!(a => a.type == NEWLINE);
                string msg = toPrint.map!(a => a.toString).join.to!string.strip;

                static if(type == "warning")
                    _errorHandler.warning(msg, loc.filename, loc.line, loc.col);
                else
                    _errorHandler.error(msg, loc.filename, loc.line, loc.col);
            }
        }

        private void parsePragma(TokenLocation loc)
        {
            _errorHandler.warning("ignored pragma", loc.filename, loc.line, loc.col);
            _workingRange.findSkip!(a => a.type != PpcTokenType.NEWLINE);
        }

        private void parseDirective(TokenLocation loc)
        {
            with(PpcTokenType)
            {
                _workingRange.findSkip!(a => a.type == SPACING);

                if(_workingRange.empty)
                    return epicFailure("unterminated directive", loc);

                auto tmp = _workingRange.front;

                if(tmp.type != IDENTIFIER)
                    return directiveFailure("malformed directive", loc);

                string name = idTokenValue(tmp);
                _workingRange.popFront();

                // Note: macros are allowed in include and conditional directives
                switch(name)
                {
                    case "include": parseInclude(loc); break;
                    case "define": parseDefine(loc); break;
                    case "undef": parseUndef(loc); break;
                    case "if": parseConditional!"if"(loc); break;
                    case "ifdef": parseConditional!"ifdef"(loc); break;
                    case "ifndef": parseConditional!"ifndef"(loc); break;
                    case "else": parseConditional!"else"(loc); break;
                    case "elif": parseConditional!"elif"(loc); break;
                    case "endif": parseConditional!"endif"(loc); break;
                    case "warning": parseMessage!"warning"(loc); break;
                    case "error": parseMessage!"error"(loc); break;
                    case "pragma": parsePragma(loc); break;
                    default: return directiveFailure("unknown directive", loc);
                }
            }
        }

        private void computeNext()
        {
            with(PpcTokenType)
            {
                while(_lineStart && _workingRange.front.type == SHARP)
                {
                    auto startLoc = _workingRange.front.location;

                    _workingRange.popFront();

                    parseDirective(startLoc);

                    if(_workingRange.empty)
                    {
                        _result = Nullable!PpcToken();
                        return;
                    }
                }

                if(_includeRange.empty)
                {
                    replaceFrontTokens();

                    if(_workingRange.empty)
                    {
                        _result = Nullable!PpcToken();
                        return;
                    }

                    PpcToken token = _workingRange.front;
                    _result = token.nullable;
                    _lineStart = token.type == NEWLINE || token.type == SPACING && _lineStart;
                    _workingRange.popFront();
                }
                else
                {
                    assert(!_includeRange.empty && !_includeRange.front.empty);
                    _result = _includeRange.front.front.nullable;
                    _includeRange.front.popFront();

                    if(_includeRange.front.empty)
                        _includeRange.popFront();
                }
            }
        }

        @property bool empty()
        {
            return _result.isNull;
        }

        @property auto front()
        {
            return _result.get;
        }

        void popFront()
        {
            if(_workingRange.empty)
                _result = Nullable!PpcToken();
            else
                computeNext();
        }

        // Note: included range should not be directly copied
        pragma(msg, "[FIXME] implement a resource manager to load files once while enabling look-ahead");
        @property typeof(this) save()
        {
            typeof(this) result = this;
            result._workingRange = _workingRange.save;

            if(!_isIncluded)
            {
                result._masterMacros = _masterMacros.dup;
                result._macros = &result._masterMacros;
            }

            result._includeRange = new typeof(this)[_includeRange.length];

            foreach(ref r ; result._includeRange)
            {
                r = r.save;
                r._macros = result._macros;
            }

            result._conditionalStates = _conditionalStates.dup;
            return result;
        }
    }

    // May consume more char than requested
    // Cannot take an InputRange as input due to look-ahead parsing
    auto preprocess(InputRange)(InputRange input, IErrorHandler errorHandler, Macro[string]* parentMacros = null)
        if(isForwardRange!InputRange && is(ElementType!InputRange : PpcToken))
    {
        return Result(input, errorHandler, parentMacros);
    };
}

// May consume more char than requested
// Cannot take an InputRange as input due to look-ahead parsing
auto preprocess(InputRange)(InputRange input, IErrorHandler errorHandler, Macro[string]* parentMacros = null)
    if(isForwardRange!InputRange && is(ElementType!InputRange : PpcToken))
{
    return Preprocess!InputRange.Result(input, errorHandler, parentMacros);
};
