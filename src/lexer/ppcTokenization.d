/* Copyright (c) 2018 <Jérôme Richard>
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

module lexer.ppcTokenization;

import std.stdio;
import std.range;
import std.range.primitives;
import std.traits;
import std.algorithm.comparison;
import std.algorithm.iteration;
import std.algorithm.searching;
import std.ascii : isAlpha, isAlphaNum, isDigit, isOctalDigit, isPunctuation;
import std.typecons;
import interfaces : IErrorHandler;
import lexer.types;
import utils;

version(withUnicodeInput)
    import std.uni : isWhite;
else
    import std.ascii : isWhite;


// Allowed chars in universal character names
// The allowed charset is implementation defined until the C11 standard
// (see ISO/IEC 9899:201x)
private bool isUCNchar(dchar c)
{
    version(withUnicodeInput)
    {
        if(c <= 0x7F)
            return c.isAlphaNum;

        if(c <= 0xFF)
            return c.among(0xA8, 0xAA, 0xAD, 0xAF)
                    || c >= 0xB2 && !c.among(0xB6, 0xBB, 0xBF, 0xD7, 0xF7);

        if(c <= 0xFFFF)
            return (c in iota(0x0100, 0x167F+1) || c in iota(0x1681, 0x180D+1)
                        || c in iota(0x180F, 0x1FFF+1) || c in iota(0x200B, 0x200D+1)
                        || c in iota(0x202A, 0x202E+1) || c in iota(0x203F, 0x2040+1)
                        || c == 0x2054 || c in iota(0x2060, 0x206F+1)
                        || c in iota(0x2070, 0x218F+1) || c in iota(0x2460, 0x24FF+1)
                        || c in iota(0x2776, 0x2793+1) || c in iota(0x2C00, 0x2DFF+1)
                        || c in iota(0x2E80, 0x2FFF+1) || c in iota(0x3004, 0x3007+1)
                        || c in iota(0x3021, 0x302F+1) || c in iota(0x3031, 0x303F+1)
                        || c in iota(0x3040, 0xD7FF+1) || c in iota(0xF900, 0xFD3D+1)
                        || c in iota(0xFD40, 0xFDCF+1) || c in iota(0xFDF0, 0xFE44+1)
                        || c in iota(0xFE47, 0xFFFD+1))
                    && !(c in iota(0x0300, 0x036F+1) || c in iota(0x1DC0, 0x1DFF+1)
                        || c in iota(0x20D0, 0x20FF+1) || c in iota(0xFE20, 0xFE2F+1));

        return c < 0xF0000 && !(c & 0xFFFF).among(0xFFFE, 0xFFFF);
    }
    else
    {
        return false;
    }
}

// May consume more char than requested
// Perform a look-ahead parsing
// Cannot take an InputRange as input without copying data, which is expensive
struct PpcTokenization(Range)
{
    private
    {
        // For header name lexing (only present within include directives)
        enum LexingState
        {
            NOTHING_FOUND,
            NEWLINE_FOUND,
            SHARP_FOUND,
            INCLUDE_FOUND,
        }

        enum operatorLexemsEnum = [
            "(", ")", "{", "}", "[", "]", ",", ";", ":", "?", "~", "+",
            "-", "*", "/", "%", "=", "<", ">", "!", "&", "|", "^", ".",
            "++", "--", "<<", ">>", "&&", "||", "<=", ">=", "==", "!=", "+=", 
            "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=", "...",
            "#", "##", "<:", ":>", "<%", "%>", "%:", "%:%:",
        ];

        enum operatorLexemLenEnum = operatorLexems.map!((string a) => a.length).array;

        enum operatorTokenTypesEnum = [
            PpcTokenType.LPAREN, PpcTokenType.RPAREN, PpcTokenType.LCURL,
            PpcTokenType.RCURL, PpcTokenType.LBRACK, PpcTokenType.RBRACK,
            PpcTokenType.COMMA, PpcTokenType.SEMICOLON, PpcTokenType.COL,
            PpcTokenType.QMARK, PpcTokenType.OP_BNOT, PpcTokenType.OP_ADD,
            PpcTokenType.OP_SUB, PpcTokenType.OP_MUL, PpcTokenType.OP_DIV,
            PpcTokenType.OP_MOD, PpcTokenType.ASSIGN, PpcTokenType.OP_LT,
            PpcTokenType.OP_GT, PpcTokenType.OP_NOT, PpcTokenType.OP_BAND,
            PpcTokenType.OP_BOR, PpcTokenType.OP_BXOR, PpcTokenType.OP_DOT,
            PpcTokenType.OP_INC, PpcTokenType.OP_DEC, PpcTokenType.OP_LSHIFT,
            PpcTokenType.OP_RSHIFT, PpcTokenType.OP_AND, PpcTokenType.OP_OR,
            PpcTokenType.OP_LE, PpcTokenType.OP_GE, PpcTokenType.OP_EQ,
            PpcTokenType.OP_NE, PpcTokenType.ADD_ASSIGN, PpcTokenType.SUB_ASSIGN,
            PpcTokenType.MUL_ASSIGN, PpcTokenType.DIV_ASSIGN, PpcTokenType.MOD_ASSIGN,
            PpcTokenType.AND_ASSIGN, PpcTokenType.OR_ASSIGN, PpcTokenType.XOR_ASSIGN,
            PpcTokenType.LSHIFT_ASSIGN, PpcTokenType.RSHIFT_ASSIGN, PpcTokenType.ELLIPSIS,
            PpcTokenType.SHARP, PpcTokenType.TOKEN_CONCAT, PpcTokenType.LBRACK, PpcTokenType.RBRACK,
            PpcTokenType.LCURL, PpcTokenType.RCURL, PpcTokenType.SHARP, PpcTokenType.TOKEN_CONCAT,
        ];

        static assert(operatorLexems.length == operatorTokenTypes.length);

        alias This = typeof(this);

        Range _input;
        LexingState _lexingState = LexingState.NEWLINE_FOUND;
        IErrorHandler _errorHandler;
        Nullable!PpcToken _result;

        // Note: compilers badly optimize direct accesses to enums in pactice...
        static immutable string[] operatorLexems = operatorLexemsEnum;
        static immutable size_t[] operatorLexemLen = operatorLexemLenEnum;
        static immutable PpcTokenType[] operatorTokenTypes = operatorTokenTypesEnum;
    }


    this(Range input, IErrorHandler errorHandler)
    {
        _input = input;
        _errorHandler = errorHandler;

        if(!_input.empty)
            computeNext();
    }

    private auto tryParseLiteral()
    {
        const auto first = _input.front;

        if(_lexingState == LexingState.INCLUDE_FOUND || !first.among('L', '"', '\''))
            return Nullable!PpcToken();

        auto loc = TokenLocation(_input.filename, _input.line, _input.col, _input.pos, 0);

        auto prefixed = first == 'L';

        if(prefixed)
        {
            auto lookAhead = _input.save.dropOne;
            if(lookAhead.empty || !lookAhead.front.among('"', '\''))
                return Nullable!PpcToken();
            _input = lookAhead;
        }

        auto strDelim = _input.front;
        _input.popFront();

        pragma(msg, "[OPTIM] avoid allocation for each char");
        static auto strContent = appender!(char[]);
        strContent.clear();

        do
        {
            _input.forwardUntil!(a => a.among('\\', '\n') || a == strDelim)(strContent);

            if(!_input.empty && _input.front == '\\')
            {
                auto lookAhead = _input.save.dropOne;
                if(lookAhead.empty)
                    break;
                auto escapeChar = lookAhead.front;
                lookAhead.popFront();

                pragma(msg, "[CHECK] check the correctness of handling '\\0'");
                if(escapeChar == strDelim)
                    strContent.put(strDelim);
                else if(escapeChar == 'n')
                    strContent.put('\n');
                else if(escapeChar == 'r')
                    strContent.put('\r');
                else if(escapeChar == 't')
                    strContent.put('\t');
                else if(escapeChar == '\\')
                    strContent.put('\\');
                else if(escapeChar.isDigit)
                {
                    long charCode = escapeChar - '0';
                    auto tmpRange = refRange(&lookAhead).take(3);
                    tmpRange.forwardWhile!(isOctalDigit, a => charCode = charCode*8 + a-'0');
                    strContent.put(cast(char)(charCode % 0xFF));

                    if(charCode >= 256)
                    {
                        auto tmpLoc = TokenLocation(_input.filename, _input.line, 
                                                _input.col, _input.pos, 0);
                        _errorHandler.error("escaping code overflow", tmpLoc.filename,
                                            tmpLoc.line, tmpLoc.col, 1);
                    }
                }
                else
                {
                    pragma(msg, "[OPTION] support escape codes like UTF-8, hexadecimal");
                    auto tmpLoc = TokenLocation(_input.filename, _input.line, 
                                                _input.col, _input.pos, 0);
                    _errorHandler.error("unsupported escaping code", tmpLoc.filename,
                                            tmpLoc.line, tmpLoc.col, 1);
                }

                _input = lookAhead;
            }
        }
        while(!_input.empty && _input.front != strDelim);

        if(!_input.skipIf(strDelim))
        {
            auto length = _input.pos - loc.pos;
            _errorHandler.error("unterminated literal", loc.filename,
                                    loc.line, loc.col, length);
            return PpcToken(PpcTokenType.EOF, loc).nullable;
        }

        loc.length = _input.pos - loc.pos;

        if(strDelim == '"')
        {
            auto value = PpcStringTokenValue(prefixed, strContent.data.idup);
            return PpcToken(PpcTokenType.STRING, loc, PpcTokenValue(value)).nullable;
        }
        else
        {
            if(strContent.data.walkLength != 1)
                _errorHandler.error("invalid character litteral (bad length)", 
                                    loc.filename, loc.line, loc.col, loc.length);
            auto value = PpcCharTokenValue(prefixed, strContent.data.front);
            return PpcToken(PpcTokenType.CHARACTER, loc, PpcTokenValue(value)).nullable;
        }
    }

    private auto tryParseIdentifier()
    {
        auto first = _input.front;

        if(!first.isAlpha && !first.isUCNchar && first != '_')
            return Nullable!PpcToken();

        if(first == 'L' && _input.save.dropOne.startsWithAmong!(["\"", "'"]) >= 0)
            return Nullable!PpcToken();

        auto loc = TokenLocation(_input.filename, _input.line, _input.col, _input.pos, 0);

        static auto acc = appender!(char[]);
        acc.clear();

        _input.forwardUntil!(a => !a.isAlphaNum && a != '_' && !a.isUCNchar)(acc);
        auto lexem = acc.data;

        loc.length = _input.pos - loc.pos;
        auto value = PpcIdentifierTokenValue(lexem.idup);
        return PpcToken(PpcTokenType.IDENTIFIER, loc, PpcTokenValue(value)).nullable;
    }

    private auto tryParseSpacing()
    {
        auto first = _input.front;
        bool withNewLines = false;

        if(first == '\n')
        {
            auto loc = TokenLocation(_input.filename, _input.line, _input.col, _input.pos, 0);
            _input.findSkip!(a => a == '\n');
            loc.length = _input.pos - loc.pos;
            return PpcToken(PpcTokenType.NEWLINE, loc).nullable;
        }

        if(!first.isWhite && !(first == '/' && _input.startsWith("/*")))
            return Nullable!PpcToken();

        auto loc = TokenLocation(_input.filename, _input.line, _input.col, _input.pos, 0);

        while(true)
        {
            _input.findSkip!(a => a.isWhite && a != '\n');

            if(_input.empty || _input.front != '/' || !_input.startsWith("/*"))
                break;

            auto tmpLoc = TokenLocation(_input.filename, _input.line, 
                                            _input.col, _input.pos, 0);

            _input.popFrontExactly(2);

            do
            {
                _input = _input.find('*');
                _input.popFrontN(1);

                if(_input.empty)
                {
                    auto length = _input.pos - tmpLoc.pos;
                    _errorHandler.error("unterminated comment", tmpLoc.filename,
                                            tmpLoc.line, tmpLoc.col, length);
                    return PpcToken(PpcTokenType.EOF, tmpLoc).nullable;
                }
            }
            while(!_input.skipIf('/'));
        }

        loc.length = _input.pos - loc.pos;
        return PpcToken(PpcTokenType.SPACING, loc).nullable;
    }

    private auto tryParseNumber()
    {
        const auto first = _input.front;

        if(!first.isDigit && (first != '.' || !_input.save.dropOne.front.isDigit))
            return Nullable!PpcToken();

        auto loc = TokenLocation(_input.filename, _input.line, _input.col, _input.pos, 0);

        static auto acc = appender!(char[]);
        acc.clear();

        auto readElem = (ElementType!Range a) => a.isAlphaNum && !a.among('e', 'E') || a.among('_', '.');
        while(_input.forwardWhile!readElem(acc) > 0
                && _input.forwardIf!(a => a.among('e', 'E'))(acc))
            _input.forwardIf!(a => a.among('+', '-'))(acc);

        loc.length = _input.pos - loc.pos;
        auto value = PpcNumberTokenValue(acc.data.idup);
        return PpcToken(PpcTokenType.NUMBER, loc, PpcTokenValue(value)).nullable;
    }

    private auto tryParseOperator()
    {
        const auto first = _input.front;

        if(_lexingState == LexingState.INCLUDE_FOUND
                || !first.isPunctuation || first.among('@', '$', '`')
                || first == '.' && _input.save.dropOne.startsWith!isDigit)
            return Nullable!PpcToken();

        auto loc = TokenLocation(_input.filename, _input.line, _input.col, _input.pos, 0);

        auto id = _input.startsWithAmong!operatorLexemsEnum;
        if(id < 0)
            return Nullable!PpcToken();

        _input.popFrontExactly(operatorLexemLen[id]);

        loc.length = _input.pos - loc.pos;
        enum concatId = operatorTokenTypesEnum.countUntil!(a => a == PpcTokenType.TOKEN_CONCAT);
        if(id != concatId)
            return PpcToken(operatorTokenTypes[id], loc).nullable;
        auto value = PpcTokenValue(PpcConcatTokenValue([], false));
        return PpcToken(PpcTokenType.TOKEN_CONCAT, loc, value).nullable;
    }

    private auto tryParseHeaderName()
    {
        auto first = _input.front;

        if(_lexingState != LexingState.INCLUDE_FOUND || !first.among('<', '"'))
            return Nullable!PpcToken();

        auto loc = TokenLocation(_input.filename, _input.line, _input.col, _input.pos, 0);

        static auto acc = appender!(char[]);
        acc.clear();

        bool isGlobal = first == '<';
        _input.popFront();
        auto last = isGlobal ? '>' : '"';
        _input.forwardUntil!(a => a == last || a == '\n')(acc);
        auto lexem = acc.data;

        if(!_input.skipIf(last))
        {
            _input.popFrontN(1);
            loc.length = _input.pos - loc.pos;
            _errorHandler.error("unterminated header name", _input.filename, _input.line, _input.col);
            return PpcToken(PpcTokenType.ERROR, loc).nullable;
        }

        loc.length = _input.pos - loc.pos;
        auto value = PpcHeaderTokenValue(isGlobal, lexem.idup);
        return PpcToken(PpcTokenType.HEADER_NAME, loc, PpcTokenValue(value)).nullable;
    }

    private void computeNext()
    {
        // Priority: Number>Operators
        if(!(_result = tryParseSpacing()).isNull) {}
        else if(!(_result = tryParseIdentifier()).isNull) {}
        else if(!(_result = tryParseOperator()).isNull) {}
        else if(!(_result = tryParseNumber()).isNull) {}
        else if(!(_result = tryParseLiteral()).isNull) {}
        else if(!(_result = tryParseHeaderName()).isNull) {}
        else
        {
            auto loc = TokenLocation(_input.filename, _input.line, _input.col, _input.pos, 0);
            _errorHandler.error("unknown token", _input.filename, _input.line, _input.col);
            _input.popFront();
            loc.length = _input.pos - loc.pos;
            _result = PpcToken(PpcTokenType.ERROR, loc).nullable;
            return;
        }

        if(_result.type == PpcTokenType.NEWLINE)
            _lexingState = LexingState.NEWLINE_FOUND;
        else if(_result.type == PpcTokenType.SHARP && _lexingState == LexingState.NEWLINE_FOUND)
            _lexingState = LexingState.SHARP_FOUND;
        else if(_result.type == PpcTokenType.IDENTIFIER && _lexingState == LexingState.SHARP_FOUND
                && _result.value.get!PpcIdentifierTokenValue.name == "include")
            _lexingState = LexingState.INCLUDE_FOUND;
        else if(_result.type != PpcTokenType.SPACING)
            _lexingState = LexingState.NOTHING_FOUND;
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

    /*@property auto save()
    {
        This result = this;
        result._input = _input.save;
        return result;
    }*/
}

PpcTokenization!Range ppcTokenize(Range)(Range input, IErrorHandler errorHandler)
    if(isForwardRange!Range && isSomeChar!(ElementEncodingType!Range) && !isConvertibleToString!Range)
{
    return PpcTokenization!Range(input, errorHandler);
}


