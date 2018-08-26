module lexer.parsing;

import std.stdio;
import std.range;
import std.range.primitives;
import std.algorithm.comparison;
import std.algorithm.searching;
import std.traits;
import std.exception;
import std.format;
import std.ascii;
import std.conv;
import std.meta;
import std.functional;
import interfaces : IErrorHandler;
import lexer.types;
import lexer.macros;
import utils;


private static class EvalException : Exception
{
    TokenLocation _location;
    bool _withLocation;

    this(string msg, TokenLocation loc, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
        _location = loc;
        _withLocation = true;
    }

    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
        _withLocation = false;
    }
}

private static void epicFailure(string msg)
{
    throw new EvalException(msg);
}

private static void epicFailureEx(string msg, TokenLocation loc)
{
    throw new EvalException(msg, loc);
}

// Type of values use to evaluate preprocessing expresion
pragma(msg, "[OPTION] prefer warnings rather than errors");
private static struct PpcValue
{
    alias This = typeof(this);

    union Value
    {
        long signed = 0;
        ulong unsigned;
    };

    bool _isSigned = true;
    Value _value;

    this(T)(T val, bool isSigned)
        if(isIntegral!T)
    {
        _isSigned = isSigned;

        if(isSigned)
            _value.signed = val;
        else
            _value.unsigned = val;
    }

    this(bool val)
    {
        this(val ? 1 : 0, true);
    }

    this(T : This)(auto ref const T other)
    {
        _isSigned = other._isSigned;
        _value = other._value;
    }

    This opUnary(string op)() const
        if(["-", "+", "~"].canFind(op))
    {
        if(_isSigned)
            return This(mixin(op ~ "_value.signed"), true);
        return This(mixin(op ~ "_value.unsigned"), false);
    }

    T opCast(T)() const
        if(isIntegral!T || is(T == bool))
    {
        if(_isSigned)
            return cast(T)_value.signed;
        return cast(T)_value.unsigned;
    }

    This opBinary(string op)(This rhs) const
        if(["+", "-", "<<", ">>", "*", "/", "%", "&", "|", "^", "&&", "||"].canFind(op))
    {
        bool signedResult = _isSigned && rhs._isSigned;

        if(_isSigned && _value.signed < 0 && !rhs._isSigned)
            epicFailure("left side of operator converted from negative value to unsigned");
        else if(rhs._isSigned && rhs._value.signed < 0 && !_isSigned)
            epicFailure("right side of operator converted from negative value to unsigned");

        if(op.among("/", "%") && rhs._value.signed == 0)
            epicFailure("integer overflow in preprocessor expression");
        if(op.among("<<", ">>") && signedResult && rhs._value.signed < 0)
            epicFailure("invalid shift in preprocessor expression");

        if(signedResult)
            return This(mixin("_value.signed" ~ op ~ "rhs._value.signed"), true);
        return This(mixin("_value.unsigned" ~ op ~ "rhs._value.unsigned"), false);
    }

    bool opEquals(T : This)(auto ref const T rhs) const
    {
        return opCmp(rhs) == 0;
    }

    int opCmp(T : This)(auto ref const T rhs) const
    {
        if(_isSigned && _value.signed < 0 && !rhs._isSigned)
            epicFailure("left side of operator converted from negative value to unsigned");
        else if(rhs._isSigned && rhs._value.signed < 0 && !_isSigned)
            epicFailure("right side of operator converted from negative value to unsigned");

        if(_value.signed == rhs._value.signed)
            return 0;
        else if(_isSigned && rhs._isSigned)
            return (_value.signed > rhs._value.signed) ? 1 : -1;
        return (_value.unsigned > rhs._value.unsigned) ? 1 : -1;
    }
}

private static struct Parser(Range)
{
    private RefRange!Range _input;
    private IErrorHandler _errorHandler;
    private MacroDb _macros;

    this(ref Range input, IErrorHandler errorHandler, MacroDb macros)
    {
        _input = &input;
        _errorHandler = errorHandler;
        _macros = macros;
    }

    private auto idTokenValue(PpcToken a)
    {
        return a.value.get!PpcIdentifierTokenValue.name;
    }

    private auto currLoc(TokenLocation fallbackLocation)
    {
        if(!_input.empty)
            return _input.front.location;
        return fallbackLocation;
    }

    // Parse a list of tokens glued by a specific type of token (specified in Args)
    // Token types and binary functions to call are specified in a list of pair of Args 
    // with the form (PpcTokenType, funcToCall)
    // A call to funcToCall is made for each glue token found (from left to right)
    private auto genEval(alias evalFunc, Args...)(TokenLocation loc)
        if(Args.length >= 2 && Args.length % 2 == 0)
    {
        auto res = evalFunc(loc);

        while(!_input.empty)
        {
            bool found = false;
            auto token = _input.front;
            loc = token.location;

            static foreach(i ; iota(0, Args.length, 2))
            {{
                if(token.type == Args[i])
                {
                    _input.popFront();

                    if(!_input.empty)
                        loc = token.location;

                    //res = PpcValue(binaryFun!(Args[i+1])(res, tmp));
                    static if(is(typeof(Args[i+1]) == string))
                    {
                        auto a = res;
                        auto b = evalFunc(loc);
                        res = PpcValue(mixin(Args[i+1]));
                    }
                    else
                    {
                        res = PpcValue(Args[i+1](res, evalFunc(loc)));
                    }

                    found = true;
                }
            }}

            if(!found)
                return res;
        }

        return res;
    }

    private auto evalPrimaryExpr(TokenLocation loc)
    {
        if(_input.empty)
            epicFailure("unexpected end of expression");

        auto token = _input.front;

        with(PpcTokenType)
        switch(token.type)
        {
            case IDENTIFIER:
                auto name = idTokenValue(token);
                _input.popFront();

                if(name != "defined")
                    return PpcValue();

                bool paren = _input.skipIf!(a => a.type == LPAREN);

                if(_input.empty || _input.front.type != IDENTIFIER)
                    epicFailure("missing macro name");

                name = idTokenValue(_input.front);
                bool res = _macros.canFind(name);
                _input.popFront();

                if(paren && !_input.skipIf!(a => a.type == RPAREN))
                    epicFailure("expecting `)`");

                return PpcValue(res);

            case CHARACTER:
                auto value = token.value.get!PpcCharTokenValue.content;
                _input.popFront();
                return PpcValue(cast(long)value, true);

            case NUMBER:
                auto number = token.value.get!PpcNumberTokenValue.content;
                auto first = number.front;
                auto acc = appender!(char[]);
                int base = 10;

                number.popFront();

                if(first != '0') // decimal
                    acc.put(first), number.forwardWhile!isDigit(acc);
                else if(number.skipIf!(a => a.among('x', 'X'))) // hexadecimal
                    number.forwardWhile!isHexDigit(acc), base = 16;
                else // octal
                    acc.put(first), number.forwardWhile!isOctalDigit(acc), base = 8;

                enum suffix = ["u", "U", "ul", "lu", "UL", "LU", "l", "L"];
                auto id = number.startsWithAmong!suffix;
                if(id >= 0)
                    number.popFrontExactly(suffix[id].length);

                _input.popFront();

                if(!first.isDigit || !number.empty)
                    epicFailureEx("invalid preprocessing integer", loc);

                pragma(msg, "[BUG] ldc 1.8.0 throw an ConvOverflowException with to!long(0, 8)");
                if(acc.data == "0")
                    return PpcValue(0, id < 0 || id >= 6);

                try
                {
                    if(id >= 0 && id < 6)
                        return PpcValue(acc.data.to!ulong(base), false);
                    else
                        return PpcValue(acc.data.to!long(base), true);
                }
                catch(ConvOverflowException)
                {
                    epicFailureEx("preprocessing integer overflow", loc);
                }

                return PpcValue();

            case LPAREN:
                _input.popFront();

                if(_input.empty)
                    epicFailure("unexpected end of expression");

                auto res = evalConstExpr(_input.front.location);

                if(!_input.skipIf!(a => a.type == RPAREN))
                    epicFailure("expecting `)`");

                return res;

            default:
                auto elem = _input.front.to!string;
                epicFailure(format!"invalid preprocessor expression token `%s`"(elem));
                return PpcValue();
        }
    }

    private auto evalUnaryExpr(TokenLocation loc)
    {
        with(PpcTokenType)
        {
            auto acc = appender!(PpcToken[]);
            _input.forwardWhile!(a => a.type.among(OP_ADD, OP_SUB, OP_BNOT, OP_NOT))(acc);
            auto res = evalPrimaryExpr(loc);

            foreach_reverse(token ; acc.data)
            {
                switch(token.type)
                {
                    case OP_ADD: res = +res; break;
                    case OP_SUB: res = -res; break;
                    case OP_BNOT: res = ~res; break;
                    case OP_NOT: res = PpcValue(!res); break;
                    default: throw new Exception("programming error");
                }
            }

            return res;
        }
    }

    private auto check(alias op)(PpcValue a, PpcValue b)
    {
        if(b != PpcValue(0, true))
            return binaryFun!op(a, b);

        epicFailure("invalid division by 0");
        return PpcValue();
    }

    private auto evalMultiplicativeExpr(TokenLocation loc)
    {
        with(PpcTokenType)
        return genEval!(evalUnaryExpr, OP_MUL, "a*b",
                        OP_DIV, check!"a/b", OP_MOD, check!"a%b")(loc);
    }

    private auto evalAdditiveExpr(TokenLocation loc)
    {
        with(PpcTokenType)
        return genEval!(evalMultiplicativeExpr,
                        OP_ADD, "a+b", OP_SUB, "a-b")(loc);
    }

    private auto evalShiftExpr(TokenLocation loc)
    {
        with(PpcTokenType)
        return genEval!(evalAdditiveExpr, 
                        OP_LSHIFT, "a<<b", OP_RSHIFT, "a>>b")(loc);
    }

    private auto evalRelationalExpr(TokenLocation loc)
    {
        with(PpcTokenType)
        return genEval!(evalShiftExpr, 
                        OP_LE, "a<=b", OP_LT, "a<b", 
                        OP_GE, "a>=b", OP_GT, "a>b")(loc);
    }

    private auto evalEqualityExpr(TokenLocation loc)
    {
        with(PpcTokenType)
        return genEval!(evalRelationalExpr, 
                        OP_EQ, "a==b", OP_NE, "a!=b")(loc);
    }

    private auto evalAndExpr(TokenLocation loc)
    {
        with(PpcTokenType)
        return genEval!(evalEqualityExpr, OP_BAND, "a&b")(loc);
    }

    private auto evalBinaryXorExpr(TokenLocation loc)
    {
        with(PpcTokenType)
        return genEval!(evalAndExpr, OP_BXOR, "a^b")(loc);
    }

    private auto evalBinaryOrExpr(TokenLocation loc)
    {
        with(PpcTokenType)
        return genEval!(evalBinaryXorExpr, OP_BOR, "a|b")(loc);
    }

    private auto evalLogicalAndExpr(TokenLocation loc)
    {
        with(PpcTokenType)
        return genEval!(evalBinaryOrExpr, OP_AND, "a&&b")(loc);
    }

    private auto evalLogicalOrExpr(TokenLocation loc)
    {
        with(PpcTokenType)
        return genEval!(evalLogicalAndExpr, OP_OR, "a||b")(loc);
    }

    private PpcValue evalConstExpr(TokenLocation loc)
    {
        auto condRes = evalLogicalOrExpr(loc);

        if(!_input.skipIf!(a => a.type == PpcTokenType.QMARK))
            return condRes;

        if(_input.empty)
            loc = _input.front.location;

        auto left = evalConstExpr(loc);

        if(_input.empty)
            epicFailure("unexpected end of expression");

        if(!_input.skipIf!(a => a.type == PpcTokenType.COL))
            epicFailure("unexpected token");

        if(_input.empty)
            loc = _input.front.location;

        auto right = evalConstExpr(loc);
        return condRes ? left : right;
    }

    bool eval(TokenLocation loc)
    {
        try
        {
            auto res = cast(bool)evalConstExpr(loc);

            if(!_input.empty)
            {
                auto elem = _input.front.to!string;
                auto errMsg = format!"missing binary operator before `%s`"(elem);
                auto errLoc = currLoc(loc);
                _errorHandler.error(errMsg, errLoc.filename, errLoc.line, errLoc.col);
            }

            return res;
        }
        catch(EvalException e)
        {
            TokenLocation errLoc = e._location;
            if(!e._withLocation)
                errLoc = currLoc(loc);
            _errorHandler.error(e.msg, errLoc.filename, errLoc.line, errLoc.col);
            return false;
        }
    }
}

// Parse a preprocessing constant expression (found in #if/#elif directives)
// May consume less char than provided when an error occurs
bool evalConstantExpression(Range)(ref Range input, 
                                    IErrorHandler errorHandler, 
                                    MacroDb macros, 
                                    TokenLocation loc = TokenLocation())
    if(isInputRange!Range && is(ElementType!Range : PpcToken))
{
    auto parser = Parser!Range(input, errorHandler, macros);
    return parser.eval(loc);
};

