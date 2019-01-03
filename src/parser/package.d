/* Copyright (c) 2018 <Jérôme Richard>
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

module parser;

import std.stdio;
import std.range.primitives;
import std.algorithm.comparison;
import std.algorithm.searching;
import std.algorithm.iteration;
import std.array;
import std.typecons;
import std.format;
import std.traits;
import std.variant;
import interfaces;
import parser.types;
import parser.ast;
import utils;

AstNodeLocation toAstLoc(ParserTokenLocation loc)
{
    return AstNodeLocation(loc.filename, loc.line, loc.col, 
                            loc.pos, loc.length);
}

// From startLoc (included) to endLoc (excluded)
AstNodeLocation toAstLoc(ParserTokenLocation startLoc, ParserTokenLocation endLoc)
{
    return AstNodeLocation(startLoc.filename, startLoc.line, 
                            startLoc.col, startLoc.pos,
                            endLoc.pos - startLoc.pos);
}

// Transform a ILexer to a usual input range
// Note: this range must not preload data as the lexer 
// may not have been configured before.
private struct LexerRange
{
    private
    {
        alias This = typeof(this);

        ILexer _lexer;
        Nullable!LexerToken _result;
        bool _first = true;
    }


    this(ILexer lexer)
    {
        _lexer = lexer;
    }

    @property bool empty()
    {
        if(_first)
        {
            _result = _lexer.next();
            _first = false;
        }

        return _result.isNull;
    }

    @property auto front()
    {
        if(_first)
        {
            _result = _lexer.next();
            _first = false;
        }

        assert(!_result.isNull);
        return _result.get;
    }

    void popFront()
    {
        if(_first)
        {
            _result = _lexer.next();
            _first = false;
        }

        if(!_result.isNull)
            _result = _lexer.next();
    }
}

// Type-aware lexing range with a lookahead support
private struct TypedLexerRange(Range)
{
    private
    {
        alias This = typeof(this);
        static immutable string[] builtinTypes = ["__builtin_va_list"];

        Range _input;
        ParserTokenType[string][] _types; // stack of scoped types
        int _scopeLevel;
        CircularQueue!LexerToken _lookAhead;
        bool _withLookup = true;
    }


    this(Range input)
    {
        _input = input;
        _scopeLevel = 0; // global scope
    }

    // Tag the beginning of a function (for local types)
    void beginScope()
    {
        _scopeLevel++;
    }

    // Tag the end of a function to clean local types
    void endScope()
    {
        assert(_scopeLevel > 0);
        if(_types.length > _scopeLevel)
            _types[_scopeLevel].clear();
        _scopeLevel--;
    }

    void enableLookup()
    {
        _withLookup = true;
    }

    void disableLookup()
    {
        _withLookup = false;
    }

    void addTypeName(string name)
    {
        if(_types.length < _scopeLevel+1)
            _types.length = _scopeLevel+1;

        _types[_scopeLevel][name] = ParserTokenType.TYPE_NAME;
    }

    void addVariable(string name)
    {
        if(_types.length < _scopeLevel+1)
            _types.length = _scopeLevel+1;

        _types[_scopeLevel][name] = ParserTokenType.IDENTIFIER;
    }

    void addEnum(string name)
    {
        if(_types.length < _scopeLevel+1)
            _types.length = _scopeLevel+1;

        _types[_scopeLevel][name] = ParserTokenType.ENUM_VALUE;
    }

    Nullable!ParserTokenType exists(string name)
    {
        foreach_reverse(int i ; 0..min(_types.length, _scopeLevel))
        {
            auto res = name in _types[i];

            if(res !is null)
                return Nullable!ParserTokenType(*res);
        }

        return Nullable!ParserTokenType();
    }

    Nullable!ParserTokenType existsInScope(string name)
    {
        if(_types.length <= _scopeLevel)
            return Nullable!ParserTokenType();

        auto res = name in _types[_scopeLevel];

        if(res is null)
            return Nullable!ParserTokenType();

        return Nullable!ParserTokenType(*res);
    }

    @property bool empty()
    {
        return _lookAhead.empty && _input.empty;
    }

    private auto toParserToken(LexerToken token)
    {
        if(token.type == LexerTokenType.IDENTIFIER)
        {
            if(_withLookup)
            {
                auto identifier = token.value.get!LexerIdentifierTokenValue.name;

                foreach_reverse(int i ; 0..min(_types.length, _scopeLevel+1))
                {
                    auto type = identifier in _types[i];

                    if(type !is null)
                        return ParserToken(*type, token.location, token.value);
                }

                if(builtinTypes.canFind(identifier))
                    return ParserToken(ParserTokenType.TYPE_NAME, token.location, token.value);
            }

            return ParserToken(ParserTokenType.IDENTIFIER, token.location, token.value);
        }

        auto resType = token.type.convertEnum!(LexerTokenType, ParserTokenType, "NUMBER", "ERROR");
        return ParserToken(resType, token.location, token.value);
    }

    @property auto front()
    {
        assert(!_input.empty);
        if(!_lookAhead.empty)
            return toParserToken(_lookAhead.front);
        return toParserToken(_input.front);
    }

    // Retrieve a tokens by looking ahead.
    // k is the number of tokens skiped before the token to return.
    // Skiped tokens are temporary stored, but always re-evaluated later.
    auto lookAhead(int k)
    {
        if(_lookAhead.length > k)
            return toParserToken(_lookAhead[k]);

        foreach(i ; 0..(k-_lookAhead.length))
        {
            assert(!_input.empty);
            pragma(msg, "[FIXME] Handle the case where there is no token left (return EOF?)");
            _lookAhead.put(_input.front);
            _input.popFront();
        }

        assert(!_input.empty);
        auto last = _input.front;
        _input.popFront();
        _lookAhead.put(last); // last value put in cache
        return toParserToken(last);
    }

    void popFront()
    {
        assert(!_lookAhead.empty || !_input.empty);
        if(!_lookAhead.empty)
            _lookAhead.popFront();
        else
            _input.popFront();
    }
}

// A pseudo-LL(2) predictive recursive descent parser
//
// Parsing strategy:
//   This parser is based on the near-C formal grammar itself derived from
//   the official ISO C89 grammar.
//   No backtracking is needed as the current and the next token are always 
//   sufficient to take a good decision (that is why it is a predictive parser).
//   It use some tricks to parse parameterDeclaration due to the ambiguity 
//   of the language using a method we call bottom-up feedback.
//   Indeed, the ISO C89 grammar is not a context free grammar: since a lexer 
//   is not able to detect if identifiers are types or variables (it should 
//   be independent of the grammar), it cause ambiguity during the parsing 
//   of declarations VS expressions.
//   It is important to note the typedef are scoped and that identifiers can 
//   be redefined from type to variables and vice-versa (shadowing).
//   This point is fixed using an intermediate range between the lexer and the
//   parser to track typedefs and define if identifiers are types or variables.
//   The parameterDeclaration rule also cause a lot of issue due to the 
//   aliasing between abstract and concrete declarators.
//
// Error management:
//   The parser stop on the first error encountered and try to report a proper error.
//   In order to report quite readable errors, only the most probable tokens and/or 
//   the one that end the rule are expected (eg. ';' for statements).
pragma(msg, "[FIXME] Check conflicts (LR vs RL)");
pragma(msg, "[FIXME] Check associativity: left to right vs right to left eval (use reverse ?)");
pragma(msg, "[FIXME] Check that the identifier lookup enabling/disabling are put on the good position");
pragma(msg, "[FIXME] Bad error location at the end of the file due to a missing EOF token");
pragma(msg, "[FIXME] Errors should expect rules rather than token subsets (add checks before parsing subrules)");
pragma(msg, "[FIXME] Update the parser range when a declaration is found (typedef, shadow var def, etc.)");
pragma(msg, "[OPTIM] Use a LALR(1) sub-parser for expressions (faster)");
class Parser : IParser, IGo
{
    private
    {
        alias ParserRange = TypedLexerRange!LexerRange;
        alias GenericDeclarator = Algebraic!(Declarator, AbstractDeclarator);
        alias GenericDirectDeclarator = Algebraic!(DirectDeclarator, DirectAbstractDeclarator);

        enum primitiveTypeSpecCount = cast(int)PrimitiveTypeSpecifierEnum.max-cast(int)PrimitiveTypeSpecifierEnum.min+1;
        static assert(PrimitiveTypeSpecifierEnum.min == 0);

        ParserRange _lexer;
        IErrorHandler _errorHandler;
        string[] _funcLocalTypes;
    }


    this(ILexer lexer, IErrorHandler errorHandler)
    {
        _lexer = ParserRange(LexerRange(lexer));
        _errorHandler = errorHandler;
    }


    /******************** GENERIC PARSING FUNCTIONS ********************/

    void fail(string msg, ParserTokenLocation loc = ParserTokenLocation())
    {
        // Skip remaining tokens for the lexical analysis to check further errors
        _lexer.walkLength;

        _errorHandler.criticalError(msg, loc.filename, loc.line, loc.col, loc.length);
    }

    void fail(string msg, AstNodeLocation loc)
    {
        // Skip remaining tokens for the lexical analysis to check further errors
        _lexer.walkLength;

        _errorHandler.criticalError(msg, loc.filename, loc.line, loc.col, loc.length);
    }

    void updateLoc(ref ParserTokenLocation loc)
    {
        if(!_lexer.empty)
            loc = _lexer.front.location;
    }

    void skip(ref ParserTokenLocation loc)
    {
        _lexer.popFront();
        updateLoc(loc);
    }

    bool condSkip(ParserTokenType type)(ref ParserTokenLocation loc)
    {
        if(currTok.type != type)
            return false;

        skip(loc);
        return true;
    }

    void unexpected(string expectedStr, ref ParserTokenLocation loc)
    {
        if(currTok.type == ParserTokenType.EOF)
            fail(format!"expected %s, but got end of file"(expectedStr));
        else
            fail(format!"expecting %s, but got `%s`"(expectedStr, _lexer.front.toString), _lexer.front.location);

        assert(false, "programming error");
    }

    @property ParserToken currTok()
    {
        if(_lexer.empty)
            return ParserToken(ParserTokenType.EOF, ParserTokenLocation(), ParserTokenValue());
        return _lexer.front;
    }

    @property ParserToken nextTok()
    {
        if(_lexer.empty)
            return ParserToken(ParserTokenType.EOF, ParserTokenLocation(), ParserTokenValue());
        return _lexer.lookAhead(1);
    }

    bool hasSpecifier(T)(T[] specifiers)
    {
        return specifiers.any!(e => cast(StorageClassSpecifier)e !is null);
    }

    bool hasSpecifier(T)(T[] specifiers, StorageClassSpecifierEnum toFind)
    {
        foreach(spec ; specifiers)
        {
            auto tmp = cast(StorageClassSpecifier)spec;

            with(StorageClassSpecifierEnum)
                if(tmp !is null && tmp.value == toFind)
                    return true;
        }

        return false;
    }

    bool hasTypedef(DeclarationSpecifier[] specifiers)
    {
        with(StorageClassSpecifierEnum)
            return hasSpecifier(specifiers, TYPEDEF);
    }

    Identifier declaratorId(Declarator decl)
    {
        Declarator nextDecl = decl;

        do
        {
            auto prefix = decl.declarator.prefix;
            decl = nextDecl;
            nextDecl = cast(Declarator)prefix;
        }
        while(nextDecl !is null);

        assert(decl !is null);
        auto declId = cast(DirectDeclaratorIdentifier)decl.declarator.prefix;

        // Unnamed declarator
        if(declId is null)
            return null;

        return declId.identifier;
    }

    void registerDeclarator(Declarator decl, bool isTypedefDecl)
    {
        auto id = declaratorId(decl);

        if(id is null)
            return;

        auto kind = _lexer.existsInScope(id.name);

        with(ParserTokenType)
            if(!kind.isNull && !(isTypedefDecl && kind.get == TYPE_NAME)
                    && !(!isTypedefDecl && kind.get == IDENTIFIER))
                fail(format!"`%s` redeclared as different kind of symbol"(id.name), decl.location);

        if(isTypedefDecl)
            _lexer.addTypeName(id.name);
        else
            _lexer.addVariable(id.name);
    }

    void registerEnumerator(Enumerator enumValue)
    {
        _lexer.addEnum(enumValue.name.name);
    }

    // Check the correctness of a primitive type
    // Take as input an array integer of indexed by PrimitiveTypeSpecifierEnum
    void checkSpecifiers(int[primitiveTypeSpecCount] nTypes, ref ParserTokenLocation loc)
    {
        with(PrimitiveTypeSpecifierEnum)
        {
            // Checking the validity of C types looks like constraint programming...

            foreach(i ; 0..primitiveTypeSpecCount)
                if(nTypes[i] > 1)
                    fail("two or more data types in declaration specifiers", loc);

            if(nTypes[VOID]+nTypes[CHAR]+nTypes[INT]+nTypes[FLOAT]+nTypes[DOUBLE] > 1)
                fail("two or more data types in declaration specifiers", loc);
            else if(nTypes[SHORT] > 0 && nTypes[LONG] > 0)
                fail("both `short` and `long` in declaration specifiers", loc);
            else if(nTypes[SIGNED] > 0 && nTypes[UNSIGNED] > 0)
                fail("both `signed` and `unsigned` in declaration specifiers", loc);
            else if(nTypes[SIGNED]+nTypes[UNSIGNED] > 0 && nTypes[VOID]+nTypes[FLOAT]+nTypes[DOUBLE] > 0)
                fail("invalid type (cannot be signed or unsigned)", loc);
            else if(nTypes[SHORT] > 0 && nTypes[VOID]+nTypes[CHAR]+nTypes[FLOAT]+nTypes[DOUBLE] > 0)
                fail("invalid type (cannot be short)", loc);
            else if(nTypes[LONG] > 0 && nTypes[VOID]+nTypes[CHAR]+nTypes[FLOAT] > 0)
                fail("invalid type (cannot be long)", loc);
        }
    }


    /******************** ACTUAL PARSING FUNCTIONS ********************/

    // LL(1) token table generated by the analysis python script from the formal grammar.
    // Warning: since TYPE_NAME/ENUM_VALUE tokens should sometime be read as
    // IDENTIFIER tokens, TYPE_NAME/ENUM tokens are added to those functions.
    // The modified rules are marked as @fixed, some of them (such as with 
    // look-ahead) can cause conflits with others and are marked as @viral.
    enum fixed;
    enum viral;
    @fixed bool matchTranslationUnit(ParserToken token) { with(ParserTokenType) return token.type.among(SHORT, ENUM, CONST, UNSIGNED, TYPE_NAME, DOUBLE, EXTERN, STATIC, SIGNED, OP_MUL, AUTO, REGISTER, TYPEDEF, STRUCT, VOID, UNION, INT, FLOAT, IDENTIFIER, CHAR, LONG, LPAREN, VOLATILE, ENUM_VALUE) > 0; };
    @fixed bool matchExternalDeclaration(ParserToken token) { with(ParserTokenType) return token.type.among(OP_MUL, SHORT, AUTO, REGISTER, ENUM, CONST, TYPEDEF, STRUCT, VOID, UNSIGNED, TYPE_NAME, UNION, INT, FLOAT, IDENTIFIER, CHAR, LONG, LPAREN, DOUBLE, EXTERN, VOLATILE, STATIC, SIGNED, ENUM_VALUE) > 0; };
    bool matchDeclarationSpecifier(ParserToken token) { with(ParserTokenType) return token.type.among(SHORT, AUTO, REGISTER, ENUM, CONST, TYPEDEF, STRUCT, VOID, UNSIGNED, TYPE_NAME, UNION, INT, FLOAT, CHAR, LONG, DOUBLE, EXTERN, VOLATILE, STATIC, SIGNED) > 0; };
    bool matchStorageClassSpecifier(ParserToken token) { with(ParserTokenType) return token.type.among(TYPEDEF, EXTERN, AUTO, STATIC, REGISTER) > 0; };
    bool matchTypeSpecifier(ParserToken token) { with(ParserTokenType) return token.type.among(UNION, SHORT, INT, FLOAT, CHAR, LONG, ENUM, DOUBLE, STRUCT, VOID, UNSIGNED, SIGNED, TYPE_NAME) > 0; };
    bool matchStructOrUnionSpecifier(ParserToken token) { with(ParserTokenType) return token.type.among(UNION, STRUCT) > 0; };
    @fixed bool matchStructDeclaration(ParserToken token) { with(ParserTokenType) return token.type.among(UNION, SHORT, INT, FLOAT, OP_MUL, COL, IDENTIFIER, CHAR, LONG, LPAREN, ENUM, DOUBLE, CONST, STRUCT, TYPE_NAME, VOID, UNSIGNED, SIGNED, VOLATILE, ENUM_VALUE) > 0; };
    bool matchSpecifierQualifier(ParserToken token) { with(ParserTokenType) return token.type.among(UNION, SHORT, INT, FLOAT, CHAR, LONG, VOLATILE, ENUM, DOUBLE, CONST, STRUCT, VOID, UNSIGNED, SIGNED, TYPE_NAME) > 0; };
    @fixed bool matchStructDeclaratorList(ParserToken token) { with(ParserTokenType) return token.type.among(OP_MUL, COL, LPAREN, IDENTIFIER, TYPE_NAME, ENUM_VALUE) > 0; };
    @fixed bool matchStructDeclarator(ParserToken token) { with(ParserTokenType) return token.type.among(OP_MUL, COL, LPAREN, IDENTIFIER, TYPE_NAME, ENUM_VALUE) > 0; };
    @fixed bool matchDeclarator(ParserToken token) { with(ParserTokenType) return token.type.among(OP_MUL, LPAREN, IDENTIFIER, TYPE_NAME, ENUM_VALUE) > 0; };
    bool matchPointer(ParserToken token) { with(ParserTokenType) return token.type.among(OP_MUL) > 0; };
    bool matchTypeQualifier(ParserToken token) { with(ParserTokenType) return token.type.among(CONST, VOLATILE) > 0; };
    @fixed bool matchDirectDeclarator(ParserToken token) { with(ParserTokenType) return token.type.among(LPAREN, IDENTIFIER, TYPE_NAME, ENUM_VALUE) > 0; };
    bool matchConstantExpression(ParserToken token) { with(ParserTokenType) return token.type.among(OP_MUL, OP_NOT, OP_ADD, NUMBER, SIZEOF, OP_SUB, IDENTIFIER, INTEGER, CHARACTER, LPAREN, ENUM_VALUE, STRING, OP_BNOT, OP_DEC, OP_INC, OP_BAND) > 0; };
    bool matchConditionalExpression(ParserToken token) { with(ParserTokenType) return token.type.among(OP_MUL, OP_NOT, OP_ADD, NUMBER, SIZEOF, OP_SUB, IDENTIFIER, INTEGER, CHARACTER, LPAREN, ENUM_VALUE, STRING, OP_BNOT, OP_DEC, OP_INC, OP_BAND) > 0; };
    bool matchLogicalOrExpression(ParserToken token) { with(ParserTokenType) return token.type.among(OP_MUL, OP_NOT, OP_ADD, NUMBER, SIZEOF, OP_SUB, IDENTIFIER, INTEGER, CHARACTER, LPAREN, ENUM_VALUE, STRING, OP_BNOT, OP_DEC, OP_INC, OP_BAND) > 0; };
    bool matchLogicalAndExpression(ParserToken token) { with(ParserTokenType) return token.type.among(OP_MUL, OP_NOT, OP_ADD, NUMBER, SIZEOF, OP_SUB, IDENTIFIER, INTEGER, CHARACTER, LPAREN, ENUM_VALUE, STRING, OP_BNOT, OP_DEC, OP_INC, OP_BAND) > 0; };
    bool matchInclusiveOrExpression(ParserToken token) { with(ParserTokenType) return token.type.among(OP_MUL, OP_NOT, OP_ADD, NUMBER, SIZEOF, OP_SUB, IDENTIFIER, INTEGER, CHARACTER, LPAREN, ENUM_VALUE, STRING, OP_BNOT, OP_DEC, OP_INC, OP_BAND) > 0; };
    bool matchExclusiveOrExpression(ParserToken token) { with(ParserTokenType) return token.type.among(OP_MUL, OP_NOT, OP_ADD, NUMBER, SIZEOF, OP_SUB, IDENTIFIER, INTEGER, CHARACTER, LPAREN, ENUM_VALUE, STRING, OP_BNOT, OP_DEC, OP_INC, OP_BAND) > 0; };
    bool matchAndExpression(ParserToken token) { with(ParserTokenType) return token.type.among(OP_MUL, OP_NOT, OP_ADD, NUMBER, SIZEOF, OP_SUB, IDENTIFIER, INTEGER, CHARACTER, LPAREN, ENUM_VALUE, STRING, OP_BNOT, OP_DEC, OP_INC, OP_BAND) > 0; };
    bool matchEqualityExpression(ParserToken token) { with(ParserTokenType) return token.type.among(OP_MUL, OP_NOT, OP_ADD, NUMBER, SIZEOF, OP_SUB, IDENTIFIER, INTEGER, CHARACTER, LPAREN, ENUM_VALUE, STRING, OP_BNOT, OP_DEC, OP_INC, OP_BAND) > 0; };
    bool matchRelationalExpression(ParserToken token) { with(ParserTokenType) return token.type.among(OP_MUL, OP_NOT, OP_ADD, NUMBER, SIZEOF, OP_SUB, IDENTIFIER, INTEGER, CHARACTER, LPAREN, ENUM_VALUE, STRING, OP_BNOT, OP_DEC, OP_INC, OP_BAND) > 0; };
    bool matchShiftExpression(ParserToken token) { with(ParserTokenType) return token.type.among(OP_MUL, OP_NOT, OP_ADD, NUMBER, SIZEOF, OP_SUB, IDENTIFIER, INTEGER, CHARACTER, LPAREN, ENUM_VALUE, STRING, OP_BNOT, OP_DEC, OP_INC, OP_BAND) > 0; };
    bool matchAdditiveExpression(ParserToken token) { with(ParserTokenType) return token.type.among(OP_MUL, OP_NOT, OP_ADD, NUMBER, SIZEOF, OP_SUB, IDENTIFIER, INTEGER, CHARACTER, LPAREN, ENUM_VALUE, STRING, OP_BNOT, OP_DEC, OP_INC, OP_BAND) > 0; };
    bool matchMultiplicativeExpression(ParserToken token) { with(ParserTokenType) return token.type.among(OP_MUL, OP_NOT, OP_ADD, NUMBER, SIZEOF, OP_SUB, IDENTIFIER, INTEGER, CHARACTER, LPAREN, ENUM_VALUE, STRING, OP_BNOT, OP_DEC, OP_INC, OP_BAND) > 0; };
    bool matchCastExpression(ParserToken token) { with(ParserTokenType) return token.type.among(OP_MUL, OP_NOT, OP_ADD, NUMBER, SIZEOF, OP_SUB, IDENTIFIER, INTEGER, CHARACTER, LPAREN, ENUM_VALUE, STRING, OP_BNOT, OP_DEC, OP_INC, OP_BAND) > 0; };
    bool matchUnaryExpression(ParserToken token) { with(ParserTokenType) return token.type.among(OP_MUL, OP_NOT, OP_ADD, NUMBER, SIZEOF, OP_SUB, IDENTIFIER, INTEGER, CHARACTER, LPAREN, ENUM_VALUE, STRING, OP_BNOT, OP_DEC, OP_INC, OP_BAND) > 0; };
    bool matchPostfixExpression(ParserToken token) { with(ParserTokenType) return token.type.among(NUMBER, IDENTIFIER, INTEGER, ENUM_VALUE, CHARACTER, LPAREN, STRING) > 0; };
    bool matchPrimaryExpression(ParserToken token) { with(ParserTokenType) return token.type.among(NUMBER, IDENTIFIER, INTEGER, ENUM_VALUE, CHARACTER, LPAREN, STRING) > 0; };
    bool matchConstant(ParserToken token) { with(ParserTokenType) return token.type.among(INTEGER, CHARACTER, NUMBER, ENUM_VALUE) > 0; };
    bool matchCompositeExpression(ParserToken token) { with(ParserTokenType) return token.type.among(OP_MUL, OP_NOT, OP_ADD, NUMBER, SIZEOF, OP_SUB, IDENTIFIER, INTEGER, CHARACTER, LPAREN, ENUM_VALUE, STRING, OP_BNOT, OP_DEC, OP_INC, OP_BAND) > 0; };
    bool matchAssignmentExpression(ParserToken token) { with(ParserTokenType) return token.type.among(OP_MUL, OP_NOT, OP_ADD, NUMBER, SIZEOF, OP_SUB, IDENTIFIER, INTEGER, CHARACTER, LPAREN, ENUM_VALUE, STRING, OP_BNOT, OP_DEC, OP_INC, OP_BAND) > 0; };
    bool matchAssignmentOperator(ParserToken token) { with(ParserTokenType) return token.type.among(ASSIGN, ADD_ASSIGN, OR_ASSIGN, RSHIFT_ASSIGN, AND_ASSIGN, DIV_ASSIGN, LSHIFT_ASSIGN, MUL_ASSIGN, MOD_ASSIGN, SUB_ASSIGN, XOR_ASSIGN) > 0; };
    bool matchUnaryOperator(ParserToken token) { with(ParserTokenType) return token.type.among(OP_MUL, OP_NOT, OP_ADD, OP_BNOT, OP_SUB, OP_BAND) > 0; };
    bool matchTypename(ParserToken token) { with(ParserTokenType) return token.type.among(UNION, SHORT, INT, FLOAT, VOID, CHAR, LONG, ENUM, DOUBLE, CONST, STRUCT, VOLATILE, UNSIGNED, SIGNED, TYPE_NAME) > 0; };
    bool matchParameterList(ParserToken token) { with(ParserTokenType) return token.type.among(UNION, SHORT, INT, FLOAT, AUTO, CHAR, REGISTER, LONG, ENUM, DOUBLE, CONST, VOLATILE, TYPEDEF, STRUCT, EXTERN, VOID, UNSIGNED, STATIC, SIGNED, TYPE_NAME) > 0; };
    bool matchParameterDeclaration(ParserToken token) { with(ParserTokenType) return token.type.among(UNION, SHORT, INT, FLOAT, AUTO, CHAR, REGISTER, LONG, ENUM, DOUBLE, CONST, VOLATILE, TYPEDEF, STRUCT, EXTERN, VOID, UNSIGNED, STATIC, SIGNED, TYPE_NAME) > 0; };
    @fixed bool matchGenericDeclarator(ParserToken token) { with(ParserTokenType) return token.type.among(LBRACK, OP_MUL, LPAREN, IDENTIFIER, TYPE_NAME, ENUM_VALUE) > 0; };
    @fixed bool matchGenericDirectDeclarator(ParserToken token) { with(ParserTokenType) return token.type.among(LBRACK, LPAREN, IDENTIFIER, TYPE_NAME, ENUM_VALUE) > 0; };
    bool matchAbstractDeclarator(ParserToken token) { with(ParserTokenType) return token.type.among(LBRACK, OP_MUL, LPAREN) > 0; };
    bool matchDirectAbstractDeclarator(ParserToken token) { with(ParserTokenType) return token.type.among(LBRACK, LPAREN) > 0; };
    bool matchEnumSpecifier(ParserToken token) { with(ParserTokenType) return token.type.among(ENUM) > 0; };
    @fixed bool matchEnumerator(ParserToken token) { with(ParserTokenType) return token.type.among(IDENTIFIER, ENUM_VALUE, TYPE_NAME) > 0; };
    bool matchDeclaration(ParserToken token) { with(ParserTokenType) return token.type.among(UNION, SHORT, INT, FLOAT, AUTO, CHAR, REGISTER, LONG, ENUM, DOUBLE, CONST, VOLATILE, TYPEDEF, STRUCT, EXTERN, VOID, UNSIGNED, STATIC, SIGNED, TYPE_NAME) > 0; };
    @fixed bool matchInitDeclarator(ParserToken token) { with(ParserTokenType) return token.type.among(OP_MUL, LPAREN, IDENTIFIER, TYPE_NAME, ENUM_VALUE) > 0; };
    bool matchInitializer(ParserToken token) { with(ParserTokenType) return token.type.among(OP_MUL, OP_NOT, LCURL, OP_ADD, NUMBER, SIZEOF, OP_SUB, IDENTIFIER, INTEGER, CHARACTER, LPAREN, ENUM_VALUE, STRING, OP_BNOT, OP_DEC, OP_INC, OP_BAND) > 0; };
    bool matchInitializerList(ParserToken token) { with(ParserTokenType) return token.type.among(LCURL) > 0; };
    bool matchCompoundStatement(ParserToken token) { with(ParserTokenType) return token.type.among(LCURL) > 0; };
    @viral bool matchStatement(ParserToken token) { with(ParserTokenType) return token.type.among(OP_MUL, OP_NOT, BREAK, CONTINUE, IF, OP_INC, LCURL, OP_ADD, NUMBER, GOTO, SIZEOF, FOR, SEMICOLON, WHILE, OP_SUB, SWITCH, DEFAULT, DO, IDENTIFIER, INTEGER, CHARACTER, LPAREN, RETURN, ENUM_VALUE, STRING, OP_BNOT, OP_DEC, CASE, OP_BAND, TYPE_NAME) > 0; };
    @viral bool matchLabeledStatement(ParserToken token) { with(ParserTokenType) return token.type.among(CASE, DEFAULT, IDENTIFIER, ENUM_VALUE, TYPE_NAME) > 0; };
    bool matchExpressionStatement(ParserToken token) { with(ParserTokenType) return token.type.among(OP_MUL, OP_NOT, IDENTIFIER, INTEGER, CHARACTER, LPAREN, OP_ADD, ENUM_VALUE, STRING, NUMBER, OP_BNOT, SIZEOF, OP_DEC, SEMICOLON, OP_INC, OP_SUB, OP_BAND) > 0; };
    bool matchSelectionStatement(ParserToken token) { with(ParserTokenType) return token.type.among(SWITCH, IF) > 0; };
    bool matchIterationStatement(ParserToken token) { with(ParserTokenType) return token.type.among(WHILE, DO, FOR) > 0; };
    bool matchJumpStatement(ParserToken token) { with(ParserTokenType) return token.type.among(CONTINUE, GOTO, BREAK, RETURN) > 0; };
    bool matchPrimitiveType(ParserToken token) { with(ParserTokenType) return token.type.among(VOID, CHAR, SHORT, INT, LONG, FLOAT, DOUBLE, UNSIGNED, SIGNED) > 0; };

    override void go()
    {
        auto loc = currTok.location;
        parseTranslationUnit(loc);

        pragma(msg, "[FIXME] to be continued");
    }

    TranslationUnit parseTranslationUnit(ref ParserTokenLocation loc)
    {
        auto startLoc = loc;
        auto externalDecls = appender!(ExternalDeclaration[])();

        while(matchExternalDeclaration(currTok))
            externalDecls ~= parseExternalDeclaration(loc);

        with(ParserTokenType)
            if(currTok.type != EOF)
                unexpected("declaration or function", loc);

        return new TranslationUnit(externalDecls.data, toAstLoc(startLoc, loc));
    }

    ExternalDeclaration parseExternalDeclaration(ref ParserTokenLocation loc)
    {
        with(ParserTokenType)
        {
            auto startLoc = loc;
            DeclarationSpecifier[] declSpecs;

            if(matchDeclarationSpecifier(currTok))
                declSpecs = parseDeclarationSpecifiers(loc);

            // Note: nothing to register for unnamed declarations
            if(!declSpecs.empty && condSkip!SEMICOLON(loc))
                return new Declaration(declSpecs, [], toAstLoc(startLoc, loc));

            const bool isTypedefDecl = hasTypedef(declSpecs);
            auto declarator = parseDeclarator(loc);

            if(currTok.type.among(ASSIGN, COMMA, SEMICOLON))
            {
                auto initDecls = appender!(InitDeclarator[])();
                Initializer initializer = null;

                if(condSkip!ASSIGN(loc))
                    initializer = parseInitializer(loc);

                auto decl = new InitDeclarator(declarator, initializer, toAstLoc(startLoc, loc));
                registerDeclarator(decl.declarator, isTypedefDecl);
                initDecls ~= decl;

                while(condSkip!COMMA(loc))
                {
                    decl = parseInitDeclarator(loc);
                    registerDeclarator(decl.declarator, isTypedefDecl);
                    initDecls ~= decl;
                }

                if(!condSkip!SEMICOLON(loc))
                    unexpected("`;`", loc);

                return new Declaration(declSpecs, initDecls.data, toAstLoc(startLoc, loc));
            }
            else if(matchDeclaration(currTok) || matchCompoundStatement(currTok))
            {
                auto funcDecl = declarator.declarator;
                auto declarations = appender!(Declaration[])();

                // Since the C grammar is very permissive on declarations,
                // additional checks are required

                if(funcDecl.elements.length == 0)
                    unexpected("`;` or function parameter list", startLoc);

                pragma(msg, "[FIXME] check how to parse this properly and add checks (choose the first or the last element?)");
                //if(declarator.pointer !is null)
                //    fail("malformed function definition", startLoc);

                if(funcDecl.elements.length > 0
                        && cast(DirectDeclaratorArray)funcDecl.elements[0] !is null)
                    unexpected("`;`", startLoc);

                if(funcDecl.elements.length != 1)
                    fail("malformed function definition", startLoc);

                auto newStyleDecl = cast(DirectDeclaratorTypedParams)funcDecl.elements[0];
                auto oldStyleDecl = cast(DirectDeclaratorUntypedParams)funcDecl.elements[0];

                // The scope is manually controled put the parameter 
                // declarations into the scope of the function body
                _lexer.beginScope();

                if(matchDeclaration(currTok))
                {
                    if(newStyleDecl)
                        fail("old-style parameter declarations in prototyped function definition", loc);

                    do
                        declarations ~= parseDeclaration(loc);
                    while(matchDeclaration(currTok));
                }

                // Inject parameter declarations in the current scope
                if(newStyleDecl)
                {
                    foreach(arg ; newStyleDecl.args.args)
                    {
                        auto concreteDecl = cast(ConcreteParameterDeclaration)arg;
                        auto abstractDecl = cast(AbstractParameterDeclaration)arg;
                        assert(concreteDecl !is null || abstractDecl !is null);

                        if(concreteDecl !is null && concreteDecl.declarator !is null)
                            registerDeclarator(concreteDecl.declarator, false);
                        else if(abstractDecl !is null && abstractDecl.declarator !is null)
                            assert(false);// TODO: possible ???
                        pragma(msg, "[FIXME] Support abstract declarator (if really needed)");
                    }
                }

                auto statement = parseCompoundStatement(loc, false);

                _lexer.endScope();

                return new FunctionDefinition(declSpecs, declarator, declarations.data, 
                                                statement, toAstLoc(startLoc, loc));
            }

            unexpected("declaration or function body", loc);
            assert(false);
        }
    }

    // Parse multiple declaration specifiers at once.
    // The parsing should not be as greedy as the grammar since
    // declarations can contain types as variable names (shadowing)
    DeclarationSpecifier[] parseDeclarationSpecifiers(ref ParserTokenLocation loc)
    {
        auto startLoc = loc;
        auto declSpecs = appender!(DeclarationSpecifier[])();
        bool storageClassSpecFound = false;
        bool isPrimitiveType = false;
        bool isUserType = false;
        int[primitiveTypeSpecCount] nTypes = 0;

        pragma(msg, "[FIXME] Add type checking in the semantics (eg. auto in global scope, duplicated qualifiers)");

        do
        {
            if(matchStorageClassSpecifier(currTok))
            {
                if(storageClassSpecFound)
                    fail("multiple storage class specifier", startLoc);

                declSpecs ~= parseStorageClassSpecifier(loc);
                storageClassSpecFound = true;
            }
            else if(matchTypeSpecifier(currTok))
            {
                if(isUserType || isPrimitiveType && !matchPrimitiveType(currTok))
                    break;

                auto spec = parseTypeSpecifier(loc);
                auto primitiveSpec = cast(PrimitiveTypeSpecifier)spec;

                if(primitiveSpec !is null)
                    nTypes[primitiveSpec.value]++;

                isPrimitiveType |= primitiveSpec !is null;
                isUserType |= primitiveSpec is null;
                declSpecs ~= spec;
            }
            else if(matchTypeQualifier(currTok))
            {
                declSpecs ~= parseTypeQualifier(loc);
            }
            else
            {
                unexpected("declaration specifier", loc);
            }
        }
        while(matchDeclarationSpecifier(currTok));

        checkSpecifiers(nTypes, startLoc);
        assert((isPrimitiveType && isUserType) == false);
        return declSpecs.data;
    }

    StorageClassSpecifier parseStorageClassSpecifier(ref ParserTokenLocation loc)
    {
        static foreach(e ; ["AUTO", "REGISTER", "STATIC", "EXTERN", "TYPEDEF"])
            if(condSkip!(mixin("ParserTokenType." ~ e))(loc))
                return new StorageClassSpecifier(mixin("StorageClassSpecifierEnum." ~ e), loc.toAstLoc);

        unexpected("storage class specifier", loc);
        assert(false);
    }

    TypeSpecifier parseTypeSpecifier(ref ParserTokenLocation loc)
    {
        static foreach(e ; ["VOID", "CHAR", "SHORT", "INT", "LONG", "FLOAT", "DOUBLE", "SIGNED", "UNSIGNED"])
            if(condSkip!(mixin("ParserTokenType." ~ e))(loc))
                return new PrimitiveTypeSpecifier(mixin("PrimitiveTypeSpecifierEnum." ~ e), loc.toAstLoc);

        if(matchStructOrUnionSpecifier(currTok))
            return parseStructOrUnionSpecifier(loc);
        else if(matchEnumSpecifier(currTok))
            return parseEnumSpecifier(loc);
        else if(currTok.type == ParserTokenType.TYPE_NAME)
            return parseUserTypeSpecifier(loc);

        unexpected("type specifier", loc);
        assert(false);
    }

    AggregateTypeSpecifier parseStructOrUnionSpecifier(ref ParserTokenLocation loc)
    {
        with(ParserTokenType)
        {
            auto startLoc = loc;
            Identifier id = null;
            auto declarations = appender!(StructDeclaration[])();

            const bool isUnion = condSkip!UNION(loc);

            if(!isUnion && !condSkip!STRUCT(loc))
                unexpected("struct or union keywords", loc);

            _lexer.disableLookup();

            if(currTok.type == IDENTIFIER)
                id = parseIdentifier(loc);

            _lexer.enableLookup();

            if(condSkip!LCURL(loc))
            {
                while(matchStructDeclaration(currTok))
                    declarations ~= parseStructDeclaration(loc);

                if(declarations.data.empty)
                {
                    if(isUnion)
                        fail("the C standard forbid empty unions", loc);
                    else
                        fail("the C standard forbid empty structures", loc);
                }

                if(!condSkip!RCURL(loc))
                    unexpected("`}`", loc);
            }

            if(id is null && declarations.data.empty)
                unexpected("identifier or struct/union body", loc);

            return new AggregateTypeSpecifier(isUnion, id, declarations.data, toAstLoc(startLoc, loc));
        }
    }

    StructDeclaration parseStructDeclaration(ref ParserTokenLocation loc)
    {
        with(ParserTokenType)
        {
            auto startLoc = loc;
            SpecifierQualifier[] typeParts;
            auto declarators = appender!(StructDeclarator[]);

            if(matchSpecifierQualifier(currTok))
                typeParts = parseSpecifierQualifiers(loc);

            do
                declarators ~= parseStructDeclarator(loc);
            while(condSkip!COMMA(loc));

            if(!condSkip!SEMICOLON(loc))
                unexpected("`;`", loc);

            return new StructDeclaration(typeParts, declarators.data, toAstLoc(startLoc, loc));
        }
    }

    // Parse multiple specifier-qualifiers at once.
    // See parseDeclarationSpecifiers for more information.
    SpecifierQualifier[] parseSpecifierQualifiers(ref ParserTokenLocation loc)
    {
        auto startLoc = loc;
        auto specQualifiers = appender!(SpecifierQualifier[])();
        bool isPrimitiveType = false;
        bool isUserType = false;
        int[primitiveTypeSpecCount] nTypes = 0;

        if(!matchSpecifierQualifier(currTok))
            unexpected("specifier qualifier", loc);

        do
        {
            if(matchTypeSpecifier(currTok))
            {
                if(isUserType || isPrimitiveType && !matchPrimitiveType(currTok))
                    break;

                auto spec = parseTypeSpecifier(loc);
                auto primitiveSpec = cast(PrimitiveTypeSpecifier)spec;

                if(primitiveSpec !is null)
                    nTypes[primitiveSpec.value]++;

                isPrimitiveType |= primitiveSpec !is null;
                isUserType |= primitiveSpec is null;
                specQualifiers ~= spec;
            }
            else if(matchTypeQualifier(currTok))
            {
                specQualifiers ~= parseTypeQualifier(loc);
            }
        }
        while(matchSpecifierQualifier(currTok));

        checkSpecifiers(nTypes, startLoc);
        assert((isPrimitiveType && isUserType) == false);
        return specQualifiers.data;
    }

    StructDeclarator parseStructDeclarator(ref ParserTokenLocation loc)
    {
        auto startLoc = loc;
        Declarator decl = null;
        Expression expr = null;

        if(matchDeclarator(currTok))
            decl = parseDeclarator(loc);

        with(ParserTokenType)
            if(condSkip!COL(loc))
                expr = parseConstantExpression(loc);

        if(decl is null && expr is null)
            unexpected("declarator or `:`", loc);

        return new StructDeclarator(decl, expr, toAstLoc(startLoc, loc));
    }

    Declarator parseDeclarator(ref ParserTokenLocation loc)
    {
        auto startLoc = loc;
        Pointer pointer = null;

        if(matchPointer(currTok))
            pointer = parsePointer(loc);

        auto decl = parseDirectDeclarator(loc);
        return new Declarator(pointer, decl, toAstLoc(startLoc, loc));
    }

    Pointer parsePointer(ref ParserTokenLocation loc)
    {
        with(ParserTokenType)
        {
            Pointer result = null;

            if(!condSkip!OP_MUL(loc))
                unexpected("`*`", loc);

            do
            {
                auto startLoc = loc;
                auto qualifiers = appender!(TypeQualifier[]);

                while(matchTypeQualifier(currTok))
                    qualifiers ~= parseTypeQualifier(loc);

                // Top-down/Right-left recursion
                result = new Pointer(qualifiers.data, result, toAstLoc(startLoc, loc));
            }
            while(condSkip!OP_MUL(loc));

            return result;
        }
    }

    TypeQualifier parseTypeQualifier(ref ParserTokenLocation loc)
    {
        static foreach(e ; ["CONST", "VOLATILE"])
            if(condSkip!(mixin("ParserTokenType." ~ e))(loc))
                return new TypeQualifier(mixin("TypeQualifierEnum." ~ e), loc.toAstLoc);

        unexpected("type qualifier", loc);
        assert(false);
    }

    DirectDeclarator parseDirectDeclarator(ref ParserTokenLocation loc)
    {
        auto startLoc = loc;
        auto declBase = parseDirectDeclaratorHead(loc);
        auto declElems = parseDirectDeclaratorTail(loc);
        return new DirectDeclarator(declBase, declElems, toAstLoc(startLoc, loc));
    }

    DirectDeclaratorBase parseDirectDeclaratorHead(ref ParserTokenLocation loc)
    {
        with(ParserTokenType)
        {
            auto startLoc = loc;

            _lexer.disableLookup();

            // Note: Enumerators are allowed here since the override of an
            // enumerator will produce a clearer error later (symbol table)
            if(currTok.type == IDENTIFIER || currTok.type == ENUM_VALUE)
            {
                auto id = parseIdentifier(loc);
                _lexer.enableLookup();
                return new DirectDeclaratorIdentifier(id, toAstLoc(startLoc, loc));
            }

            _lexer.enableLookup();

            if(condSkip!LPAREN(loc))
            {
                auto decl = parseDeclarator(loc);

                if(!condSkip!RPAREN(loc))
                    unexpected("`)`", loc);

                return decl;
            }

            unexpected("identifier or `(`", loc);
            assert(false);
        }
    }

    DirectDeclaratorElement[] parseDirectDeclaratorTail(ref ParserTokenLocation loc)
    {
        with(ParserTokenType)
        {
            auto declElems = appender!(DirectDeclaratorElement[]);

            while(currTok.type.among(LBRACK, LPAREN))
            {
                auto startLoc = loc;

                if(condSkip!LBRACK(loc))
                {
                    Expression expr = null;

                    if(matchConstantExpression(currTok))
                        expr = parseConstantExpression(loc);

                    if(!condSkip!RBRACK(loc))
                        unexpected("`]`", loc);

                    declElems ~= new DirectDeclaratorArray(expr, toAstLoc(startLoc, loc));
                }
                else if(condSkip!LPAREN(loc))
                {
                    if(matchParameterList(currTok))
                    {
                        auto paramList = parseParameterList(loc);
                        declElems ~= new DirectDeclaratorTypedParams(paramList, toAstLoc(startLoc, loc));
                    }
                    else if(currTok.type.among(IDENTIFIER, ENUM_VALUE))
                    {
                        auto args = appender!(Identifier[])();

                        pragma(msg, "[FIXME] check if parsing type here is allowed by the strict C89");

                        do
                        {
                            if(currTok.type == ENUM_VALUE)
                            {
                                _lexer.disableLookup();
                                args ~= parseIdentifier(loc);
                                _lexer.enableLookup();
                            }
                            else
                            {
                                args ~= parseIdentifier(loc);
                            }
                        }
                        while(condSkip!COMMA(loc));

                        declElems ~= new DirectDeclaratorUntypedParams(args.data, toAstLoc(startLoc, loc));
                    }
                    else
                    {
                        declElems ~= new DirectDeclaratorUntypedParams([], toAstLoc(startLoc, loc));
                    }

                    if(!condSkip!RPAREN(loc))
                        unexpected("`)`", loc);
                }
            }

            return declElems.data;
        }
    }

    Expression parseConstantExpression(ref ParserTokenLocation loc)
    {
        return parseConditionalExpression(loc);
    }

    Expression parseConditionalExpression(ref ParserTokenLocation loc)
    {
        with(ParserTokenType)
        {
            auto startLoc = loc;

            auto condExpr = parseLogicalOrExpression(loc);

            if(!condSkip!QMARK(loc))
                return condExpr;

            Expression whenTrueExpr = parseCompositeExpression(loc);

            if(!condSkip!COL(loc))
                unexpected("`:`", loc);

            Expression whenFalseExpr = parseConditionalExpression(loc);
            return new ConditionalExpression(condExpr, whenTrueExpr, whenFalseExpr, toAstLoc(startLoc, loc));
        }
    }

    Expression parseBinaryExpression(string[] opChoices, alias parseFunc)(ref ParserTokenLocation loc)
    {
        auto startLoc = loc;

        auto left = parseFunc(loc);

        while(true)
        {
            BinaryOperator currBinOpType;

            // Find the BinaryOperator from the current ParserTokenType
            // Generate an efficient code for all possible cases in opChoices
            tokenSwitch: switch(currTok.type)
            {
                static foreach(operator ; opChoices)
                {
                    case mixin("ParserTokenType.OP_" ~ operator):
                        currBinOpType = mixin("BinaryOperator." ~ operator);
                        break tokenSwitch;
                }
                default: return left;
            }

            skip(loc);
            auto right = parseFunc(loc);
            left = new BinaryExpression(currBinOpType, left, right, toAstLoc(startLoc, loc));
        }

        return left;
    }

    Expression parseLogicalOrExpression(ref ParserTokenLocation loc)
    {
        return parseBinaryExpression!(["OR"], parseLogicalAndExpression)(loc);
    }

    Expression parseLogicalAndExpression(ref ParserTokenLocation loc)
    {
        return parseBinaryExpression!(["AND"], parseInclusiveOrExpression)(loc);
    }

    Expression parseInclusiveOrExpression(ref ParserTokenLocation loc)
    {
        return parseBinaryExpression!(["BOR"], parseExclusiveOrExpression)(loc);
    }

    Expression parseExclusiveOrExpression(ref ParserTokenLocation loc)
    {
        return parseBinaryExpression!(["BXOR"], parseAndExpression)(loc);
    }

    Expression parseAndExpression(ref ParserTokenLocation loc)
    {
        return parseBinaryExpression!(["BAND"], parseEqualityExpression)(loc);
    }

    Expression parseEqualityExpression(ref ParserTokenLocation loc)
    {
        return parseBinaryExpression!(["EQ", "NE"], parseRelationalExpression)(loc);
    }

    Expression parseRelationalExpression(ref ParserTokenLocation loc)
    {
        return parseBinaryExpression!(["LT", "GT", "LE", "GE"], parseShiftExpression)(loc);
    }

    Expression parseShiftExpression(ref ParserTokenLocation loc)
    {
        return parseBinaryExpression!(["LSHIFT", "RSHIFT"], parseAdditiveExpression)(loc);
    }

    Expression parseAdditiveExpression(ref ParserTokenLocation loc)
    {
        return parseBinaryExpression!(["ADD", "SUB"], parseMultiplicativeExpression)(loc);
    }

    Expression parseMultiplicativeExpression(ref ParserTokenLocation loc)
    {
        return parseBinaryExpression!(["MUL", "DIV", "MOD"], parseCastExpression)(loc);
    }

    Expression parseCastExpression(ref ParserTokenLocation loc)
    {
        with(ParserTokenType)
        {
            auto startLoc = loc;

            if(currTok.type == LPAREN && matchTypename(nextTok))
            {
                skip(loc);

                auto typename = parseTypename(loc);

                if(!condSkip!RPAREN(loc))
                    unexpected("`)`", loc);

                auto expr = parseCastExpression(loc);
                return new CastExpression(typename, expr, toAstLoc(startLoc, loc));
            }
            
            return parseUnaryExpression(loc);
        }
    }

    Expression parseUnaryExpression(ref ParserTokenLocation loc)
    {
        with(ParserTokenType)
        {
            auto startLoc = loc;

            if(matchPostfixExpression(currTok))
                return parsePostfixExpression(loc);

            if(matchUnaryOperator(currTok))
            {
                auto op = parseUnaryOperator(loc);
                auto expr = parseCastExpression(loc);
                return new BasicUnaryExpression(op, expr, toAstLoc(startLoc, loc));
            }

            if(currTok.type.among(OP_INC, OP_DEC))
            {
                const bool isIncremented = currTok.type == OP_INC;
                skip(loc);
                auto expr = parseUnaryExpression(loc);
                return new PrefixIncrementExpression(expr, isIncremented, toAstLoc(startLoc, loc));
            }

            if(condSkip!SIZEOF(loc))
            {
                if(currTok.type == LPAREN && matchTypename(nextTok))
                {
                    skip(loc);

                    auto typename = parseTypename(loc);

                    if(!condSkip!RPAREN(loc))
                        unexpected("`)`", loc);

                    return new SimpleSizeofExpression(typename, toAstLoc(startLoc, loc));
                }

                auto expr = parseUnaryExpression(loc);
                return new ComplexSizeofExpression(expr, toAstLoc(startLoc, loc));
            }

            unexpected("unary expression", loc);
            assert(false);
        }
    }

    Expression parsePostfixExpression(ref ParserTokenLocation loc)
    {
        with(ParserTokenType)
        {
            auto startLoc = loc;
            auto leftExpr = parsePrimaryExpression(loc);

            while(true)
            {
                auto tokenType = currTok.type;

                switch(tokenType)
                {
                    case LBRACK:
                        Expression indexExpr = null;

                        skip(loc);

                        if(matchCompositeExpression(currTok))
                            indexExpr = parseCompositeExpression(loc);

                        if(!condSkip!RBRACK(loc))
                            unexpected("`]`", loc);

                        leftExpr = new ArrayAccessExpression(leftExpr, indexExpr, toAstLoc(startLoc, loc));
                        break;

                    case LPAREN:
                        skip(loc);

                        auto params = parseCompositeExpression(loc);

                        if(!condSkip!RPAREN(loc))
                            unexpected("`)`", loc);

                        leftExpr = new FunctionCallExpression(leftExpr, params, toAstLoc(startLoc, loc));
                        break;

                    case OP_DOT:
                        skip(loc);
                        _lexer.disableLookup();
                        auto id = parseIdentifier(loc);
                        _lexer.enableLookup();
                        leftExpr = new FieldAccessExpression(leftExpr, id, toAstLoc(startLoc, loc));
                        break;

                    case OP_ARROW:
                        skip(loc);
                        _lexer.disableLookup();
                        auto id = parseIdentifier(loc);
                        _lexer.enableLookup();
                        leftExpr = new IndirectFieldAccessExpression(leftExpr, id, toAstLoc(startLoc, loc));
                        break;

                    case OP_INC:
                        skip(loc);
                        leftExpr = new PostfixIncrementExpression(leftExpr, true, toAstLoc(startLoc, loc));
                        break;

                    case OP_DEC:
                        skip(loc);
                        leftExpr = new PostfixIncrementExpression(leftExpr, false, toAstLoc(startLoc, loc));
                        break;

                    default:
                        return leftExpr;
                }
            }
        }
    }

    Expression parsePrimaryExpression(ref ParserTokenLocation loc)
    {
        with(ParserTokenType)
        {
            auto startLoc = loc;
            auto token = currTok;

            switch(token.type)
            {
                case INTEGER:
                    auto val = token.value.get!ParserIntegerTokenValue;
                    skip(loc);
                    return new IntegerExpression(val.isUnsigned, val.isLong, val.content, toAstLoc(startLoc, loc));

                case IDENTIFIER:
                    auto id = parseIdentifier(loc);
                    return new IdentifierExpression(id, toAstLoc(startLoc, loc));

                case NUMBER:
                    auto val = token.value.get!ParserNumberTokenValue;
                    skip(loc);
                    return new NumberExpression(val.isDouble, val.content, toAstLoc(startLoc, loc));

                case STRING:
                    auto val = token.value.get!ParserStringTokenValue;
                    skip(loc);
                    return new StringExpression(val.isWide, val.content, toAstLoc(startLoc, loc));

                case CHARACTER:
                    auto val = token.value.get!ParserCharTokenValue;
                    skip(loc);
                    return new CharacterExpression(val.isWide, val.content, toAstLoc(startLoc, loc));

                case ENUM_VALUE:
                    auto enumValue = parseEnumValue(loc);
                    return new EnumExpression(enumValue, toAstLoc(startLoc, loc));

                case LPAREN:
                    skip(loc);
                    auto expr = parseCompositeExpression(loc);
                    if(!condSkip!RPAREN(loc))
                        unexpected("`)`", loc);
                    return expr;

                default:
                    break;
            }

            unexpected("primary expression", loc);
            assert(false);
        }
    }

    CompositeExpression parseCompositeExpression(ref ParserTokenLocation loc)
    {
        with(ParserTokenType)
        {
            auto startLoc = loc;
            auto expressions = appender!(Expression[])();

            do
                expressions ~= parseAssignmentExpression(loc);
            while(condSkip!COMMA(loc));

            // Must return an object CompositeExpression for other rules to 
            // work properly (such as for function calls and assignments)
            return new CompositeExpression(expressions.data, toAstLoc(startLoc, loc));
        }
    }

    Expression parseAssignmentExpression(ref ParserTokenLocation loc)
    {
        auto startLoc = loc;
        auto lhs = parseConditionalExpression(loc);

        // Solve the grammar conflict between conditional and unary expressions:
        // the type of lhs is probed at runtime in order to to know if 
        // an assignment operator should be parsed just after lhs.
        if(!matchAssignmentOperator(currTok)
                || cast(UnaryExpression)lhs is null
                && cast(PostfixExpression)lhs is null
                && cast(PrimaryExpression)lhs is null
                && cast(CompositeExpression)lhs is null)
            return lhs;

        auto op = parseAssignmentOperator(loc);
        auto rhs = parseAssignmentExpression(loc);
        return new AssignmentExpression(op, lhs, rhs, toAstLoc(startLoc, loc));
    }

    AssignmentOperator parseAssignmentOperator(ref ParserTokenLocation loc)
    {
        auto token = currTok;

        if(!matchAssignmentOperator(token))
            unexpected("assignment operator", loc);

        skip(loc);
        return convertEnum!(ParserTokenType, AssignmentOperator, "ASSIGN", "XOR_ASSIGN")(token.type);
    }

    UnaryOperator parseUnaryOperator(ref ParserTokenLocation loc)
    {
        with(ParserTokenType)
        {
            switch(currTok.type)
            {
                case OP_BAND: skip(loc); return UnaryOperator.INDIR;
                case OP_MUL: skip(loc); return UnaryOperator.DEREF;
                case OP_ADD: skip(loc); return UnaryOperator.ADD;
                case OP_SUB: skip(loc); return UnaryOperator.SUB;
                case OP_NOT: skip(loc); return UnaryOperator.NOT;
                case OP_BNOT: skip(loc); return UnaryOperator.BNOT;
                default: unexpected("unary operator", loc);
            }

            assert(false);
        }
    }

    Typename parseTypename(ref ParserTokenLocation loc)
    {
        with(ParserTokenType)
        {
            auto startLoc = loc;

            auto typeParts = parseSpecifierQualifiers(loc);
            AbstractDeclarator decl = null;

            if(matchAbstractDeclarator(currTok))
                decl = parseAbstractDeclarator(loc);

            return new Typename(typeParts, decl, toAstLoc(startLoc, loc));
        }
    }

    ParameterList parseParameterList(ref ParserTokenLocation loc)
    {
        with(ParserTokenType)
        {
            auto startLoc = loc;
            auto paramDecls = appender!(ParameterDeclaration[])();
            bool ellipsis = false;

            // Temporary short-lived scope for function parameter
            _lexer.beginScope();

            paramDecls ~= parseParameterDeclaration(loc);

            while(condSkip!COMMA(loc))
            {
                if(matchParameterDeclaration(currTok))
                    paramDecls ~= parseParameterDeclaration(loc);
                else if(condSkip!ELLIPSIS(loc))
                    ellipsis = true;
                else
                    unexpected("parameter declaration or `...`", loc);
            }

            _lexer.endScope();

            return new ParameterList(paramDecls.data, ellipsis, toAstLoc(startLoc, loc));
        }
    }

    ParameterDeclaration parseParameterDeclaration(ref ParserTokenLocation loc)
    {
        auto startLoc = loc;
        GenericDeclarator decl;

        auto declSpecs = parseDeclarationSpecifiers(loc);

        if(matchGenericDeclarator(currTok))
            decl = parseGenericDeclarator(loc);

        if(!decl.hasValue)
            return new AbstractParameterDeclaration(declSpecs, null, toAstLoc(startLoc, loc));
        else if(decl.peek!AbstractDeclarator !is null)
            return new AbstractParameterDeclaration(declSpecs, decl.get!AbstractDeclarator, toAstLoc(startLoc, loc));

        auto concDecl = decl.get!Declarator;
        registerDeclarator(concDecl, false);
        return new ConcreteParameterDeclaration(declSpecs, concDecl, toAstLoc(startLoc, loc));
    }

    GenericDeclarator parseGenericDeclarator(ref ParserTokenLocation loc)
    {
        auto startLoc = loc;
        Pointer pointer = null;
        GenericDirectDeclarator decl;

        if(matchPointer(currTok))
            pointer = parsePointer(loc);

        if(matchGenericDirectDeclarator(currTok))
            decl = parseGenericDirectDeclarator(loc);

        if(pointer is null && !decl.hasValue)
            unexpected("pointer or direct [abstract] declarator", loc);

        DirectAbstractDeclarator actualDecl = null;
        const bool isAbstract = !decl.hasValue || decl.peek!DirectAbstractDeclarator !is null;

        if(isAbstract)
        {
            if(decl.hasValue)
                actualDecl = decl.get!DirectAbstractDeclarator;

            auto res = new AbstractDeclarator(pointer, actualDecl, toAstLoc(startLoc, loc));
            return GenericDeclarator(res);
        }

        auto res = new Declarator(pointer, decl.get!DirectDeclarator, toAstLoc(startLoc, loc));
        return GenericDeclarator(res);
    }

    GenericDirectDeclarator parseGenericDirectDeclarator(ref ParserTokenLocation loc)
    {
        with(ParserTokenType)
        {
            _lexer.disableLookup();
            auto firstTokenType = currTok.type;
            _lexer.enableLookup();

            // Simple cases where existing rules can be reused
            // Note: Enumerators are allowed here since the override of an
            // enumerator will produce a clearer error later (symbol table)
            if(firstTokenType.among(IDENTIFIER, ENUM_VALUE))
                return GenericDirectDeclarator(parseDirectDeclarator(loc));
            else if(firstTokenType == LBRACK)
                return GenericDirectDeclarator(parseDirectAbstractDeclarator(loc));

            // Abiguous case: it is not possible to know here if we 
            // have to deal with a declarator or an abstractDeclarator.
            // So, both rules are parsed simultaneously using generic 
            // recursive rules until a discriminant token can be found.
            // The next tokens to parse can then be selected using type 
            // information retrieved from the callee (bottom-up diffusion).

            auto startLoc = loc;

            GenericDeclarator decl;
            ParameterList params;

            if(!condSkip!LPAREN(loc))
                unexpected("identifier or `[` or `(`", loc);

            if(matchGenericDeclarator(currTok))
                decl = parseGenericDeclarator(loc);
            else if(matchParameterList(currTok))
                params = parseParameterList(loc);

            if(!condSkip!RPAREN(loc))
                unexpected("`)`", loc);

            if(!decl.hasValue || decl.peek!AbstractDeclarator !is null)
            {
                DirectAbstractDeclaratorBase absDeclBase;

                if(decl.hasValue)
                    absDeclBase = decl.get!AbstractDeclarator;
                else
                    absDeclBase = new DirectAbstractDeclaratorParams(params, toAstLoc(startLoc, loc));

                auto declElems = parseDirectAbstractDeclaratorTail(loc);
                auto tmp = new DirectAbstractDeclarator(absDeclBase, declElems, toAstLoc(startLoc, loc));
                return GenericDirectDeclarator(tmp);
            }

            auto concDeclBase = decl.get!Declarator;
            auto declElems = parseDirectDeclaratorTail(loc);
            auto tmp = new DirectDeclarator(concDeclBase, declElems, toAstLoc(startLoc, loc));
            return GenericDirectDeclarator(tmp);
        }
    }

    AbstractDeclarator parseAbstractDeclarator(ref ParserTokenLocation loc)
    {
        auto startLoc = loc;
        Pointer pointer = null;
        DirectAbstractDeclarator decl = null;

        if(matchPointer(currTok))
            pointer = parsePointer(loc);

        if(matchDirectAbstractDeclarator(currTok))
            decl = parseDirectAbstractDeclarator(loc);

        if(pointer is null && decl is null)
            unexpected("pointer or direct abstract declarator", loc);

        return new AbstractDeclarator(pointer, decl, toAstLoc(startLoc, loc));
    }

    DirectAbstractDeclarator parseDirectAbstractDeclarator(ref ParserTokenLocation loc)
    {
        auto startLoc = loc;
        auto declBase = parseDirectAbstractDeclaratorHead(loc);
        auto declElems = parseDirectAbstractDeclaratorTail(loc);
        return new DirectAbstractDeclarator(declBase, declElems, toAstLoc(startLoc, loc));
    }

    DirectAbstractDeclaratorBase parseDirectAbstractDeclaratorHead(ref ParserTokenLocation loc)
    {
        with(ParserTokenType)
        {
            auto startLoc = loc;

            if(condSkip!LPAREN(loc))
            {
                AbstractDeclarator decl = null;
                ParameterList params;

                if(matchAbstractDeclarator(currTok))
                    decl = parseAbstractDeclarator(loc);
                else if(matchParameterList(currTok))
                    params = parseParameterList(loc);

                if(!condSkip!RPAREN(loc))
                    unexpected("`)`", loc);

                if(decl !is null)
                    return decl;

                return new DirectAbstractDeclaratorParams(params, toAstLoc(startLoc, loc));
            }
            else if(condSkip!LBRACK(loc))
            {
                Expression expr = parseConstantExpression(loc);

                if(!condSkip!RBRACK(loc))
                    unexpected("`]`", loc);

                return new DirectAbstractDeclaratorArray(expr, toAstLoc(startLoc, loc));
            }

            unexpected("`(` or `[`", loc);
            assert(false);
        }
    }

    DirectAbstractDeclaratorElement[] parseDirectAbstractDeclaratorTail(ref ParserTokenLocation loc)
    {
        with(ParserTokenType)
        {
            auto startLoc = loc;
            auto declElems = appender!(DirectAbstractDeclaratorElement[]);

            while(currTok.type.among(LBRACK, LPAREN))
            {
                auto startSubLoc = loc;

                if(condSkip!LPAREN(loc))
                {
                    ParameterList params = null;

                    if(matchParameterList(currTok))
                        params = parseParameterList(loc);

                    if(!condSkip!RPAREN(loc))
                        unexpected("`)`", loc);

                    declElems ~= new DirectAbstractDeclaratorParams(params, toAstLoc(startSubLoc, loc));
                }
                else if(condSkip!LBRACK(loc))
                {
                    Expression expr = null;

                    if(matchConstantExpression(currTok))
                        expr = parseConstantExpression(loc);

                    if(!condSkip!RBRACK(loc))
                        unexpected("`]`", loc);

                    declElems ~= new DirectAbstractDeclaratorArray(expr, toAstLoc(startSubLoc, loc));
                }
            }

            return declElems.data;
        }
    }

    EnumTypeSpecifier parseEnumSpecifier(ref ParserTokenLocation loc)
    {
        with(ParserTokenType)
        {
            auto startLoc = loc;
            Identifier id = null;
            auto enums = appender!(Enumerator[])();

            if(!condSkip!ENUM(loc))
                unexpected("enum", loc);

            _lexer.disableLookup();

            if(currTok.type == IDENTIFIER)
                id = parseIdentifier(loc);

            _lexer.enableLookup();

            if(condSkip!LCURL(loc))
            {
                do
                {
                    auto enumValue = parseEnumerator(loc);
                    registerEnumerator(enumValue);
                    enums ~= enumValue;
                }
                while(condSkip!COMMA(loc));

                if(!condSkip!RCURL(loc))
                    unexpected("`}`", loc);
            }

            if(id is null && enums.data.empty)
                unexpected("identifier or enum body", loc);

            return new EnumTypeSpecifier(id, enums.data, toAstLoc(startLoc, loc));
        }
    }

    Enumerator parseEnumerator(ref ParserTokenLocation loc)
    {
        auto startLoc = loc;
        Expression expr = null;

        _lexer.disableLookup();
        auto id = parseIdentifier(loc);
        _lexer.enableLookup();

        with(ParserTokenType)
            if(condSkip!ASSIGN(loc))
                expr = parseConstantExpression(loc);

        return new Enumerator(id, expr, toAstLoc(startLoc, loc));
    }

    Declaration parseDeclaration(ref ParserTokenLocation loc)
    {
        with(ParserTokenType)
        {
            auto startLoc = loc;
            auto initDecls = appender!(InitDeclarator[])();

            auto declSpecs = parseDeclarationSpecifiers(loc);
            const bool isTypedefDecl = hasTypedef(declSpecs);

            if(matchInitDeclarator(currTok))
            {
                do
                {
                    auto decl = parseInitDeclarator(loc);
                    registerDeclarator(decl.declarator, isTypedefDecl);
                    initDecls ~= decl;
                }
                while(condSkip!COMMA(loc));
            }

            if(!condSkip!SEMICOLON(loc))
                unexpected("`;`", loc);

            return new Declaration(declSpecs, initDecls.data, toAstLoc(startLoc, loc));
        }
    }

    InitDeclarator parseInitDeclarator(ref ParserTokenLocation loc)
    {
        auto startLoc = loc;
        auto declarator = parseDeclarator(loc);
        Initializer initializer = null;

        with(ParserTokenType)
            if(condSkip!ASSIGN(loc))
                initializer = parseInitializer(loc);

        return new InitDeclarator(declarator, initializer, toAstLoc(startLoc, loc));
    }

    Initializer parseInitializer(ref ParserTokenLocation loc)
    {
        auto startLoc = loc;

        if(matchAssignmentExpression(currTok))
            return new BasicInitializer(parseAssignmentExpression(loc), toAstLoc(startLoc, loc));

        if(matchInitializerList(currTok))
            return parseInitializerList(loc);

        unexpected("initializer", loc);
        assert(false);
    }

    InitializerList parseInitializerList(ref ParserTokenLocation loc)
    {
        with(ParserTokenType)
        {
            auto startLoc = loc;
            auto initializers = appender!(Initializer[])();

            if(!condSkip!LCURL(loc))
                unexpected("`{`", loc);

            do
                initializers ~= parseInitializer(loc);
            while(condSkip!COMMA(loc) && matchInitializer(currTok));

            if(!condSkip!RCURL(loc))
                unexpected("`}`", loc);

            return new InitializerList(initializers.data, toAstLoc(startLoc, loc));
        }
    }

    Statement parseCompoundStatement(ref ParserTokenLocation loc, bool withScope = true)
    {
        with(ParserTokenType)
        {
            auto startLoc = loc;
            auto declarations = appender!(Declaration[])();
            auto statements = appender!(Statement[])();

            if(!condSkip!LCURL(loc))
                unexpected("`{`", loc);

            if(withScope)
                _lexer.beginScope();

            while(matchDeclaration(currTok))
                declarations ~= parseDeclaration(loc);

            while(matchStatement(currTok))
                statements ~= parseStatement(loc);

            if(withScope)
                _lexer.endScope();

            if(!condSkip!RCURL(loc))
            {
                if(matchDeclaration(currTok))
                    fail("unexpected declaration after a statement", loc);
                else
                    unexpected("statement or `}`", loc);
            }

            return new CompoundStatement(declarations.data, statements.data, toAstLoc(startLoc, loc));
        }
    }

    Statement parseStatement(ref ParserTokenLocation loc)
    {
        with(ParserTokenType)
        {
            _lexer.disableLookup();
            auto firstTokenType = currTok.type;
            _lexer.enableLookup();

            // Lookahead needed to solve the conflict between labeledStatement
            // and expressionStatement on the IDENTIFIER token.
            if(firstTokenType == IDENTIFIER && nextTok.type == COL)
                return parseLabeledStatement(loc);
            else if(matchExpressionStatement(currTok))
                return parseExpressionStatement(loc);
            else if(matchLabeledStatement(currTok) && firstTokenType != IDENTIFIER)
                return parseLabeledStatement(loc);
            else if(matchCompoundStatement(currTok))
                return parseCompoundStatement(loc);
            else if(matchSelectionStatement(currTok))
                return parseSelectionStatement(loc);
            else if(matchIterationStatement(currTok))
                return parseIterationStatement(loc);
            else if(matchJumpStatement(currTok))
                return parseJumpStatement(loc);

            unexpected("statement", loc);
            assert(false);
        }
    }

    Statement parseLabeledStatement(ref ParserTokenLocation loc)
    {
        with(ParserTokenType)
        {
            auto startLoc = loc;
            _lexer.disableLookup();
            auto firstTokenType = currTok.type;
            _lexer.enableLookup();

            if(firstTokenType == IDENTIFIER)
            {
                _lexer.disableLookup();
                auto id = parseIdentifier(loc);
                _lexer.enableLookup();

                if(!condSkip!COL(loc))
                    unexpected("`:`", loc);

                auto statement = parseStatement(loc);
                return new LabelStatement(id, statement, toAstLoc(startLoc, loc));
            }
            else if(condSkip!CASE(loc))
            {
                auto expr = parseConstantExpression(loc);

                if(!condSkip!COL(loc))
                    unexpected("`:`", loc);

                auto statement = parseStatement(loc);
                return new CaseStatement(expr, statement, toAstLoc(startLoc, loc));
            }
            else if(condSkip!DEFAULT(loc))
            {
                if(!condSkip!COL(loc))
                    unexpected("`:`", loc);

                auto statement = parseStatement(loc);
                return new DefaultStatement(statement, toAstLoc(startLoc, loc));
            }

            unexpected("label statement", loc);
            assert(false);
        }
    }

    Statement parseExpressionStatement(ref ParserTokenLocation loc)
    {
        auto startLoc = loc;
        Expression expr = null;

        if(matchCompositeExpression(currTok))
            expr = parseCompositeExpression(loc);

        with(ParserTokenType)
            if(!condSkip!SEMICOLON(loc))
                unexpected("`;`", loc);

        return new ExpressionStatement(expr, toAstLoc(startLoc, loc));
    }

    Statement parseSelectionStatement(ref ParserTokenLocation loc)
    {
        with(ParserTokenType)
        {
            auto startLoc = loc;

            if(condSkip!IF(loc))
            {
                Statement elseStatement = null;

                if(!condSkip!LPAREN(loc))
                    unexpected("`(`", loc);

                auto expr = parseCompositeExpression(loc);

                if(!condSkip!RPAREN(loc))
                    unexpected("`)`", loc);

                auto ifStatement = parseStatement(loc);

                if(condSkip!ELSE(loc))
                    elseStatement = parseStatement(loc);

                return new IfStatement(expr, ifStatement, elseStatement, toAstLoc(startLoc, loc));
            }
            else if(condSkip!SWITCH(loc))
            {
                if(!condSkip!LPAREN(loc))
                    unexpected("`(`", loc);

                auto expr = parseCompositeExpression(loc);

                if(!condSkip!RPAREN(loc))
                    unexpected("`)`", loc);

                auto statement = parseStatement(loc);
                return new SwitchStatement(expr, statement, toAstLoc(startLoc, loc));
            }

            unexpected("selection statement", loc);
            assert(false);
        }
    }

    Statement parseIterationStatement(ref ParserTokenLocation loc)
    {
        with(ParserTokenType)
        {
            auto startLoc = loc;

            if(condSkip!WHILE(loc))
            {
                if(!condSkip!LPAREN(loc))
                    unexpected("`(`", loc);

                auto expr = parseCompositeExpression(loc);

                if(!condSkip!RPAREN(loc))
                    unexpected("`)`", loc);

                auto statement = parseStatement(loc);
                return new WhileStatement(expr, statement, toAstLoc(startLoc, loc));
            }
            else if(condSkip!DO(loc))
            {
                auto statement = parseStatement(loc);

                if(!condSkip!WHILE(loc))
                    unexpected("`while`", loc);

                if(!condSkip!LPAREN(loc))
                    unexpected("`(`", loc);

                auto expr = parseCompositeExpression(loc);

                if(!condSkip!RPAREN(loc))
                    unexpected("`)`", loc);

                if(!condSkip!SEMICOLON(loc))
                    unexpected("`;`", loc);

                return new DoStatement(expr, statement, toAstLoc(startLoc, loc));
            }
            else if(condSkip!FOR(loc))
            {
                if(!condSkip!LPAREN(loc))
                    unexpected("`(`", loc);

                Expression initExpr = null;
                Expression condExpr = null;
                Expression iterExpr = null;

                if(matchCompositeExpression(currTok))
                    initExpr = parseCompositeExpression(loc);

                if(!condSkip!SEMICOLON(loc))
                    unexpected("`;`", loc);

                if(matchCompositeExpression(currTok))
                    condExpr = parseCompositeExpression(loc);

                if(!condSkip!SEMICOLON(loc))
                    unexpected("`;`", loc);

                if(matchCompositeExpression(currTok))
                    iterExpr = parseCompositeExpression(loc);

                if(!condSkip!RPAREN(loc))
                    unexpected("`)`", loc);

                auto statement = parseStatement(loc);
                return new ForStatement(initExpr, condExpr, iterExpr, statement, toAstLoc(startLoc, loc));
            }

            unexpected("iteration statement", loc);
            assert(false);
        }
    }

    Statement parseJumpStatement(ref ParserTokenLocation loc)
    {
        with(ParserTokenType)
        {
            auto startLoc = loc;

            if(condSkip!GOTO(loc))
            {
                _lexer.disableLookup();
                auto id = parseIdentifier(loc);
                _lexer.enableLookup();

                if(!condSkip!SEMICOLON(loc))
                    unexpected("`;`", loc);

                return new GotoStatement(id, toAstLoc(startLoc, loc));
            }
            else if(condSkip!CONTINUE(loc))
            {
                if(!condSkip!SEMICOLON(loc))
                    unexpected("`;`", loc);

                return new ContinueStatement(toAstLoc(startLoc, loc));
            }
            else if(condSkip!BREAK(loc))
            {
                if(!condSkip!SEMICOLON(loc))
                    unexpected("`;`", loc);

                return new BreakStatement(toAstLoc(startLoc, loc));
            }
            else if(condSkip!RETURN(loc))
            {
                Expression expr = null;

                if(matchCompositeExpression(currTok))
                    expr = parseCompositeExpression(loc);

                if(!condSkip!SEMICOLON(loc))
                    unexpected("`;`", loc);

                return new ReturnStatement(expr, toAstLoc(startLoc, loc));
            }

            unexpected("jump statement", loc);
            assert(false);
        }
    }

    Identifier parseIdentifier(ref ParserTokenLocation loc)
    {
        auto startLoc = loc;

        with(ParserTokenType)
            if(currTok.type != IDENTIFIER)
                unexpected("identifier", loc);

        auto name = currTok.value.get!ParserIdentifierTokenValue.name;
        skip(loc);
        return new Identifier(name, toAstLoc(startLoc, loc));
    }

    EnumValue parseEnumValue(ref ParserTokenLocation loc)
    {
        auto startLoc = loc;

        with(ParserTokenType)
            if(currTok.type != ENUM_VALUE)
                unexpected("identifier", loc);

        auto name = currTok.value.get!ParserIdentifierTokenValue.name;
        skip(loc);
        return new EnumValue(name, toAstLoc(startLoc, loc));
    }

    UserTypeSpecifier parseUserTypeSpecifier(ref ParserTokenLocation loc)
    {
        auto startLoc = loc;

        with(ParserTokenType)
            if(currTok.type != TYPE_NAME)
                unexpected("user-defined type", loc);

        auto name = currTok.value.get!ParserIdentifierTokenValue.name;
        skip(loc);
        return new UserTypeSpecifier(name, toAstLoc(startLoc, loc));
    }
}

