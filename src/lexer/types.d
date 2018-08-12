import std.variant;
import std.conv;
import std.traits;
import std.algorithm.comparison;
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

pragma(msg, "[OPTIM] Use a range to avoid allocations OR tack the string slice from the source range (if locLength ok)");
struct PpcIdentifierTokenValue
{
    string name;
}

pragma(msg, "[OPTIM] Use a range to avoid allocations OR tack the string slice from the source range (if locLength ok) (OR tweak the appender)");
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

alias PpcTokenValue = Algebraic!(PpcIdentifierTokenValue, PpcNumberTokenValue,
                                    PpcCharTokenValue, PpcStringTokenValue,
                                    PpcHeaderTokenValue, void);

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
    HEADER_NAME, SHARP, TOKEN_CONCAT,
}

struct PpcToken
{
    PpcTokenType type;
    TokenLocation location;
    PpcTokenValue value;

    string toString()
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
            switch(type)
            {
                case IDENTIFIER: return value.get!PpcIdentifierTokenValue.name;
                case NUMBER: return value.get!PpcNumberTokenValue.content;
                case CHARACTER:
                    auto actualValue = value.get!PpcCharTokenValue;
                    return text(actualValue.isWide ? "L'" : "'", actualValue.content.escapeChar, "'");
                case STRING:
                    auto actualValue = value.get!PpcStringTokenValue;
                    return text(actualValue.isWide ? "L\"" : "\"", actualValue.content.escape, "\"");
                case LPAREN: .. case XOR_ASSIGN:
                    enum ppcStart = LPAREN.asOriginalType;
                    enum ppcEnd = XOR_ASSIGN.asOriginalType;
                    static assert(is(OriginalType!PpcTokenType == int));
                    static assert(ppcEnd-ppcStart+1 == operatorLexems.length);
                    return operatorLexems[type.asOriginalType-ppcStart];
                case SPACING: return " ";
                case NEWLINE: return "\n";
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

struct Macro
{
    string name;
    bool predefined;
    bool withArgs;
    string[] args;
    PpcToken[] content;

    bool opEquals()(auto ref const Macro m) const
    {
        alias sameToken = (PpcToken a, PpcToken b) => a.type == b.type && a.value == b.value;
        return name == m.name
                && withArgs == m.withArgs 
                && args == m.args
                && content.equal!sameToken(m.content);
    }
};

