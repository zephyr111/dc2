module parser;

import std.stdio;
import std.typecons;
import interfaces;
import parser.types;
import utils;


// Transform a ILexer to a usual input range
private struct LexerRange
{
    private
    {
        alias This = typeof(this);

        ILexer _lexer;
        Nullable!(LexerToken) _result;
    }


    this(ILexer lexer)
    {
        _lexer = lexer;
        _result = _lexer.next();
    }

    @property bool empty()
    {
        return _result.isNull;
    }

    @property auto front()
    {
        assert(!_result.isNull);
        return _result.get;
    }

    void popFront()
    {
        if(_result.isNull)
            _result = _lexer.next();
    }
}

// Type aware lexing range
private struct TypedLexerRange(Range)
{
    private
    {
        alias This = typeof(this);

        ParserTokenType[string] _types;
        Range _input;
        LexerToken _result;
    }


    this(Range input)
    {
        _input = input;
    }

    void addTypename(string name)
    {
        _types[name] = ParserTokenType.TYPE_NAME;
    }

    void addEnum(string name)
    {
        _types[name] = ParserTokenType.ENUM_VALUE;
    }

    void removeTypename(string name)
    {
        assert(name in _types && _types[name] == ParserTokenType.TYPE_NAME);
        _types.remove(name);
    }

    void removeEnum(string name)
    {
        assert(name in _types && _types[name] == ParserTokenType.ENUM_VALUE);
        _types.remove(name);
    }

    @property bool empty()
    {
        return _input.empty;
    }

    @property auto front()
    {
        assert(!_input.empty);
        auto res = _input.front;

        if(res.type == LexerTokenType.IDENTIFIER)
        {
            auto identifier = res.value.get!LexerIdentifierTokenValue.name;
            auto type = identifier in _types;

            if(type is null)
                return ParserToken(ParserTokenType.IDENTIFIER, res.location, res.value);

            return ParserToken(*type, res.location, res.value);
        }

        auto resType = res.type.convertEnum!(LexerTokenType, ParserTokenType,
                                                "NUMBER", "ERROR");
        return ParserToken(resType, res.location, res.value);
    }

    void popFront()
    {
        assert(!_input.empty);
        return _input.popFront;
    }
}

class Parser : IParser, IGo
{
    private
    {
        TypedLexerRange!LexerRange _lexer;
        IErrorHandler _errorHandler;
    }


    this(ILexer lexer, IErrorHandler errorHandler)
    {
        _lexer = TypedLexerRange!LexerRange(LexerRange(lexer));
        _errorHandler = errorHandler;
    }

    override void go()
    {
        // To be continued...
    }
}

