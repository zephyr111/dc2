import std.stdio;
import std.range;
import std.range.primitives;
import std.traits;
import std.algorithm.comparison;
import std.algorithm.searching;
import std.typecons;
import std.ascii;
import std.conv;
import std.exception;
import std.format;
import interfaces : IErrorHandler;
import types;
import utils;


// May consume more char than requested
// Cannot take an InputRange as input due to look-ahead parsing
auto stdTokenize(Range)(Range input, IErrorHandler errorHandler)
    if(isForwardRange!Range && is(ElementType!Range : PpcToken))
{
    struct Result
    {
        static private StdTokenType[string] keywords;

        private Range _input;
        private IErrorHandler _errorHandler;
        private Nullable!StdToken _result;

        static this()
        {
            with(StdTokenType)
            {
                keywords = [
                    "auto": AUTO, "break": BREAK, "case": CASE, "char": CHAR,
                    "const": CONST, "continue": CONTINUE, "default": DEFAULT, "do": DO,
                    "double": DOUBLE, "else": ELSE, "enum": ENUM, "extern": EXTERN,
                    "float": FLOAT, "for": FOR, "goto": GOTO, "if": IF,
                    "int": INT, "long": LONG, "register": REGISTER, "return": RETURN,
                    "short": SHORT, "signed": SIGNED, "sizeof": SIZEOF, "static": STATIC,
                    "struct": STRUCT, "switch": SWITCH, "typedef": TYPEDEF, "union": UNION,
                    "unsigned": UNSIGNED, "void": VOID, "volatile": VOLATILE, "while": WHILE,
                ];
            }
        }

        this(Range input, IErrorHandler errorHandler)
        {
            _input = input;
            _errorHandler = errorHandler;

            if(!_input.empty)
                computeNext();
        }

        private auto tryParseFloat(Range)(ref Range input)
        {
            auto first = input.front;

            if(!first.isDigit && first != '.')
                return Nullable!StdTokenValue();

            auto lookAhead = input.save;

            static auto acc = appender!(char[]);
            acc.clear();

            long lLen = lookAhead.forwardWhile!isDigit(acc);
            bool isFractional = lookAhead.forwardIf!(a => a == '.')(acc);
            long rLen = isFractional ? lookAhead.forwardWhile!isDigit(acc) : 0;

            if(lLen+rLen == 0) // should be just a dot operator
                return Nullable!StdTokenValue();

            bool hasExponent = lookAhead.forwardIf!(a => a.among('e', 'E'))(acc);

            if(!isFractional && !hasExponent) // should be an integer
                return Nullable!StdTokenValue();

            if(hasExponent)
            {
                lookAhead.forwardIf!(a => a.among('+', '-'))(acc);
                long expLen = lookAhead.forwardWhile!isDigit(acc);

                if(expLen == 0)
                    return Nullable!StdTokenValue();
            }

            auto id = lookAhead.startsWithAmong!(["f", "F", "l", "L"]);
            if(id >= 0)
                lookAhead.popFront();

            input = lookAhead;

            // Note: identifier-like strings found just after without spaces produces a parse error

            return StdTokenValue(StdNumberTokenValue(id >= 2, acc.data.to!double)).nullable;
        }

        private auto tryParseInteger(Range)(ref Range input)
        {
            auto first = input.front;

            if(!first.isDigit)
                return Nullable!StdTokenValue();

            auto lookAhead = input.save;
            lookAhead.popFront();

            static immutable auto suffix = ["u", "U", "ul", "lu", "UL", "LU", "l", "L"];

            static auto acc = appender!(char[]);
            acc.clear();
            acc.put(first);

            int base = 10;

            if(first != '0') // decimal
                lookAhead.forwardWhile!isDigit(acc);
            else if(lookAhead.skipIf!(a => a.among('x', 'X'))) // hexadecimal
                lookAhead.forwardWhile!isHexDigit(acc), base = 16;
            else // octal
                lookAhead.forwardWhile!isOctalDigit(acc), base = 8;

            // Note: identifier-like strings found just after without spaces produces a parse error

            auto id = lookAhead.startsWithAmong!suffix;
            if(id >= 0)
                lookAhead.popFrontExactly(suffix[id].length);

            input = lookAhead;

            auto value = acc.data.to!long(base);
            return StdTokenValue(StdIntegerTokenValue(id >= 0 && id < 6, id >= 4, value)).nullable;
        }

        void computeNext()
        {
            _input.findSkip!(a => a.type.among(PpcTokenType.SPACING, PpcTokenType.NEWLINE));

            if(_input.empty)
            {
                _result = Nullable!StdToken();
                return;
            }

            auto first = _input.front;

            switch(first.type)
            {
                case PpcTokenType.IDENTIFIER:
                    string name = first.value.get!PpcIdentifierTokenValue.name;

                    if(name in keywords)
                    {
                        _result = StdToken(keywords[name], first.location);
                    }
                    else
                    {
                        auto value = StdIdentifierTokenValue(name);
                        _result = StdToken(StdTokenType.IDENTIFIER, first.location, StdTokenValue(value));
                    }
                    break;

                case PpcTokenType.NUMBER:
                    auto oldValue = first.value.get!PpcNumberTokenValue;
                    _result = StdToken(StdTokenType.ERROR, first.location);
                    auto value = Nullable!StdTokenValue();
                    if(!(value = tryParseFloat(oldValue.content)).isNull)
                        _result = StdToken(StdTokenType.FLOAT, first.location, value.get);
                    else if(!(value = tryParseInteger(oldValue.content)).isNull)
                        _result = StdToken(StdTokenType.INTEGER, first.location, value.get);
                    else
                        _errorHandler.error("unable to parse the number", first.location.filename,
                                            first.location.line, first.location.col);
                    break;

                case PpcTokenType.CHARACTER:
                    auto oldValue = first.value.get!PpcCharTokenValue;
                    auto newValue = StdCharTokenValue(oldValue.isWide, oldValue.content);
                    _result = StdToken(StdTokenType.CHARACTER, first.location, StdTokenValue(newValue));
                    break;

                case PpcTokenType.STRING:
                    auto oldValue = first.value.get!PpcStringTokenValue;
                    auto newValue = StdStringTokenValue(oldValue.isWide, oldValue.content);
                    _result = StdToken(StdTokenType.STRING, first.location, StdTokenValue(newValue));
                    break;

                case PpcTokenType.LPAREN: .. case PpcTokenType.XOR_ASSIGN:
                    pragma(msg, "[OPTION] Improve the automatic matching between XxxTokenType enums");
                    // Assume a full match between enums
                    static assert(is(OriginalType!PpcTokenType == int));
                    static assert(is(OriginalType!StdTokenType == int));
                    enum ppcStart = PpcTokenType.LPAREN.asOriginalType;
                    enum stdStart = StdTokenType.LPAREN.asOriginalType;
                    enum ppcEnd = PpcTokenType.XOR_ASSIGN.asOriginalType;
                    enum stdEnd = StdTokenType.XOR_ASSIGN.asOriginalType;
                    static assert(ppcEnd-ppcStart == stdEnd-stdStart);
                    auto type = cast(StdTokenType)(stdStart + (first.type.asOriginalType - ppcStart));
                    _result = StdToken(type, first.location);
                    break;

                case PpcTokenType.ERROR:
                    _result = StdToken(StdTokenType.ERROR, first.location);
                    break;

                case PpcTokenType.EOF:
                    _result = StdToken(StdTokenType.EOF, first.location);
                    break;

                default:
                    string msg = format!"unknown token type `%s`"(first.type);
                    _errorHandler.error(msg, first.location.filename,
                                        first.location.line, first.location.col);
                    _input.walkLength;
                    break;
            }

            _input.popFront();
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
                _result = Nullable!StdToken();
            else
                computeNext();
        }

        @property auto save()
        {
            Result result = this;
            result._input = _input.save;
            return result;
        }

        /*@property auto filename() { return _input.filename; }
        @property auto line() { return _input.line; }
        @property auto col() { return _input.col; }
        @property auto pos() { return _input.pos; }*/
    }

    return Result(input, errorHandler);
}


