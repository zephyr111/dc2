/* Copyright (c) 2018 <Jérôme Richard>
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

module parser.types;

import std.string;
import std.conv;
import std.traits;
import std.algorithm.comparison;
import core.exception;
import stdTypes = interfaces.types.tokens;
import utils;


alias LexerTokenType = stdTypes.TokenType;
alias LexerTokenLocation = stdTypes.TokenLocation;
alias LexerIdentifierTokenValue = stdTypes.IdentifierTokenValue;
alias LexerIntegerTokenValue = stdTypes.IntegerTokenValue;
alias LexerNumberTokenValue = stdTypes.NumberTokenValue;
alias LexerCharTokenValue = stdTypes.CharTokenValue;
alias LexerStringTokenValue = stdTypes.StringTokenValue;
alias LexerTokenValue = stdTypes.TokenValue;
alias LexerToken = stdTypes.Token;

alias ParserTokenLocation = stdTypes.TokenLocation;
alias ParserIdentifierTokenValue = stdTypes.IdentifierTokenValue;
alias ParserIntegerTokenValue = stdTypes.IntegerTokenValue;
alias ParserNumberTokenValue = stdTypes.NumberTokenValue;
alias ParserCharTokenValue = stdTypes.CharTokenValue;
alias ParserStringTokenValue = stdTypes.StringTokenValue;
alias ParserTokenValue = stdTypes.TokenValue;

enum ParserTokenType
{
    // Identifiers, typenames, enums and constant literals
    IDENTIFIER, TYPE_NAME, ENUM_VALUE,
    INTEGER, NUMBER, CHARACTER, STRING,

    // Keywords
    AUTO, BREAK, CASE, CHAR,
    CONST, CONTINUE, DEFAULT, DO,
    DOUBLE, ELSE, ENUM, EXTERN,
    FLOAT, FOR, GOTO, IF,
    INT, LONG, REGISTER, RETURN,
    SHORT, SIGNED, SIZEOF, STATIC,
    STRUCT, SWITCH, TYPEDEF, UNION,
    UNSIGNED, VOID, VOLATILE, WHILE,

    // Structuring operators
    LPAREN, RPAREN,
    LCURL, RCURL,
    LBRACK, RBRACK,
    COMMA, ELLIPSIS,
    SEMICOLON, COL, QMARK,

    // Arithmetical & Logical operators 
    OP_INC, OP_DEC,
    OP_ADD, OP_SUB,
    OP_MUL, OP_DIV, OP_MOD,
    OP_LSHIFT, OP_RSHIFT,
    OP_AND, OP_OR,
    OP_LE, OP_LT, OP_GE, OP_GT,
    OP_NOT, OP_EQ, OP_NE,
    OP_BAND, OP_BOR, OP_BXOR, OP_BNOT,
    OP_DOT, OP_ARROW,

    // Assignment operator
    ASSIGN,
    ADD_ASSIGN, SUB_ASSIGN,
    MUL_ASSIGN, DIV_ASSIGN, MOD_ASSIGN,
    LSHIFT_ASSIGN, RSHIFT_ASSIGN,
    AND_ASSIGN, OR_ASSIGN, XOR_ASSIGN,

    // Ignored tokens (spacing include comments in C)
    //SPACING,

    // An invalid token (unknown)
    ERROR,

    // End-of-file token
    EOF,
}

struct ParserToken
{
    ParserTokenType type;
    ParserTokenLocation location;
    ParserTokenValue value;

    // Transform a token to a string
    // Set pretty to false for direct printing and token stringification
    // Set pretty to true for reporting tokens to the user (enclosed by back-quotes)
    string toString(bool pretty = true)() const
    {
        static immutable string[] operatorLexems = [
            "(", ")", "{", "}", "[", "]", ",", "...", ";", ":",
            "?", "++", "--", "+", "-", "*", "/", "%", "<<", ">>",
            "&&", "||", "<=", "<", ">=", ">", "!", "==", "!=", "&",
            "|", "^", "~", ".", "->", "=", "+=", "-=", "*=", "/=", 
            "%=", "<<=", ">>=", "&=", "|=", "^=",
        ];

        with(ParserTokenType)
        {
            enum opStart = LPAREN.asOriginalType;
            enum opEnd = XOR_ASSIGN.asOriginalType;
            static assert(is(OriginalType!ParserTokenType == int));
            static assert(opEnd-opStart+1 == operatorLexems.length);

            if(type == IDENTIFIER)
                return value.get!ParserIdentifierTokenValue.name;
            else if(type >= opStart && type <= opEnd)
                return operatorLexems[type.asOriginalType-opStart];
            else if(type == NUMBER)
                return value.get!ParserNumberTokenValue.content.to!string;
            else if(type == INTEGER)
                return value.get!ParserIntegerTokenValue.content.to!string;
            else if(type == TYPE_NAME)
                return value.get!ParserIdentifierTokenValue.name;
            else if(type == ENUM_VALUE)
                return value.get!ParserIdentifierTokenValue.name;
            else if(type == STRING)
            {
                auto actualValue = value.get!ParserStringTokenValue;
                enum finalEscapeType = pretty ? EscapeType.REPR_DQUOTES : EscapeType.ONLY_DQUOTES;
                auto finalContent = actualValue.content.escape!finalEscapeType;
                return text(actualValue.isWide ? "L\"" : "\"", finalContent, "\"");
            }
            else if(type == CHARACTER)
            {
                auto actualValue = value.get!ParserCharTokenValue;
                enum finalEscapeType = pretty ? EscapeType.REPR_SQUOTES : EscapeType.ONLY_SQUOTES;
                auto finalContent = actualValue.content.escapeChar!finalEscapeType;
                return text(actualValue.isWide ? "L'" : "'", finalContent, "'");
            }

            // Other unlikely cases
            switch(type)
            {
                case AUTO: .. case WHILE: return type.to!string.toLower;
                case ERROR: return "[ERROR]";
                case EOF: return "[EOF]";
                default: throw new SwitchError(format!"Programming error (unsupported type: %s)"(type));
            }
        }
    }
}

