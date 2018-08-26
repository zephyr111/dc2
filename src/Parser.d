module Parser;

import std.stdio;
import interfaces;


class Parser : IParser
{
    private
    {
        ILexer _lexer;
        IErrorHandler _errorHandler;
    }

    this(ILexer lexer, IErrorHandler errorHandler)
    {
        _lexer = lexer;
        _errorHandler = errorHandler;
    }
}

