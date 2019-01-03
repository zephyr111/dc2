/* Copyright (c) 2018 <Jérôme Richard>
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

module lexer.stdTokenization;

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
import lexer.types;
import utils;


// May consume more char than requested
// Perform a look-ahead parsing
struct StdTokenization(Range)
{
    private
    {
        alias This = typeof(this);

        static StdTokenType[string] keywords;

        LookAheadRange!Range _input;
        IErrorHandler _errorHandler;
        Nullable!StdToken _result;
    }


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
        _input = lookAhead(input);
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

        long value;

        if(id >= 0 && id < 6)
            value = acc.data.to!ulong(base);
        else
            value = acc.data.to!long(base);

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
                auto loc = first.location;
                _result = StdToken(StdTokenType.ERROR, loc);
                auto value = Nullable!StdTokenValue();

                try
                {
                    if(!(value = tryParseFloat(oldValue.content)).isNull)
                        _result = StdToken(StdTokenType.FLOAT, loc, value.get);
                    else if(!(value = tryParseInteger(oldValue.content)).isNull)
                        _result = StdToken(StdTokenType.INTEGER, loc, value.get);
                    else
                        _errorHandler.error("unable to parse the number", loc.filename, loc.line, loc.col);
                    
                    if(!oldValue.content.empty)
                    {
                        auto remainingValue = oldValue.content;
                        auto fullValue = first.value.get!PpcNumberTokenValue.content;
                        enum errMsgPattern = "ignored remaining suffix `%s` in `%s`";
                        auto errMsg = format!errMsgPattern(remainingValue, fullValue);
                        _errorHandler.warning(errMsg, loc.filename, loc.line, loc.col);
                    }
                }
                catch(ConvOverflowException)
                {
                    _errorHandler.error("preprocessing number overflow", loc.filename, loc.line, loc.col);
                }
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
                auto type = first.type.convertEnum!(PpcTokenType, StdTokenType,
                                                    "LPAREN", "XOR_ASSIGN");
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
                return;
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

    /*@property auto save()
    {
        This result = this;
        result._input = _input.save;
        return result;
    }*/
}

StdTokenization!Range stdTokenize(Range)(Range input, IErrorHandler errorHandler)
    if(isInputRange!Range && is(ElementType!Range : PpcToken))
{
    return StdTokenization!Range(input, errorHandler);
}


