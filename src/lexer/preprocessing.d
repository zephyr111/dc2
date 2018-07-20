import std.stdio;
import std.range;
import std.range.primitives;
import std.traits;
import std.algorithm.comparison;
import std.algorithm.searching;
import std.algorithm.iteration;
import std.typecons;
import std.exception;
import std.string;
import std.conv;
import interfaces : IErrorHandler;
import types;
import utils;


// May consume more char than requested
// Cannot take an InputRange as input due to look-ahead parsing
auto preprocess(Range)(Range input, IErrorHandler errorHandler)
    if(isForwardRange!Range && is(ElementType!Range : PpcToken))
{
    struct Result
    {
        private Range _input;
        private IErrorHandler _errorHandler;
        private Nullable!PpcToken _result;

        this(Range input, IErrorHandler errorHandler)
        {
            _input = input;
            _errorHandler = errorHandler;

            if(!_input.empty)
                computeNext();
        }

        private void computeNext()
        {
            auto check = (long e, string str) => enforce!LexerException(e, str);
            auto msgUnterm = "unterminated preprocessing directive";
            auto msgMalformed = "malformed preprocessing directive";
            auto msgUnknown = "unknown preprocessing directive";

            auto startLoc = _input.front.location;

            try
            {
                pragma(msg, "[FIXME] a preprocessing directive must start with a [NEWLINE]");
                while(_input.front.type == PpcTokenType.SHARP)
                {
                    startLoc = _input.front.location;

                    _input.popFront();

                    _input.findSkip!(a => a.type == PpcTokenType.SPACING);
                    check(!_input.empty, msgUnterm);

                    auto tmp = _input.front;

                    if(tmp.type == PpcTokenType.NEWLINE)
                        continue;

                    check(tmp.type == PpcTokenType.IDENTIFIER, msgMalformed);
                    string name = tmp.value.get!PpcIdentifierTokenValue.name;
                    _input.popFront();

                    pragma(msg, "[FIXME] support include, define/undef and if/ifdef/else/...");
                    switch(name)
                    {
                        case "include":
                            writeln("[ignored include]");
                            break;
                        case "define":
                            writeln("[ignored define]");
                            break;
                        case "undef":
                            writeln("[ignored undef]");
                            break;
                        case "if":
                            writeln("[ignored if]");
                            break;
                        case "ifdef":
                            writeln("[ignored ifdef]");
                            break;
                        case "ifndef":
                            writeln("[ignored ifndef]");
                            break;
                        case "else":
                            writeln("[ignored else]");
                            break;
                        case "elif":
                            writeln("[ignored elif]");
                            break;
                        case "endif":
                            writeln("[ignored endif]");
                            break;
                        case "warning":
                        case "error":
                            auto tokenToPrint = _input.until!(a => a.type == PpcTokenType.NEWLINE);
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
                            _errorHandler.error(msgUnknown, startLoc.filename, startLoc.line, startLoc.col);
                            _result = Nullable!PpcToken();
                            return;
                    }

                    _input.findSkip!(a => a.type != PpcTokenType.NEWLINE);
                    check(_input.skipOver!(a => a.type == PpcTokenType.NEWLINE), msgMalformed);

                    if(_input.empty)
                    {
                        _result = Nullable!PpcToken();
                        return;
                    }
                }

                pragma(msg, "[FIXME] support macro replacement");

                _result = _input.front.nullable;
                _input.popFront();
            }
            catch(LexerException err)
            {
                _result = Nullable!PpcToken();
                _errorHandler.error(err.msg, startLoc.filename, 
                                    startLoc.line, startLoc.col);
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
            if(_input.empty)
                _result = Nullable!PpcToken();
            else
                computeNext();
        }

        pragma(msg, "[FIXME] implement a resource manager to load files once while enabling look-ahead");
        @property auto save()
        {
            Result result = this;
            result._input = _input.save;
            return result;
        }
    }

    return Result(input, errorHandler);
}


