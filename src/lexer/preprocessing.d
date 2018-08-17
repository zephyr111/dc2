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
import interfaces : IErrorHandler;
import types;
import utils;
import locationTracking; // for #include
import trigraphSubstitution; // for #include
import lineSplicing; // for #include
import ppcTokenization; // for #include
import parsing;
import macros;


private auto bestLoc(Range)(Range input, TokenLocation fallbackLocation)
    if(isInputRange!Range && is(ElementType!Range : PpcToken))
{
    if(!input.empty)
        return input.front.location;
    return fallbackLocation;
}

pragma(msg, "[OPTIM] avoid/rewrite findSkip since it call save internally (not needed)");
private template Preprocess(InputRange)
{
    static struct Result
    {
        struct ConditionalState
        {
            bool ifPart; // include #if, #ifdef, #ifndef and #elif
            bool evaluated;
        };

        alias This = typeof(this);
        alias WorkingRange = MacroRange!(LookAheadRange!InputRange);
        pragma(msg, "[WTF] using BufferedStack!Result cause the LDC compiler to crash...");
        alias IncludeRange = Result[];

        private WorkingRange _workingRange;
        private IncludeRange _includeRange;
        private IErrorHandler _errorHandler;
        private Nullable!PpcToken _result;
        private MacroDb _macros;
        private bool _isIncluded;
        private bool _lineStart = true;
        private SList!ConditionalState _conditionalStates;
        private const int _nestingLevel;

        this(InputRange input, IErrorHandler errorHandler, MacroDb parentMacros, int nestingLevel)
        {
            _workingRange = WorkingRange(lookAhead(input));
            _errorHandler = errorHandler;
            _nestingLevel = nestingLevel;

            _isIncluded = parentMacros !is null;
            if(_isIncluded)
                _macros = parentMacros;
            else
                _macros = new MacroDb();

            if(!_workingRange.empty)
                computeNext();
        }

        private auto idTokenValue(PpcToken token)
        {
            return token.value.get!PpcIdentifierTokenValue.name;
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

        // Parse an #include preprocessing directive and save the resulting
        // sub-range for that the included tokens can be forwarded later
        private void parseInclude(TokenLocation loc)
        {
            with(PpcTokenType)
            {
                _workingRange.findSkip!(a => a.type == SPACING);
                _workingRange.macroSubstitution(_macros, _errorHandler);

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

                // Avoid runaway recursion
                if(_nestingLevel >= 200)
                    return directiveFailure("#include nested too deeply", currLoc(loc));

                auto range = dstr.trackLocation(filename)
                                    .substituteTrigraph
                                    .spliceLines
                                    .ppcTokenize(_errorHandler)
                                    .preprocess(_errorHandler, _macros, _nestingLevel+1);

                if(!range.empty)
                    _includeRange ~= range;
            }
        }

        // Parse a #define preprocessing directive
        // and update the macro database
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

                auto mOld = _macros.get(m.name, loc);

                if(!mOld.isNull && mOld.get != m)
                    error(format!"macro `%s` redefined differently"(m.name), loc);
                else if(!mOld.isNull && mOld.predefined)
                    error(format!"redefining the built-in macro `%s`"(m.name), loc);

                _macros.set(m);
            }
        }

        // Parse an #undef preprocessing directive
        // and update the macro database
        private void parseUndef(TokenLocation loc)
        {
            with(PpcTokenType)
            {
                auto noSpaceInput = refRange(&_workingRange).filter!(a => a.type != SPACING);
                loc = currLoc(loc);

                if(noSpaceInput.empty || noSpaceInput.front.type != IDENTIFIER)
                    return directiveFailure("expecting identifier", loc);

                string macroName = idTokenValue(noSpaceInput.front);

                auto m = _macros.get(noSpaceInput.front);

                if(!m.isNull)
                {
                    if(m.get.predefined)
                        error(format!"undefining the built-in macro `%s`"(m.name), loc);

                    _macros.remove(m);
                }

                noSpaceInput.popFront();
            }
        }

        // Skip a group of token enclosed by #if directives
        private void skipGroup(TokenLocation loc)
        {
            with(PpcTokenType)
            {
                SList!bool condStates;
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

                    switch(name)
                    {
                        case "if":
                        case "ifdef":
                        case "ifndef":
                            condStates.insertFront(true);
                            break;

                        case "elif":
                        case "else":
                            if(condStates.empty)
                                return;
                            if(!condStates.front)
                                return epicFailure(format!"#%s without #if"(name), lookAhead.bestLoc(loc));
                            condStates.front = name == "elif";
                            break;

                        case "endif":
                            if(condStates.empty)
                                return;
                            condStates.removeFront();
                            break;

                        default:
                            break;
                    }

                    _workingRange = lookAhead;
                    _workingRange.findSkip!(a => a.type != NEWLINE);

                    if(_workingRange.empty)
                        return epicFailure("unterminated group", loc);
                }
            }
        }

        // Parse a #if-like preprocessing directive
        // Evaluate #if/#elif expressions and skip the block when required
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
                                _workingRange.macroSubstitution(_macros, _errorHandler);
                            else
                                macroSubstitution = true;
                        }

                        _workingRange.forwardIf!(a => a.type != SPACING)(acc);
                        _workingRange.skipIf!(a => a.type == SPACING);
                    }

                    auto expr = acc.data;
                    keepGroup = expr.evalConstantExpression(_errorHandler, _macros, expr.bestLoc(loc));

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

                        keepGroup = _macros.canFind(name);

                        static if(type == "ifndef")
                            keepGroup = !keepGroup;

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

        // Parse a #warning or an #error preprocessing directive
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

        // Parse a #pragma preprocessing directive
        private void parsePragma(TokenLocation loc)
        {
            _errorHandler.warning("ignored pragma", loc.filename, loc.line, loc.col);
            _workingRange.findSkip!(a => a.type != PpcTokenType.NEWLINE);
        }

        // Parse any preprocessing directive
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
                    _workingRange.macroSubstitution(_macros, _errorHandler);

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
        @property This save()
        {
            This result = this;
            result._workingRange = _workingRange.save;

            if(!_isIncluded)
                result._macros = result._macros.dup;

            result._includeRange = new This[_includeRange.length];

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
    // Perform a look-ahead parsing
    auto preprocess(InputRange)(InputRange input, IErrorHandler errorHandler, MacroDb parentMacros, int nestingLevel = 0)
        if(isInputRange!InputRange && is(ElementType!InputRange : PpcToken))
    {
        return Result(input, errorHandler, parentMacros, nestingLevel);
    };
}

// May consume more char than requested
// Perform a look-ahead parsing
auto preprocess(InputRange)(InputRange input, IErrorHandler errorHandler, MacroDb parentMacros = null)
    if(isInputRange!InputRange && is(ElementType!InputRange : PpcToken))
{
    return Preprocess!InputRange.Result(input, errorHandler, parentMacros, 0);
};

