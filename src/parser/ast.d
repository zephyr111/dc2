/* Copyright (c) 2018 <Jérôme Richard>
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

module parser.ast;

import std.typecons;
import interfaces;
import parser.astBase;
import utils;


    // Base classes

struct AstNodeLocation
{
    string filename;
    uint line;
    uint col;
    ulong pos;
    ulong length;
}

// Base class for all AST node
abstract class AstNode
{
    AstNodeLocation location;

    this(AstNodeLocation loc)
    {
        location = loc;
    }

    void accept(AstVisitor visitor);
}


    // Base interface to derive AST traversal classes

interface AstVisitor
{
    mixin(genAstVisitorInterface());
}

// All following classes can be visited
@visited:


    // TranslationUnit, Definitions & Declarations

final class TranslationUnit : AstNode
{
    ExternalDeclaration[] declarations;
    mixin(genAstNodeContent!(typeof(this)));
}

interface ExternalDeclaration {}

final class FunctionDefinition : AstNode, ExternalDeclaration
{
    DeclarationSpecifier[] specifiers;
    Declarator declarator;
    Declaration[] args;
    Statement content;
    mixin(genAstNodeContent!(typeof(this)));
}

interface DeclarationSpecifier {}

enum StorageClassSpecifierEnum
{
    AUTO, REGISTER, STATIC, EXTERN, TYPEDEF
}

final class StorageClassSpecifier : AstNode, DeclarationSpecifier
{
    StorageClassSpecifierEnum value;
    mixin(genAstNodeContent!(typeof(this)));
}

interface TypeSpecifier : DeclarationSpecifier, SpecifierQualifier {}

enum PrimitiveTypeSpecifierEnum
{
    VOID, CHAR, SHORT, INT, LONG, FLOAT, DOUBLE, SIGNED, UNSIGNED
}

// For primitive types
final class PrimitiveTypeSpecifier : AstNode, TypeSpecifier
{
    PrimitiveTypeSpecifierEnum value;
    mixin(genAstNodeContent!(typeof(this)));
}

final class StructDeclarator : AstNode
{
    // Note: one of the two is not null
    Declarator declarator; // can be null
    Expression defaultValue; // can be null
    mixin(genAstNodeContent!(typeof(this)));
}

interface SpecifierQualifier {}

final class StructDeclaration : AstNode
{
    SpecifierQualifier[] typeParts;
    StructDeclarator[] declarators;
    mixin(genAstNodeContent!(typeof(this)));
}

// For structs and unions
final class AggregateTypeSpecifier : AstNode, TypeSpecifier
{
    bool isUnion;
    Identifier name; // can be null
    StructDeclaration[] fields;
    mixin(genAstNodeContent!(typeof(this)));
}

final class Enumerator : AstNode
{
    Identifier name;
    Expression value;
    mixin(genAstNodeContent!(typeof(this)));
}

// For enums
final class EnumTypeSpecifier : AstNode, TypeSpecifier
{
    Identifier name; // can be null
    Enumerator[] fields;
    mixin(genAstNodeContent!(typeof(this)));
}

// For user defined types (defined with a typedef)
final class UserTypeSpecifier : AstNode, TypeSpecifier
{
    string name;
    mixin(genAstNodeContent!(typeof(this)));
}

enum TypeQualifierEnum
{
    CONST, VOLATILE
}

pragma(msg, "[OPTIM] Use a bitset (faster)");
final class TypeQualifier : AstNode, DeclarationSpecifier, SpecifierQualifier
{
    TypeQualifierEnum value;
    mixin(genAstNodeContent!(typeof(this)));
}

final class Pointer : AstNode
{
    TypeQualifier[] qualifiers;
    Pointer nextPointer; // can be null, contain the left-side pointer
    mixin(genAstNodeContent!(typeof(this)));
}

final class DirectDeclarator : AstNode
{
    DirectDeclaratorBase prefix;
    DirectDeclaratorElement[] elements;
    mixin(genAstNodeContent!(typeof(this)));
}

interface DirectDeclaratorBase {}

pragma(msg, "[FIXME] use direct inheritence in Identifier or derive DirectDeclarator in two");
final class DirectDeclaratorIdentifier : AstNode, DirectDeclaratorBase
{
    Identifier identifier;
    mixin(genAstNodeContent!(typeof(this)));
}

final class DirectAbstractDeclarator : AstNode
{
    DirectAbstractDeclaratorBase base;
    DirectAbstractDeclaratorElement[] elements;
    mixin(genAstNodeContent!(typeof(this)));
}

interface DirectAbstractDeclaratorBase {}

final class ParameterList : AstNode
{
    ParameterDeclaration[] args;
    bool withEllipsis;
    mixin(genAstNodeContent!(typeof(this)));
}

final class DirectAbstractDeclaratorParams : AstNode, DirectAbstractDeclaratorBase, DirectAbstractDeclaratorElement
{
    pragma(msg, "[FIXME] null or empty? => fix the parser if needed!");
    ParameterList list;
    mixin(genAstNodeContent!(typeof(this)));
}

final class DirectAbstractDeclaratorArray : AstNode, DirectAbstractDeclaratorBase, DirectAbstractDeclaratorElement
{
    Expression index;
    pragma(msg, "[FIXME] to be continued (use direct ineritance?)");
    mixin(genAstNodeContent!(typeof(this)));
}

interface DirectAbstractDeclaratorElement {}

final class AbstractDeclarator : AstNode, DirectAbstractDeclaratorBase
{
    // Note: one of the two is not null
    Pointer pointer; // can be null
    DirectAbstractDeclarator declarator; // can be null
    mixin(genAstNodeContent!(typeof(this)));
}

interface ParameterDeclaration {}

final class ConcreteParameterDeclaration : AstNode, ParameterDeclaration
{
    DeclarationSpecifier[] specifiers;
    Declarator declarator;
    mixin(genAstNodeContent!(typeof(this)));
}

final class AbstractParameterDeclaration : AstNode, ParameterDeclaration
{
    DeclarationSpecifier[] specifiers;
    AbstractDeclarator declarator;
    mixin(genAstNodeContent!(typeof(this)));
}

interface DirectDeclaratorElement {}

final class DirectDeclaratorArray : AstNode, DirectDeclaratorElement
{
    Expression index; // can be null
    mixin(genAstNodeContent!(typeof(this)));
}

pragma(msg, "[FIXME] find a better name");
final class DirectDeclaratorTypedParams : AstNode, DirectDeclaratorElement
{
    ParameterList args;
    mixin(genAstNodeContent!(typeof(this)));
}

pragma(msg, "[FIXME] find a better name");
final class DirectDeclaratorUntypedParams : AstNode, DirectDeclaratorElement
{
    Identifier[] args;
    mixin(genAstNodeContent!(typeof(this)));
}

final class Declarator : AstNode, DirectDeclaratorBase
{
    Pointer pointer; // can be null
    DirectDeclarator declarator;
    mixin(genAstNodeContent!(typeof(this)));
}

interface Initializer {}

final class BasicInitializer : AstNode, Initializer
{
    Expression expr;
    mixin(genAstNodeContent!(typeof(this)));
}

final class InitializerList : AstNode, Initializer
{
    Initializer[] initializers;
    mixin(genAstNodeContent!(typeof(this)));
}

final class InitDeclarator : AstNode
{
    Declarator declarator;
    Initializer value; // can be null
    mixin(genAstNodeContent!(typeof(this)));
}

final class Declaration : AstNode, ExternalDeclaration
{
    DeclarationSpecifier[] specifiers;
    InitDeclarator[] initDeclarators;
    mixin(genAstNodeContent!(typeof(this)));
}

final class Typename : AstNode
{
    SpecifierQualifier[] typeParts;
    AbstractDeclarator declarator; // can be null
    mixin(genAstNodeContent!(typeof(this)));
}


    // Expressions

enum BinaryOperator
{
    INC, DEC, ADD, SUB, 
    MUL, DIV, MOD, LSHIFT, RSHIFT, 
    AND, OR, LE, LT, GE, GT,
    EQ, NE, BAND, BOR, BXOR
}

enum AssignmentOperator
{
    ASSIGN, ADD_ASSIGN, SUB_ASSIGN, 
    MUL_ASSIGN, DIV_ASSIGN, MOD_ASSIGN,
    LSHIFT_ASSIGN, RSHIFT_ASSIGN,
    AND_ASSIGN, OR_ASSIGN, XOR_ASSIGN
}

enum UnaryOperator
{
    INDIR, DEREF, ADD, SUB, NOT, BNOT
}


interface Expression {}


final class CompositeExpression : AstNode, Expression
{
    Expression[] content;
    mixin(genAstNodeContent!(typeof(this)));
}


final class AssignmentExpression : AstNode, Expression
{
    AssignmentOperator op;
    Expression left;
    Expression right; // can be null
    mixin(genAstNodeContent!(typeof(this)));
}


final class ConditionalExpression : AstNode, Expression
{
    Expression condition;
    Expression ifTrue;
    Expression ifFalse;
    mixin(genAstNodeContent!(typeof(this)));
}


final class BinaryExpression : AstNode, Expression
{
    BinaryOperator op;
    Expression left;
    Expression right;
    mixin(genAstNodeContent!(typeof(this)));
}


final class CastExpression : AstNode, Expression
{
    Typename type;
    Expression expr;
    mixin(genAstNodeContent!(typeof(this)));
}


interface UnaryExpression : Expression {}

final class PrefixIncrementExpression : AstNode, UnaryExpression
{
    Expression expr;
    bool isIncremented;
    mixin(genAstNodeContent!(typeof(this)));
}

final class BasicUnaryExpression : AstNode, UnaryExpression
{
    UnaryOperator op;
    Expression expr;
    mixin(genAstNodeContent!(typeof(this)));
}

interface SizeofExpression : UnaryExpression {}

// Typename-based sizeof
final class SimpleSizeofExpression : AstNode, SizeofExpression
{
    Typename type;
    mixin(genAstNodeContent!(typeof(this)));
}

// Expression-based sizeof
final class ComplexSizeofExpression : AstNode, SizeofExpression
{
    Expression expr;
    mixin(genAstNodeContent!(typeof(this)));
}


interface PostfixExpression : Expression {}

final class ArrayAccessExpression : AstNode, PostfixExpression
{
    Expression expr;
    Expression indices;
    mixin(genAstNodeContent!(typeof(this)));
}

final class FunctionCallExpression : AstNode, PostfixExpression
{
    Expression func;
    CompositeExpression args;
    mixin(genAstNodeContent!(typeof(this)));
}

final class FieldAccessExpression : AstNode, PostfixExpression
{
    Expression expr;
    Identifier field;
    mixin(genAstNodeContent!(typeof(this)));
}

final class IndirectFieldAccessExpression : AstNode, PostfixExpression
{
    Expression expr;
    Identifier field;
    mixin(genAstNodeContent!(typeof(this)));
}

final class PostfixIncrementExpression : AstNode, PostfixExpression
{
    Expression expr;
    bool isIncremented;
    mixin(genAstNodeContent!(typeof(this)));
}


interface PrimaryExpression : Expression {}

final class IdentifierExpression : AstNode, PrimaryExpression
{
    Identifier name;
    mixin(genAstNodeContent!(typeof(this)));
}

final class EnumExpression : AstNode, PrimaryExpression
{
    EnumValue name;
    mixin(genAstNodeContent!(typeof(this)));
}

final class IntegerExpression : AstNode, PrimaryExpression
{
    bool isUnsigned;
    bool isLong;
    long content;
    mixin(genAstNodeContent!(typeof(this)));
}

final class NumberExpression : AstNode, PrimaryExpression
{
    bool isDouble;
    double content;
    mixin(genAstNodeContent!(typeof(this)));
}

final class CharacterExpression : AstNode, PrimaryExpression
{
    bool isWide;
    dchar content;
    mixin(genAstNodeContent!(typeof(this)));
}

final class StringExpression : AstNode, PrimaryExpression
{
    bool isWide;
    string content;
    mixin(genAstNodeContent!(typeof(this)));
}

    // Special

final class Identifier : AstNode
{
    string name;
    mixin(genAstNodeContent!(typeof(this)));
}

final class EnumValue : AstNode
{
    string name;
    mixin(genAstNodeContent!(typeof(this)));
}


    // Statements

interface Statement {}

final class CompoundStatement : AstNode, Statement
{
    Declaration[] declarations;
    Statement[] statements;
    mixin(genAstNodeContent!(typeof(this)));
}

final class LabelStatement : AstNode, Statement
{
    Identifier label;
    Statement content;
    mixin(genAstNodeContent!(typeof(this)));
}

final class CaseStatement : AstNode, Statement
{
    Expression value;
    Statement content;
    mixin(genAstNodeContent!(typeof(this)));
}

final class DefaultStatement : AstNode, Statement
{
    Statement content;
    mixin(genAstNodeContent!(typeof(this)));
}

final class ExpressionStatement : AstNode, Statement
{
    Expression content;
    mixin(genAstNodeContent!(typeof(this)));
}

final class IfStatement : AstNode, Statement
{
    Expression condition;
    Statement ifContent;
    Statement elseContent;
    mixin(genAstNodeContent!(typeof(this)));
}

final class SwitchStatement : AstNode, Statement
{
    Expression value;
    Statement content;
    mixin(genAstNodeContent!(typeof(this)));
}

final class ForStatement : AstNode, Statement
{
    Expression initialization; // can be null
    Expression condition; // can be null
    Expression iteration; // can be null
    Statement content;
    mixin(genAstNodeContent!(typeof(this)));
}

final class DoStatement : AstNode, Statement
{
    Expression condition;
    Statement content;
    mixin(genAstNodeContent!(typeof(this)));
}

final class WhileStatement : AstNode, Statement
{
    Expression condition;
    Statement content;
    mixin(genAstNodeContent!(typeof(this)));
}

final class GotoStatement : AstNode, Statement
{
    Identifier label;
    mixin(genAstNodeContent!(typeof(this)));
}

final class ContinueStatement : AstNode, Statement
{
    // No sub-elements
    mixin(genAstNodeContent!(typeof(this)));
}

final class BreakStatement : AstNode, Statement
{
    // No sub-elements
    mixin(genAstNodeContent!(typeof(this)));
}

final class ReturnStatement : AstNode, Statement
{
    Expression value;
    mixin(genAstNodeContent!(typeof(this)));
}

