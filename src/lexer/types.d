module lexer.types;

import std.variant;
import std.conv;
import std.traits;
import std.algorithm.comparison;
import std.format;
import core.exception;
import interfaces;
import utils;


alias TokenLocation = ILexer.TokenLocation;
alias StdIdentifierTokenValue = ILexer.IdentifierTokenValue;
alias StdIntegerTokenValue = ILexer.IntegerTokenValue;
alias StdNumberTokenValue = ILexer.NumberTokenValue;
alias StdCharTokenValue = ILexer.CharTokenValue;
alias StdStringTokenValue = ILexer.StringTokenValue;
alias StdTokenType = ILexer.TokenType;
alias StdTokenValue = ILexer.TokenValue;
alias StdToken = ILexer.Token;

alias PpcMacroState = immutable(string)[];

pragma(msg, "[OPTIM] Use a range to avoid allocations OR tack the string slice from the source range (if locLength ok)");
struct PpcIdentifierTokenValue
{
    string name;
    PpcMacroState state = [];
}

pragma(msg, "[OPTIM] Use a range to avoid allocations OR tack the string slice from the source range (if locLength ok)");
struct PpcNumberTokenValue
{
    string content;
}

struct PpcCharTokenValue
{
    bool isWide;
    dchar content;
}

struct PpcStringTokenValue
{
    bool isWide;
    string content;
}

struct PpcHeaderTokenValue
{
    bool isGlobal;
    string name;
}

struct PpcParamTokenValue
{
    int id;
    bool toStringify;
}

struct PpcConcatTokenValue
{
    immutable(PpcToken)[] children;
    bool isInMacro;
}

alias PpcTokenValue = Algebraic!(PpcIdentifierTokenValue, PpcNumberTokenValue,
                                    PpcCharTokenValue, PpcStringTokenValue,
                                    PpcHeaderTokenValue, void,
                                    PpcParamTokenValue, PpcConcatTokenValue);

enum PpcTokenType
{
    // Identifiers and constants
    IDENTIFIER, NUMBER, CHARACTER, STRING,

    // Structuring operators
    LPAREN, RPAREN, LCURL, RCURL, LBRACK, RBRACK,
    COMMA, ELLIPSIS, SEMICOLON, COL, QMARK,

    // Arithmetical & Logical operators 
    OP_INC, OP_DEC, OP_ADD, OP_SUB, OP_MUL, OP_DIV, OP_MOD,
    OP_LSHIFT, OP_RSHIFT, OP_AND, OP_OR,
    OP_LE, OP_LT, OP_GE, OP_GT, OP_NOT, OP_EQ, OP_NE,
    OP_BAND, OP_BOR, OP_BXOR, OP_BNOT,
    OP_DOT,

    // Assignment operator
    ASSIGN, ADD_ASSIGN, SUB_ASSIGN, MUL_ASSIGN, DIV_ASSIGN, MOD_ASSIGN,
    LSHIFT_ASSIGN, RSHIFT_ASSIGN, AND_ASSIGN, OR_ASSIGN, XOR_ASSIGN,

    // Spacing
    SPACING, NEWLINE,

    // An invalid token (unknown)
    ERROR,

    // End-of-file token
    EOF,

    // In-macro tokens
    HEADER_NAME, SHARP, TOKEN_CONCAT, MACRO_PARAM,
}

struct PpcToken
{
    PpcTokenType type;
    TokenLocation location;
    PpcTokenValue value;

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

        with(PpcTokenType)
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
                case MACRO_PARAM: return format!"[MACRO_PARAM_%s]"(value.get!PpcParamTokenValue.id);
                case ERROR: return "[ERROR]";
                case EOF: return "[EOF]";
                case HEADER_NAME: return "[HEADER_NAME]";
                case SHARP: return "#";
                case TOKEN_CONCAT: return "##";
                default: throw new SwitchError("Programming error");
            }
        }
    }
}

