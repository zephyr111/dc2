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
import std.string;
import std.format;
import std.conv;
import std.meta;
import std.container;
import std.ascii;
import std.functional;
import std.file; // for #include
import std.utf; // for #include
import std.path; // for #include
import interfaces : IErrorHandler;
import types;
import utils;
import locationTracking; // for #include
import trigraphSubstitution; // for #include
import lineSplicing; // for #include
import ppcTokenization; // for #include


private auto bestLoc(Range)(Range input, TokenLocation fallbackLocation)
    if(isInputRange!Range && is(ElementType!Range : PpcToken))
{
    if(!input.empty)
        return input.front.location;
    return fallbackLocation;
}

private template Preprocess(InputRange)
{
    struct Result
    {
        struct ConditionalState
        {
            bool ifPart; // include #if, #ifdef, #ifndef and #elif
            bool evaluated;
        };

        alias MacroPrefixRange = BufferedStack!(PpcToken[]);
        pragma(msg, "[WTF] using BufferedStack!Result cause the LDC compiler to crash...");
        alias IncludeRange = Result[];
        alias WorkingRange = MergeRange!(MacroPrefixRange, InputRange);

        private InputRange _input;
        private IErrorHandler _errorHandler;
        private Nullable!PpcToken _result;
        private Macro[string] _macros;
        private bool _isIncluded;
        private MacroPrefixRange _macroPrefixRange;
        private IncludeRange _includeRange;
        private WorkingRange _workingRange;
        private bool _lineStart = true;
        private SList!ConditionalState _conditionalStates;

        this(InputRange input, IErrorHandler errorHandler, Macro[string] prarentMacros)
        {
            _input = input;
            _errorHandler = errorHandler;
            updateWorkingRange();

            _isIncluded = prarentMacros !is null;
            if(_isIncluded)
                _macros = prarentMacros;

            if(!_workingRange.empty)
                computeNext();
        }

        this(this)
        {
            updateWorkingRange();
        }

        private void updateWorkingRange()
        {
            _workingRange.mergeRange!(MacroPrefixRange, InputRange)(_macroPrefixRange, _input);
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

                    Macro* mPtr = idTokenValue(token) in _macros;

                    if(mPtr is null)
                        break;

                    auto m = *mPtr;

                    if(m.withArgs)
                    {
                        //auto lookAhead = _workingRange.save; // does not make an actual copy...
                        WorkingRange lookAhead;
                        auto tmp1 = _macroPrefixRange.save;
                        auto tmp2 = _input.save;
                        lookAhead.mergeRange!(MacroPrefixRange, InputRange)(tmp1, tmp2);

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
                            _macroPrefixRange.put(m.content);
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

                            _macroPrefixRange.put(newTokens.data);
                        }
                    }
                    else
                    {
                        _workingRange.popFront();
                        _macroPrefixRange.put(m.content);
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

                if(m.name in _macros && _macros[m.name] != m)
                    error(format!"macro `%s` redefined differently"(m.name), loc);

                _macros[m.name] = m;
            }
        }

        private void parseUndef(TokenLocation loc)
        {
            with(PpcTokenType)
            {
                auto noSpaceInput = refRange(&_workingRange).filter!(a => a.type != SPACING);

                if(noSpaceInput.empty || noSpaceInput.front.type != IDENTIFIER)
                    return directiveFailure("expecting identifier", currLoc(loc));

                _macros.remove(idTokenValue(noSpaceInput.front));
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
                    //auto lookAhead = _workingRange.save; // does not make an actual copy...
                    WorkingRange lookAhead;
                    auto tmp1 = _macroPrefixRange.save;
                    auto tmp2 = _input.save;
                    lookAhead.mergeRange!(MacroPrefixRange, InputRange)(tmp1, tmp2);

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

        // Parse a list of tokens glued by a specific type of token (specified in Args)
        // Token types and binary functions to call are specified in a list of pair of Args 
        // with the form (PpcTokenType, funcToCall)
        // A call to funcToCall is made for each glue token found (from left to right)
        private auto genEval(Range, alias evalFunc, Args...)(ref Range input, TokenLocation loc)
            if(Args.length >= 2 && Args.length % 2 == 0)
        {
            auto res = evalFunc(input, loc);

            while(!input.empty)
            {
                bool found = false;
                auto token = input.front;
                loc = token.location;

                static foreach(i ; iota(0, Args.length, 2))
                {{
                    if(token.type == Args[i])
                    {
                        input.popFront();
                        if(!input.empty)
                            loc = token.location;
                        res = binaryFun!(Args[i+1])(res, evalFunc(input, loc));
                        found = true;
                    }
                }}

                if(!found)
                    return res;
            }

            return res;
        }

        private long evalPrimaryExpr(Range)(ref Range input, TokenLocation loc)
        {
            if(input.empty)
            {
                error("unexpected end of expression", loc);
                return 0;
            }

            auto token = input.front;

            with(PpcTokenType)
            switch(token.type)
            {
                case IDENTIFIER:
                    auto name = idTokenValue(token);
                    input.popFront();

                    if(name != "defined")
                        return 0;

                    bool paren = input.skipIf!(a => a.type == LPAREN);

                    if(input.empty || input.front.type != IDENTIFIER)
                    {
                        error("missing macro name", input.bestLoc(loc));
                        return 0;
                    }

                    name = idTokenValue(input.front);
                    bool res = (name in _macros) != null;
                    input.popFront();

                    if(paren && !input.skipIf!(a => a.type == RPAREN))
                    {
                        error("expecting `)`", input.bestLoc(loc));
                        return 0;
                    }

                    return res;

                case CHARACTER:
                    auto value = token.value.get!PpcCharTokenValue.content;
                    input.popFront();
                    return cast(long)value;

                case NUMBER:
                    auto number = token.value.get!PpcNumberTokenValue.content;
                    auto first = number.front;
                    auto acc = appender!(char[]);
                    int base = 10;

                    number.popFront();
                    acc.put(first);

                    if(first != '0') // decimal
                        number.forwardWhile!isDigit(acc);
                    else if(number.skipIf!(a => a.among('x', 'X'))) // hexadecimal
                        number.forwardWhile!isHexDigit(acc), base = 16;
                    else // octal
                        number.forwardWhile!isOctalDigit(acc), base = 8;

                    static immutable auto suffix = ["u", "U", "ul", "lu", "UL", "LU", "l", "L"];
                    auto id = number.startsWithAmong!suffix;
                    if(id >= 0)
                        number.popFrontExactly(suffix[id].length);

                    input.popFront();

                    if(!first.isDigit || !number.empty)
                    {
                        error("invalid preprocessing integer", input.bestLoc(loc));
                        return 0;
                    }

                    pragma(msg, "[BUG] ldc 1.8.0 throw an ConvOverflowException with to!long(0, 8)");
                    if(acc.data == "0")
                        return 0;

                    try
                    {
                        return acc.data.to!long(base);
                    }
                    catch(ConvOverflowException)
                    {
                        error("preprocessing integer overflow", input.bestLoc(loc));
                        return 0;
                    }

                case LPAREN:
                    input.popFront();

                    if(input.empty)
                    {
                        error("unexpected end of expression", input.bestLoc(loc));
                        return 0;
                    }

                    auto res = evalConstExpr(input, input.front.location);

                    if(!input.skipIf!(a => a.type == RPAREN))
                    {
                        error("expecting `)`", input.bestLoc(loc));
                        return 0;
                    }

                    return res;

                default:
                    error(format!"invalid preprocessor expression token `%s`"(input.front.to!string), input.bestLoc(loc));
                    input.popFront();
                    return 0;
            }
        }

        private auto evalUnaryExpr(Range)(ref Range input, TokenLocation loc)
        {
            with(PpcTokenType)
            {
                auto acc = appender!(PpcToken[]);
                input.forwardWhile!(a => a.type.among(OP_ADD, OP_SUB, OP_BNOT, OP_NOT))(acc);
                auto res = evalPrimaryExpr(input, loc);

                foreach_reverse(token ; acc.data)
                {
                    switch(token.type)
                    {
                        case OP_ADD: res = +res; break;
                        case OP_SUB: res = -res; break;
                        case OP_BNOT: res = ~res; break;
                        case OP_NOT: res = res ? 0 : 1; break;
                        default: throw new Exception("programming error");
                    }
                }

                return res;
            }
        }

        private auto check(alias op)(long a, long b)
        {
            if(b != 0)
                return binaryFun!op(a, b);

            error("invalid division by 0", currLoc(TokenLocation()));
            return 0;
        }

        private auto evalMultiplicativeExpr(Range)(ref Range input, TokenLocation loc)
        {
            with(PpcTokenType)
            return genEval!(Range, evalUnaryExpr, 
                            OP_MUL, "a*b", OP_DIV, check!"a/b", OP_MOD, check!"a%b")(input, loc);
        }

        private auto evalAdditiveExpr(Range)(ref Range input, TokenLocation loc)
        {
            with(PpcTokenType)
            return genEval!(Range, evalMultiplicativeExpr,
                            OP_ADD, "a+b", OP_SUB, "a-b")(input, loc);
        }

        private auto evalShiftExpr(Range)(ref Range input, TokenLocation loc)
        {
            with(PpcTokenType)
            return genEval!(Range, evalAdditiveExpr, 
                            OP_LSHIFT, "a<<b", OP_RSHIFT, "a>>b")(input, loc);
        }

        private auto evalRelationalExpr(Range)(ref Range input, TokenLocation loc)
        {
            with(PpcTokenType)
            return genEval!(Range, evalShiftExpr, 
                            OP_LE, "(a<=b)?1:0", OP_LT, "(a<b)?1:0", 
                            OP_GE, "(a>=b)?1:0", OP_GT, "(a>b)?1:0")(input, loc);
        }

        private auto evalEqualityExpr(Range)(ref Range input, TokenLocation loc)
        {
            with(PpcTokenType)
            return genEval!(Range, evalRelationalExpr, 
                            OP_EQ, "(a==b)?1:0", OP_NE, "(a!=b)?1:0")(input, loc);
        }

        private auto evalAndExpr(Range)(ref Range input, TokenLocation loc)
        {
            with(PpcTokenType)
            return genEval!(Range, evalEqualityExpr, OP_BAND, "a&b")(input, loc);
        }

        private auto evalBinaryXorExpr(Range)(ref Range input, TokenLocation loc)
        {
            with(PpcTokenType)
            return genEval!(Range, evalAndExpr, OP_BXOR, "a^b")(input, loc);
        }

        private auto evalBinaryOrExpr(Range)(ref Range input, TokenLocation loc)
        {
            with(PpcTokenType)
            return genEval!(Range, evalBinaryXorExpr, OP_BOR, "a|b")(input, loc);
        }

        private auto evalLogicalAndExpr(Range)(ref Range input, TokenLocation loc)
        {
            with(PpcTokenType)
            return genEval!(Range, evalBinaryOrExpr, OP_AND, "(a&&b)?1:0")(input, loc);
        }

        private auto evalLogicalOrExpr(Range)(ref Range input, TokenLocation loc)
        {
            with(PpcTokenType)
            return genEval!(Range, evalLogicalAndExpr, OP_OR, "(a||b)?1:0")(input, loc);
        }

        private long evalConstExpr(Range)(ref Range input, TokenLocation loc)
        {
            auto condRes = evalLogicalOrExpr(input, loc);

            if(!input.skipIf!(a => a.type == PpcTokenType.QMARK))
                return condRes;

            if(input.empty)
                loc = input.front.location;

            auto left = evalConstExpr(input, loc);

            if(input.empty)
            {
                error("unexpected end of expression", loc);
                return 0;
            }

            if(!input.skipIf!(a => a.type == PpcTokenType.COL))
                error("unexpected token", input.front.location);

            if(input.empty)
                loc = input.front.location;

            auto right = evalConstExpr(input, loc);
            return condRes ? left : right;
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
                    keepGroup = evalConstExpr(expr, expr.bestLoc(loc)) != 0;

                    if(!expr.empty)
                        error(format!"missing binary operator before `%s`"(expr.front.to!string), expr.bestLoc(loc));

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
                            keepGroup = (name in _macros) !is null;
                        else
                            keepGroup = (name in _macros) is null;

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

        // Note: copying included range directly is forbidden
        pragma(msg, "[FIXME] implement a resource manager to load files once while enabling look-ahead");
        @property Result save()
        {
            Result result = this;
            result._input = _input.save;
            result._macroPrefixRange = _macroPrefixRange.save;

            if(!_isIncluded)
                result._macros = _macros.dup;

            result._includeRange = new Result[_includeRange.length];

            foreach(ref r ; result._includeRange)
            {
                r = r.save;
                r._macros = result._macros;
            }

            result._conditionalStates = _conditionalStates.dup;
            result.updateWorkingRange();
            return result;
        }
    }

    // May consume more char than requested
    // Cannot take an InputRange as input due to look-ahead parsing
    auto preprocess(InputRange)(InputRange input, IErrorHandler errorHandler, Macro[string] prarentMacros = null)
        if(isForwardRange!InputRange && is(ElementType!InputRange : PpcToken))
    {
        return Result(input, errorHandler, prarentMacros);
    };
}

// May consume more char than requested
// Cannot take an InputRange as input due to look-ahead parsing
auto preprocess(InputRange)(InputRange input, IErrorHandler errorHandler, Macro[string] prarentMacros = null)
    if(isForwardRange!InputRange && is(ElementType!InputRange : PpcToken))
{
    return Preprocess!InputRange.Result(input, errorHandler, prarentMacros);
};
