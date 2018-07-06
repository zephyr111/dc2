import std.exception;


interface ILexer
{
    enum TokenType
    {
        // Identifiers, types, enums and constants
        IDENTIFIER, TYPE, ENUM_VALUE,
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
        OP_DOT,

        // Assignment operator
        ASSIGN,
        ADD_ASSIGN, SUB_ASSIGN,
        MUL_ASSIGN, DIV_ASSIGN, MOD_ASSIGN,
        LSHIFT_ASSIGN, RSHIFT_ASSIGN,
        AND_ASSIGN, OR_ASSIGN, XOR_ASSIGN,

        // Ignored tokens (spacing include comments in C)
        SPACING,

        // An invalid token (unknown)
        ERROR,

        // End-of-file token
        EOF,
    }

    // Notes:
    //  - the length of the token include 
    struct Token
    {
        TokenType type;
        TokenLocation location;
        string lexem; // without digraph/trigraph & cesures
    }

    // Location in the source file (include digraph/trigraph and cesures)
    struct TokenLocation
    {
        string filename;
        uint line;
        uint col;
        ulong pos;
        ulong length;
    }

    Token next();
}

interface IParser
{
    
}

interface ISemanticAnalyser
{
    
}

class HaltException : Exception
{
    mixin basicExceptionCtors;
}

interface IErrorHandler
{
    // Note: error and missingFile functions can throw a class 
    // derived from IHaltException to stop the program
    void error(string message, string filename, ulong line, ulong col, ulong sliceLength = 0);
    void missingFile(string filename);
    void handleHalt(HaltException err);
    void printReport();
    int countErrors();
}

interface IGo
{
    void go();
}

