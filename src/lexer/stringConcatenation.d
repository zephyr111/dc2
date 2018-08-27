module lexer.stringConcatenation;

import std.stdio;
import std.range;
import std.range.primitives;
import std.traits;
import std.typecons;
import interfaces : IErrorHandler;
import lexer.types;
import utils;


// May consume more char than requested
// Perform a look-ahead parsing
struct StringConcatenation(Range)
{
    private
    {
        alias This = typeof(this);

        LookAheadRange!Range _input;
        IErrorHandler _errorHandler;
    }


    this(Range input, IErrorHandler errorHandler)
    {
        _input = lookAhead(input);
        _errorHandler = errorHandler;
    }

    @property bool empty()
    {
        return _input.empty;
    }

    @property auto front()
    {
        auto firstToken = _input.front;

        if(firstToken.type != PpcTokenType.STRING)
            return firstToken;

        auto lookAhead = _input.save;
        lookAhead.popFront();

        auto accLength = firstToken.location.length;

        while(!lookAhead.empty && lookAhead.front.type == PpcTokenType.SPACING)
        {
            accLength += lookAhead.front.location.length;
            lookAhead.popFront();
        }

        if(lookAhead.empty)
            return firstToken;

        auto secondToken = lookAhead.front;

        if(firstToken.type != secondToken.type)
            return firstToken;

        pragma(msg, "[OPTION] handle better wide string (cf. encoding)");
        auto location = firstToken.location;
        location.length = accLength + secondToken.location.length;
        auto firstValue = firstToken.value.get!PpcStringTokenValue;
        auto secondVal = secondToken.value.get!PpcStringTokenValue;
        bool isWide = firstValue.isWide || secondVal.isWide;
        string content = firstValue.content ~ secondVal.content;
        auto value = PpcStringTokenValue(isWide, content);
        return PpcToken(firstToken.type, location, PpcTokenValue(value));
    }

    void popFront()
    {
        auto firstToken = _input.front;

        if(firstToken.type != PpcTokenType.STRING)
        {
            _input.popFront();
            return;
        }

        _input.popFront();

        auto lookAhead = _input.save;

        while(!lookAhead.empty && lookAhead.front.type == PpcTokenType.SPACING)
            lookAhead.popFront();

        if(lookAhead.empty)
            return;

        auto secondToken = lookAhead.front;

        if(firstToken.type == secondToken.type)
        {
            lookAhead.popFront();
            _input = lookAhead;
        }
    }

    /*@property auto save()
    {
        This result = this;
        result._input = _input.save;
        return result;
    }*/
}

StringConcatenation!Range concatStrings(Range)(Range input, IErrorHandler errorHandler)
    if(isInputRange!Range && is(ElementType!Range : PpcToken))
{
    return StringConcatenation!Range(input, errorHandler);
}


