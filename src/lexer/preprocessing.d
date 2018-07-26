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
import interfaces : IErrorHandler;
import types;
import utils;


// May consume more char than requested
// Cannot take an InputRange as input due to look-ahead parsing
auto preprocess(InputRange)(InputRange input, IErrorHandler errorHandler)
    if(isForwardRange!InputRange && is(ElementType!InputRange : PpcToken))
{
    struct Result
    {
        private struct Macro
        {
            string name;
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

        alias MacroPrefixRange = BufferedStack!(PpcToken[]);
        alias WorkingRange = MergeRange!(MacroPrefixRange, InputRange);

        private InputRange _input;
        private IErrorHandler _errorHandler;
        private Nullable!PpcToken _result;
        private Macro[string] _macros;
        private MacroPrefixRange _macroPrefixRange;
        //private IncludePrefixRange _includeRange;
        private WorkingRange _workingRange;
        private bool _lineStart = true;

        this(InputRange input, IErrorHandler errorHandler)
        {
            _input = input;
            _errorHandler = errorHandler;
            updateWorkingRange();

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

        private auto error(string msg, TokenLocation loc)
        {
            _errorHandler.error(msg, loc.filename, loc.line, loc.col);
        }

        private auto critical(string msg, TokenLocation loc)
        {
            _errorHandler.error(msg, loc.filename, loc.line, loc.col);
            _workingRange.findSkip!(a => a.type != PpcTokenType.NEWLINE);
        }

        private auto currLoc(TokenLocation fallbackLocation)
        {
            if(!_workingRange.empty)
                return _workingRange.front.location;
            return fallbackLocation;
        }

        private void parseDefine(TokenLocation loc)
        {
            with(PpcTokenType)
            {
                Macro m;

                _workingRange.findSkip!(a => a.type == SPACING);

                if(!_workingRange.forwardIf!(a => a.type == IDENTIFIER, (a) {m.name = idTokenValue(a);}))
                    return critical("expecting identifier", currLoc(loc));

                m.withArgs = _workingRange.skipIf!(a => a.type == LPAREN);

                auto noSpaceInput = refRange(&_workingRange).filter!(a => a.type != SPACING);

                if(m.withArgs && !noSpaceInput.skipIf!(a => a.type == RPAREN))
                {
                    auto acc = appender!(string[]);

                    if(!noSpaceInput.forwardIf!(a => a.type == IDENTIFIER, a => acc.put(idTokenValue(a))))
                        return critical("expecting identifier or `)`", currLoc(loc));

                    while(noSpaceInput.skipIf!(a => a.type == COMMA))
                        if(!noSpaceInput.forwardIf!(a => a.type == IDENTIFIER, a => acc.put(idTokenValue(a))))
                            return critical("expecting identifier", currLoc(loc));

                    if(!noSpaceInput.skipIf!(a => a.type == RPAREN))
                        return critical("expecting `,` or `)`", currLoc(loc));

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
                    return critical("expecting identifier", currLoc(loc));

                _macros.remove(idTokenValue(noSpaceInput.front));
                noSpaceInput.popFront();
            }
        }

        private void computeNext()
        {
            void error(string msg, TokenLocation loc)
            {
                _errorHandler.error(msg, loc.filename, loc.line, loc.col);
            }

            void critical(string msg, TokenLocation loc)
            {
                _errorHandler.error(msg, loc.filename, loc.line, loc.col);
                _result = Nullable!PpcToken();
            }

            with(PpcTokenType)
            {
                auto startLoc = _workingRange.front.location;

                if(_lineStart)
                {
                    while(_workingRange.front.type == SHARP)
                    {
                        startLoc = _workingRange.front.location;

                        _workingRange.popFront();

                        _workingRange.findSkip!(a => a.type == SPACING);

                        if(_workingRange.empty)
                            return critical("unterminated directive", startLoc);

                        auto tmp = _workingRange.front;

                        if(tmp.type == NEWLINE)
                            continue;

                        if(tmp.type != IDENTIFIER)
                            return critical("malformed directive", startLoc);

                        string name = idTokenValue(tmp);
                        _workingRange.popFront();

                        pragma(msg, "[FIXME] support include, define/undef and if/ifdef/else/...");
                        switch(name)
                        {
                            case "include":
                                writeln("[ignored include]");
                                _workingRange.findSkip!(a => a.type != NEWLINE);
                                break;

                            case "define": parseDefine(startLoc); break;
                            case "undef": parseUndef(startLoc); break;

                            case "if":
                                writeln("[ignored if]");
                                _workingRange.findSkip!(a => a.type != NEWLINE);
                                break;

                            case "ifdef":
                                writeln("[ignored ifdef]");
                                _workingRange.findSkip!(a => a.type != NEWLINE);
                                break;

                            case "ifndef":
                                writeln("[ignored ifndef]");
                                _workingRange.findSkip!(a => a.type != NEWLINE);
                                break;

                            case "else":
                                writeln("[ignored else]");
                                _workingRange.findSkip!(a => a.type != NEWLINE);
                                break;

                            case "elif":
                                writeln("[ignored elif]");
                                _workingRange.findSkip!(a => a.type != NEWLINE);
                                break;

                            case "endif":
                                writeln("[ignored endif]");
                                _workingRange.findSkip!(a => a.type != NEWLINE);
                                break;

                            case "warning":
                            case "error":
                                auto tokenToPrint = refRange(&_workingRange).until!(a => a.type == NEWLINE);
                                string msg = tokenToPrint.map!(a => a.toString).join.to!string.strip;
                                if(name == "warning")
                                    _errorHandler.warning(msg, startLoc.filename, startLoc.line, startLoc.col);
                                else
                                    _errorHandler.error(msg, startLoc.filename, startLoc.line, startLoc.col);
                                break;

                            case "pragma":
                                _errorHandler.warning("ignored pragma", startLoc.filename, startLoc.line, startLoc.col);
                                break;

                            default:
                                error("unknown directive", startLoc);
                                _workingRange.findSkip!(a => a.type != NEWLINE);
                                break;
                        }

                        if(!_workingRange.skipIf!(a => a.type == NEWLINE))
                        {
                            _workingRange.findSkip!(a => a.type != NEWLINE);
                            error("malformed directive", startLoc);
                        }

                        if(_workingRange.empty)
                        {
                            _result = Nullable!PpcToken();
                            return;
                        }
                    }
                }


                // Macro substitution

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

                        startLoc = _workingRange.front.location;

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
                                return critical("unterminated macro", startLoc);

                            params.put(param.data);
                        }
                        while(_workingRange.skipIf!(a => a.type == COMMA));

                        if(!_workingRange.skipIf!(a => a.type == RPAREN))
                            return critical("internal error", startLoc);

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

                if(_workingRange.empty)
                {
                    _result = Nullable!PpcToken();
                    return;
                }

                auto token = _workingRange.front;
                _result = token.nullable;
                _lineStart = token.type == NEWLINE || token.type == SPACING && _lineStart;
                _workingRange.popFront();
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

        pragma(msg, "[FIXME] implement a resource manager to load files once while enabling look-ahead");
        @property auto save()
        {
            Result result = this;
            result._input = _input.save;
            result._macroPrefixRange = _macroPrefixRange.save;
            result.updateWorkingRange();
            return result;
        }
    }

    return Result(input, errorHandler);
}


