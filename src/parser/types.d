module parser.types;

import std.conv;
import std.traits;
import std.algorithm.comparison;
import core.exception;
import interfaces;
import utils;


alias LexerTokenType = ILexer.TokenType;
alias LexerTokenLocation = ILexer.TokenLocation;
alias LexerIdentifierTokenValue = ILexer.IdentifierTokenValue;
alias LexerIntegerTokenValue = ILexer.IntegerTokenValue;
alias LexerNumberTokenValue = ILexer.NumberTokenValue;
alias LexerCharTokenValue = ILexer.CharTokenValue;
alias LexerStringTokenValue = ILexer.StringTokenValue;
alias LexerTokenValue = ILexer.TokenValue;
alias LexerToken = ILexer.Token;

alias ParserTokenLocation = ILexer.TokenLocation;
alias ParserIdentifierTokenValue = ILexer.IdentifierTokenValue;
alias ParserIntegerTokenValue = ILexer.IntegerTokenValue;
alias ParserNumberTokenValue = ILexer.NumberTokenValue;
alias ParserCharTokenValue = ILexer.CharTokenValue;
alias ParserStringTokenValue = ILexer.StringTokenValue;
alias ParserTokenValue = ILexer.TokenValue;

enum ParserTokenType
{
    // Identifiers, typenames, enums and constant literals
    IDENTIFIER, TYPE_NAME, ENUM_VALUE,
    NUMBER, CHARACTER, STRING,

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
    OP_DOT,

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
            "|", "^", "~", ".", "=", "+=", "-=", "*=", "/=", "%=",
            "<<=", ">>=", "&=", "|=", "^=",
        ];

        with(ParserTokenType)
        {
            enum ppcStart = LPAREN.asOriginalType;
            enum ppcEnd = XOR_ASSIGN.asOriginalType;
            static assert(is(OriginalType!PpcTokenType == int));
            static assert(ppcEnd-ppcStart+1 == operatorLexems.length);

            if(type == SPACING)
                return " ";
            else if(type == IDENTIFIER)
                return value.get!PpcIdentifierTokenValue.name;
            else if(type >= ppcStart && type <= ppcEnd)
                return operatorLexems[type.asOriginalType-ppcStart];
            else if(type == NUMBER)
                return value.get!PpcNumberTokenValue.content;
            else if(type == NEWLINE)
                return "\n";
            else if(type == STRING)
            {
                auto actualValue = value.get!PpcStringTokenValue;
                enum finalEscapeType = pretty ? EscapeType.REPR_DQUOTES : EscapeType.ONLY_DQUOTES;
                auto finalContent = actualValue.content.escape!finalEscapeType;
                return text(actualValue.isWide ? "L\"" : "\"", finalContent, "\"");
            }
            else if(type == CHARACTER)
            {
                auto actualValue = value.get!PpcCharTokenValue;
                enum finalEscapeType = pretty ? EscapeType.REPR_SQUOTES : EscapeType.ONLY_SQUOTES;
                auto finalContent = actualValue.content.escapeChar!finalEscapeType;
                return text(actualValue.isWide ? "L'" : "'", finalContent, "'");
            }

            // Other unlikely cases
            switch(type)
            {
                case ERROR: return "[ERROR]";
                case EOF: return "[EOF]";
                default: throw new SwitchError("Programming error");
            }
        }
    }
}

