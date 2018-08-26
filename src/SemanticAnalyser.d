module SemanticAnalyser;

import std.stdio;
import interfaces;


class SemanticAnalyser : ISemanticAnalyser
{
    private
    {
        IParser _parser;
        IErrorHandler _errorHandler;
    }

    this(IParser parser, IErrorHandler errorHandler)
    {
        _parser = parser;
        _errorHandler = errorHandler;
    }
}

