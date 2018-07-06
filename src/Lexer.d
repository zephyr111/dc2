import std.stdio;
import std.typecons;
import std.range;
import std.range.primitives;
import std.string;
import std.ascii;
import std.algorithm;
import std.file;
import std.traits;
import std.utf;
import std.conv;
import std.array;
import core.time;
import utils;
import interfaces;


pragma(msg, "BUG: [Issue 19020] findSkip, findSplit and findSplitBefore return wrong results (prefer using findSkip later)");


// Lazy range: consume not more char than requested
// Cannot take an InputRange as input due to look-ahead parsing
private auto trackLocation(Range)(Range input, string filename)
    if(isForwardRange!Range && isSomeChar!(ElementEncodingType!Range) && !isConvertibleToString!Range)
{
    struct Result
    {
        private Range _input;
        private string _filename;
        private uint _line = 1;
        private uint _col = 1;
        private ulong _pos = 0;

        this(Range input, string filename)
        {
            _input = input;
            _filename = filename;
        }

        @property bool empty()
        {
            return _input.empty;
        }

        @property auto front()
        {
            return _input.front;
        }

        void popFront()
        {
            auto first = _input.front;
            _input.popFront();
            _col++;
            _pos++;

            if(first == '\n')
            {
                _line++;
                _col = 1;
            }
        }

        @property auto save()
        {
            Result result = this;
            result._input = _input.save;
            return result;
        }

        @property auto filename() { return _filename; }
        @property auto line() { return _line; }
        @property auto col() { return _col; }
        @property auto pos() { return _pos; }
    }

    return Result(input, filename);
}


// Lazy range: consume not more char than requested
// Cannot take an InputRange as input due to look-ahead parsing
private auto removeTrigraph(Range)(Range input)
    if(isForwardRange!Range && isSomeChar!(ElementEncodingType!Range) && !isConvertibleToString!Range)
{
    struct Result
    {
        private Range _input;

        this(Range input)
        {
            _input = input;
        }

        @property bool empty()
        {
            return _input.empty;
        }

        @property auto front()
        {
            auto first = _input.front;

            if(first == '?')
            {
                auto lookAhead = _input.dropOne;

                if(lookAhead.skipOver('?') && !lookAhead.empty)
                {
                    const long pos = "=/'()!<>-".indexOf(lookAhead.front);

                    if(pos >= 0)
                        return "#\\^[]|{}~"[pos];
                }
            }

            return first;
        }

        void popFront()
        {
            auto first = _input.front;
            _input.popFront();

            if(first == '?' && _input.startsWith('?'))
            {
                auto lookAhead = _input.dropOne;

                if(!lookAhead.empty && "=/'()!<>-".canFind(lookAhead.front))
                    _input = lookAhead.dropOne;
            }
        }

        @property auto save()
        {
            return Result(_input.save);
        }

        @property auto filename() { return _input.filename; }
        @property auto line() { return _input.line; }
        @property auto col() { return _input.col; }
        @property auto pos() { return _input.pos; }
    }

    return Result(input);
}


// Greedy lazy range: consume not more char than requested,
// while eating as much line split as possible
// Cannot take an InputRange as input due to look-ahead parsing
private auto removeLineSpliting(Range)(Range input)
    if(isForwardRange!Range && isSomeChar!(ElementEncodingType!Range) && !isConvertibleToString!Range)
{
    struct Result
    {
        private Range _input;

        this(Range input)
        {
            _input = input;
            trim();
        }

        private void trim()
        {
            while(_input.startsWith('\\') && _input.dropOne.startsWith('\n'))
                _input.popFrontExactly(2);
        }

        @property bool empty()
        {
            return _input.empty;
        }

        @property auto front()
        {
            return _input.front;
        }

        void popFront()
        {
            _input.popFront();
            trim();
        }

        @property auto save()
        {
            return Result(_input.save);
        }

        @property auto filename() { return _input.filename; }
        @property auto line() { return _input.line; }
        @property auto col() { return _input.col; }
        @property auto pos() { return _input.pos; }
    }

    return Result(input);
}


alias StdTokenType = ILexer.TokenType;
alias TokenLocation = ILexer.TokenLocation;

enum PpcTokenType
{
    INCLUDE = StdTokenType.max+1,
    IF,
    IFDEF,
    IFNDEF,
    ELSE,
    ELIF,
    ENDIF,
    DEFINE,
    UNDEF,
    ERROR,
    WARNING,
    PRAGMA,
    END,
}

union TemporaryTokenType
{
    StdTokenType stdToken;
    PpcTokenType preprocessorToken;
}

pragma(msg, "TODO: add token-specific fields (variant) and (optionnaly) remove lexem ?");
struct TemporaryToken
{
    TemporaryTokenType type;
    TokenLocation location;
    string lexem; // without digraph/trigraph & cesures
}

// Cannot take an InputRange as input due to look-ahead parsing
private auto tokenize(Range)(Range input, IErrorHandler errorHandler)
    if(isForwardRange!Range && isSomeChar!(ElementEncodingType!Range) && !isConvertibleToString!Range)
{
    struct Result
    {
        private Range _input;
        private IErrorHandler _errorHandler;
        private Nullable!TemporaryToken result;
        static private StdTokenType[string] keywords;
        static private PpcTokenType[string] directives;

        pragma(msg, "TODO: support preprocessor directives with digraph '%:'");
        pragma(msg, "TODO: support the preprocessor directive '##' and its associated digraph '%:%:'");
        static private immutable string[] operatorLexems = [
            "(", ")", "{", "}", "[", "]", ",", ";", ":", "?", "~", "+",
            "-", "*", "/", "%", "=", "<", ">", "!", "&", "|", "^", ".",
            "++", "--", "<<", ">>", "&&", "||", "<=", ">=", "==", "!=", "+=", 
            "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=", "...",
            "<:", ":>", "<%", "%>",
        ];

        static private immutable StdTokenType[] operatorTokenTypes = [
            StdTokenType.LPAREN, StdTokenType.RPAREN, StdTokenType.LCURL,
            StdTokenType.RCURL, StdTokenType.LBRACK, StdTokenType.RBRACK,
            StdTokenType.COMMA, StdTokenType.SEMICOLON, StdTokenType.COL,
            StdTokenType.QMARK, StdTokenType.OP_BNOT, StdTokenType.OP_ADD,
            StdTokenType.OP_SUB, StdTokenType.OP_MUL, StdTokenType.OP_DIV,
            StdTokenType.OP_MOD, StdTokenType.ASSIGN, StdTokenType.OP_LT,
            StdTokenType.OP_GT, StdTokenType.OP_NOT, StdTokenType.OP_BAND,
            StdTokenType.OP_BOR, StdTokenType.OP_BXOR, StdTokenType.OP_DOT,
            StdTokenType.OP_INC, StdTokenType.OP_DEC, StdTokenType.OP_LSHIFT,
            StdTokenType.OP_RSHIFT, StdTokenType.OP_AND, StdTokenType.OP_OR,
            StdTokenType.OP_LE, StdTokenType.OP_GE, StdTokenType.OP_EQ,
            StdTokenType.OP_NE, StdTokenType.ADD_ASSIGN, StdTokenType.SUB_ASSIGN,
            StdTokenType.MUL_ASSIGN, StdTokenType.DIV_ASSIGN, StdTokenType.MOD_ASSIGN,
            StdTokenType.AND_ASSIGN, StdTokenType.OR_ASSIGN, StdTokenType.XOR_ASSIGN,
            StdTokenType.LSHIFT_ASSIGN, StdTokenType.RSHIFT_ASSIGN, StdTokenType.ELLIPSIS,
            StdTokenType.LBRACK, StdTokenType.RBRACK, StdTokenType.LCURL, StdTokenType.RCURL,
        ];

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

            with(PpcTokenType)
            {
                directives = [
                    "include": INCLUDE, "if": IF, "ifdef": IFDEF, "ifndef": IFNDEF,
                    "else": ELSE, "elif": ELIF, "endif": ENDIF, "define": DEFINE,
                    "undef": UNDEF, "error": ERROR, "warning": WARNING, "pragma": PRAGMA,
                ];
            }

            assert(operatorLexems.length == operatorTokenTypes.length);
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

            if(!first.among('L', '"', '\''))
                return Nullable!TemporaryToken();

            auto loc = TokenLocation(_input.filename, _input.line, _input.col, _input.pos, 0);

            auto prefixed = first == 'L';

            if(prefixed)
            {
                auto lookAhead = _input.dropOne;
                if(lookAhead.empty || !lookAhead.front.among('"', '\''))
                    return Nullable!TemporaryToken();
                _input = lookAhead;
            }

            auto strDelim = _input.front;
            _input.popFront();

            auto strContent = appender!string;

            if(prefixed)
                strContent.put('L');
            strContent.put(strDelim);

            do
            {
                _input.forwardUntil!(a => a.among('\\', '\n') || a == strDelim)(strContent);

                if(!_input.empty && _input.front == '\\')
                {
                    auto lookAhead = _input.dropOne;
                    if(lookAhead.empty)
                        break;
                    auto escapeChar = lookAhead.front;
                    lookAhead.popFront();

                    pragma(msg, "TODO: check the correctness of handling '\\0'");
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
                    else if(escapeChar == '0')
                        strContent.put('\0');
                    else
                    {
                        pragma(msg, "TODO: support escape codes like UTF-8, hexadecimal and octal");
                        auto tmpLoc = TokenLocation(_input.filename, _input.line, 
                                                    _input.col, _input.pos, 0);
                        _errorHandler.error("unsupported escaping code", tmpLoc.filename,
                                                tmpLoc.line, tmpLoc.col, 1);
                    }

                    _input = lookAhead;
                }
            }
            while(!_input.empty && _input.front != strDelim);

            if(!_input.skipOver(strDelim))
            {
                auto length = _input.pos - loc.pos;
                _errorHandler.error("unterminated literal", loc.filename,
                                        loc.line, loc.col, length);

                auto type = TemporaryTokenType(StdTokenType.EOF);
                return TemporaryToken(type, loc, "").nullable;
            }

            // WARNING: strings must be concatenated later
            strContent.put(strDelim);

            auto type = TemporaryTokenType(strDelim == '"' ? StdTokenType.STRING : StdTokenType.CHARACTER);
            loc.length = _input.pos - loc.pos;
            auto lexem = strContent.data;
            return TemporaryToken(type, loc, lexem).nullable;
        }

        private auto tryParseIdentifier()
        {
            pragma(msg, "TODO: implement TYPE/ENUM/(MACRO?) recognition by interacting with the parser");

            auto first = _input.front;

            if(!first.isAlpha && first != '_')
                return Nullable!TemporaryToken();

            auto loc = TokenLocation(_input.filename, _input.line, _input.col, _input.pos, 0);

            auto tmp = appender!string;
            _input.forwardUntil!(a => !a.isAlphaNum && a != '_')(tmp);
            auto lexem = tmp.data;
            //auto lexem = refRange(&_input).until!(a => !a.isAlphaNum && a != '_').to!string;

            auto type = TemporaryTokenType(lexem in keywords ? keywords[lexem] : StdTokenType.IDENTIFIER);
            loc.length = _input.pos - loc.pos;
            return TemporaryToken(type, loc, lexem).nullable;
        }

        private auto tryParseSpacing()
        {
            auto first = _input.front;

            if(!first.isWhite && !(first == '/' && _input.startsWith("/*")))
                return Nullable!TemporaryToken();

            auto loc = TokenLocation(_input.filename, _input.line, _input.col, _input.pos, 0);

            while(true)
            {
                _input.findSkip!isWhite;

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

                        auto type = TemporaryTokenType(StdTokenType.EOF);
                        return TemporaryToken(type, tmpLoc, "").nullable;
                    }
                }
                while(!_input.skipOver('/'));
            }

            auto type = TemporaryTokenType(StdTokenType.SPACING);
            loc.length = _input.pos - loc.pos;
            return TemporaryToken(type, loc, " ").nullable;
        }

        private auto tryParseFloat()
        {
            auto first = _input.front;

            if(!first.isDigit && first != '.')
                return Nullable!TemporaryToken();

            auto loc = TokenLocation(_input.filename, _input.line, _input.col, _input.pos, 0);

            auto lookAhead = _input.save;

            auto tmp = appender!string;
            long lLen = lookAhead.forwardWhile!isDigit(tmp);
            bool isFractional = lookAhead.forwardIf!(a => a == '.')(tmp);
            long rLen = isFractional ? lookAhead.forwardWhile!isDigit(tmp) : 0;

            if(lLen+rLen == 0) // should be just a dot operator
                return Nullable!TemporaryToken();

            bool hasExponent = lookAhead.forwardIf!(a => a.among('e', 'E'))(tmp);

            if(!isFractional && !hasExponent) // should be an integer
                return Nullable!TemporaryToken();

            if(hasExponent)
            {
                lookAhead.forwardIf!(a => a.among('+', '-'))(tmp);
                long expLen = lookAhead.forwardWhile!isDigit(tmp);

                if(expLen == 0)
                {
                    loc.length = lookAhead.pos - loc.pos;
                    _errorHandler.error("Malformed float exponent", 
                                        lookAhead.filename, lookAhead.line, 
                                        lookAhead.col, loc.length);
                    auto type = TemporaryTokenType(StdTokenType.ERROR);
                    return TemporaryToken(type, loc, tmp.data).nullable;
                }
            }

            lookAhead.forwardIf!(a => a.among('f', 'l', 'F', 'L'))(tmp);
            auto lexem = tmp.data;

            _input = lookAhead;

            pragma(msg, "TODO: check that no identifier are glued after this token");

            auto type = TemporaryTokenType(StdTokenType.INTEGER);
            loc.length = _input.pos - loc.pos;
            return TemporaryToken(type, loc, lexem).nullable;
        }

        private auto tryParseInteger()
        {
            auto first = _input.front;

            if(!first.isDigit)
                return Nullable!TemporaryToken();

            auto loc = TokenLocation(_input.filename, _input.line, _input.col, _input.pos, 0);

            auto lookAhead = _input.save;
            lookAhead.popFront();

            static immutable auto suffix = ["u", "l", "ul", "lu", "U", "L", "UL", "LU"];

            auto tmp = appender!string;
            tmp.put(first);
            if(first != '0') // decimal
                lookAhead.forwardWhile!isDigit(tmp);
            else if(lookAhead.forwardIf!(a => a.among('x', 'X'))(tmp)) // hexadecimal
                lookAhead.forwardWhile!isHexDigit(tmp);
            else // octal
                lookAhead.forwardWhile!isOctalDigit(tmp);

            pragma(msg, "TODO: check that no identifier are glued after this token");

            auto id = lookAhead.startsWithAmong!suffix;
            if(id >= 0)
            {
                tmp.put(suffix[id]);
                lookAhead.popFrontExactly(suffix[id].length);
            }
            auto lexem = tmp.data;

            _input = lookAhead;

            auto type = TemporaryTokenType(StdTokenType.INTEGER);
            loc.length = _input.pos - loc.pos;
            return TemporaryToken(type, loc, lexem).nullable;
        }

        private auto tryParseOperator()
        {
            const auto first = _input.front;

            if(!first.isPunctuation || first.among('#', '@', '$', '`'))
                return Nullable!TemporaryToken();

            auto loc = TokenLocation(_input.filename, _input.line, _input.col, _input.pos, 0);

            enum tmp = operatorLexems;
            auto id = _input.startsWithAmong!tmp;

            if(id < 0)
                return Nullable!TemporaryToken();

            auto lexem = operatorLexems[id];
            auto type = operatorTokenTypes[id];
            _input.popFrontExactly(lexem.length);
            loc.length = _input.pos - loc.pos;
            return TemporaryToken(TemporaryTokenType(type), loc, lexem).nullable;
        }

        private auto tryParseDirective()
        {
            if(_input.front != '#')
                return Nullable!TemporaryToken();

            auto loc = TokenLocation(_input.filename, _input.line, _input.col, _input.pos, 0);

            // Note: care about spaces, new lines, no escaping chars and tokens:
            // [newline] [space]? # [space]? include [space]? '<' [anyFileChar]+ '>' [newline]
            // [newline] [space]? # [space]? include [space]? '"' [anyFileCharNoEscape]+ '"' [newline]
            // [newline] [space]? # [space]? define [space] [ident] [space] [tokens] [newline]
            // [newline] [space]? # [space]? define [space] [ident] [space]? '(' ... ')' [space] [tokens] [newline]
            // Add an internal state for newline before preprocessing elements ?
            pragma(msg, "TODO: reuse tryParseXXX functions to parse preprocessing directives (children tokens)");

            pragma(msg, "TODO: support comment in preprocessing directives");
            pragma(msg, "TODO: check \\n at the end of the directive + add check at the end of file");
            auto tmp = appender!(string);
            _input.forwardUntil!(a => a == '\n')(tmp);
            auto lexem = tmp.data;
            _input.popFrontN(1);

            loc.length = _input.pos - loc.pos;

            auto directive = lexem.dropOne.stripLeft.until!(a => !a.isAlphaNum).to!string;

            if(directive !in directives)
            {
                _errorHandler.error("unknown directive", _input.filename, _input.line, _input.col);
                auto type = TemporaryTokenType(StdTokenType.ERROR);
                return TemporaryToken(type, loc, lexem).nullable;
            }

            TemporaryTokenType type;
            type.preprocessorToken = directives[directive];
            return TemporaryToken(type, loc, lexem).nullable;
        }

        private void computeNext()
        {
            // Priority: Literals > Identifiers, Floats > Integers, Floats > Operators

            if(!(result = tryParseLiteral()).isNull) {}
            else if(!(result = tryParseIdentifier()).isNull) {}
            else if(!(result = tryParseSpacing()).isNull) {}
            else if(!(result = tryParseFloat()).isNull) {}
            else if(!(result = tryParseInteger()).isNull) {}
            else if(!(result = tryParseOperator()).isNull) {}
            else if(!(result = tryParseDirective()).isNull) {}
            else
            {
                _errorHandler.error("unknown token", _input.filename, _input.line, _input.col);
                auto type = TemporaryTokenType(StdTokenType.ERROR);
                auto location = TokenLocation(_input.filename, _input.line, _input.col, _input.pos, 1);
                result = TemporaryToken(type, location, _input.front.to!string).nullable;
                _input.popFront();
            }
        }

        @property bool empty()
        {
            return _input.empty;
        }

        @property auto front()
        {
            return result.get;
        }

        void popFront()
        {
            if(!_input.empty)
                computeNext();
        }

        @property auto save()
        {
            return Result(_input.save, _errorHandler);
        }
    }

    return Result(input, errorHandler);
}


pragma(msg, "TODO: check support of UTF-8 (code & filenames)");
pragma(msg, "TODO: support includes (recursively)");
pragma(msg, "TODO: support macro/defines definition/replacement (recursively) & expressions in #ifXXX");
pragma(msg, "TODO: support merging strings");
private class Lexer : ILexer, IGo
{
    private
    {
        struct FileContext
        {
            string filename;
            ulong line = 0;
            ulong col = 0;
            string data;
        }

        FileContext[] _contexts;
        IErrorHandler _errorHandler;
    }

    this(string filename, IErrorHandler errorHandler)
    {
        _contexts.reserve(16);

        try
        {
            _contexts ~= FileContext(filename, 0, 0, readText(filename));
        }
        catch(FileException err)
        {
            errorHandler.missingFile(filename);
        }

        _errorHandler = errorHandler;
    }

    // Use a sliding window lexer ? a forward range with save ?
    // => Done in the LL parser => Separation of concerns
    override Token next()
    {
        FileContext* context = &_contexts[$-1];
        Token token;

        //while(true)
        {
//auto s = MonoTime.currTime;

            //

//auto e = MonoTime.currTime;
//writeln(e-s);
        }

        return token;
    }

    override void go()
    {
        dstring dstr = _contexts[$-1].data.byDchar.array;
ulong tokenCount = 0;
auto s = MonoTime.currTime;
        foreach(token ; dstr.trackLocation(_contexts[$-1].filename)
                                .removeTrigraph
                                .removeLineSpliting
                                .tokenize(_errorHandler))
        {
            tokenCount++;
            //writeln("token:", token);
        }
        //writeln(dstr.trackLocation(_contexts[$-1].filename)
        //            .removeTrigraph
        //            .removeLineSpliting
        //            .tokenize(_errorHandler)
        //            .walkLength);
auto e = MonoTime.currTime;
writeln(e-s);
writefln("%d tokens found", tokenCount);

        /*Token token;

        do
        {
            token = next();
            writeln(token.type, " ", token.location.line, " ", token.location.col);
        }
        while(token.type != StdTokenType.EOF);*/
    }
}

