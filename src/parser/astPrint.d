/* Copyright (c) 2018 <Jérôme Richard>
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

module parser.astPrint;

import std.stdio;
import std.traits;
import std.array;
import std.algorithm.iteration;
import std.format;
import interfaces;
import parser.ast;
import parser.astBase;
import utils;


final class AstDotPrinter : AstVisitor
{
    int lastChildId;
    int guid = 0;

    void computeChild(T)(int parentId, int fieldId, T child)
    {
        auto base = cast(AstNode)child;

        // Check child is a node since it can be any field of an AST node
        if(base !is null)
        {
            auto oldLastChild = lastChildId;
            base.accept(this);
            assert(lastChildId != oldLastChild);

            auto childId = lastChildId;
            writeln(format!`    %d:%d -> %d;`(parentId, fieldId, childId));
        }
    }

    void mkNode(AstNodeType)(AstNodeType node)
    {
        auto childrenText = appender!(string[]);
        enum fieldNames = FieldNameTuple!AstNodeType;
        auto fields = node.tupleof;

        assert(fieldNames.length == fields.length);

        // Create the current node
        static foreach(int i ; 0..fieldNames.length)
        {{
            alias fieldType = typeof(fields[i]);

            static if(isArray!fieldType)
                alias childType = ForeachType!fieldType;
            else
                alias childType = fieldType;

            static if(isVisitedAstNodeType!childType)
            {
                auto childName = fieldNames[i];
                childrenText ~= format!`<%d> %s`(i, childName);
            }
        }}

        auto nodeId = guid++;
        string astNodeType = AstNodeType.stringof;
        auto childrenContent = childrenText.data.joiner(` | `);
        string nodeName = astNodeType;

        with(EscapeType)
        {
            static if(is(AstNodeType == Identifier))
                nodeName = format!`%s: %s`(astNodeType, node.name);
            else static if(is(AstNodeType == EnumValue))
                nodeName = format!`%s: %s`(astNodeType, node.name);
            else static if(is(AstNodeType == IntegerExpression))
                nodeName = format!`%s: %d`(astNodeType, node.content);
            else static if(is(AstNodeType == NumberExpression))
                nodeName = format!`%s: %f`(astNodeType, node.content);
            else static if(is(AstNodeType == CharacterExpression))
                nodeName = format!`%s: '%s'`(astNodeType, node.content.escapeChar!ONLY_SQUOTES);
            else static if(is(AstNodeType == StringExpression))
                nodeName = format!`%s: "%s"`(astNodeType, node.content.escape!ONLY_DQUOTES);
            else static if(is(AstNodeType == BinaryExpression))
                nodeName = format!`%s: %s`(astNodeType, node.op);
            else static if(is(AstNodeType == BasicUnaryExpression))
                nodeName = format!`%s: %s`(astNodeType, node.op);
            else static if(is(AstNodeType == AssignmentExpression))
                nodeName = format!`%s: %s`(astNodeType, node.op);
            else static if(is(AstNodeType == PrefixIncrementExpression))
                nodeName = format!`%s: %s`(astNodeType, node.isIncremented ? "++" : "--");
            else static if(is(AstNodeType == PostfixIncrementExpression))
                nodeName = format!`%s: %s`(astNodeType, node.isIncremented ? "++" : "--");
            else static if(is(AstNodeType == PrimitiveTypeSpecifier))
                nodeName = format!`%s: %s`(astNodeType, node.value);
            else static if(is(AstNodeType == StorageClassSpecifier))
                nodeName = format!`%s: %s`(astNodeType, node.value);
            else static if(is(AstNodeType == TypeQualifier))
                nodeName = format!`%s: %s`(astNodeType, node.value);
        }

        if(!childrenContent.empty)
            writeln(format!`    %d [label="{%s | {%s}}"]`(nodeId, nodeName, childrenContent));
        else
            writeln(format!`    %d [label="{%s}"]`(nodeId, nodeName));

        // Generate and connect child nodes
        static foreach(int i ; 0..fieldNames.length)
        {{
            auto field = fields[i];
            auto fieldId = i;
            alias fieldType = typeof(field);

            static if(isArray!fieldType)
            {
                static if(isVisitedAstNodeType!(ForeachType!fieldType))
                    foreach(fieldElem ; field)
                        computeChild(nodeId, fieldId, fieldElem);
            }
            else
            {
                static if(isVisitedAstNodeType!fieldType)
                    computeChild(nodeId, fieldId, field);
            }
        }}

        lastChildId = nodeId;
    }

    override void visit(TranslationUnit node) { mkNode(node); }
    override void visit(FunctionDefinition node) { mkNode(node); }
    override void visit(StorageClassSpecifier node) { mkNode(node); }
    override void visit(PrimitiveTypeSpecifier node) { mkNode(node); }
    override void visit(StructDeclarator node) { mkNode(node); }
    override void visit(StructDeclaration node) { mkNode(node); }
    override void visit(AggregateTypeSpecifier node) { mkNode(node); }
    override void visit(Enumerator node) { mkNode(node); }
    override void visit(EnumTypeSpecifier node) { mkNode(node); }
    override void visit(UserTypeSpecifier node) { mkNode(node); }
    override void visit(TypeQualifier node) { mkNode(node); }
    override void visit(Pointer node) { mkNode(node); }
    override void visit(DirectDeclarator node) { mkNode(node); }
    override void visit(DirectDeclaratorIdentifier node) { mkNode(node); }
    override void visit(DirectAbstractDeclarator node) { mkNode(node); }
    override void visit(ParameterList node) { mkNode(node); }
    override void visit(DirectAbstractDeclaratorParams node) { mkNode(node); }
    override void visit(DirectAbstractDeclaratorArray node) { mkNode(node); }
    override void visit(AbstractDeclarator node) { mkNode(node); }
    override void visit(ConcreteParameterDeclaration node) { mkNode(node); }
    override void visit(AbstractParameterDeclaration node) { mkNode(node); }
    override void visit(DirectDeclaratorArray node) { mkNode(node); }
    override void visit(DirectDeclaratorTypedParams node) { mkNode(node); }
    override void visit(DirectDeclaratorUntypedParams node) { mkNode(node); }
    override void visit(Declarator node) { mkNode(node); }
    override void visit(BasicInitializer node) { mkNode(node); }
    override void visit(InitializerList node) { mkNode(node); }
    override void visit(InitDeclarator node) { mkNode(node); }
    override void visit(Declaration node) { mkNode(node); }
    override void visit(Typename node) { mkNode(node); }
    override void visit(CompositeExpression node) { mkNode(node); }
    override void visit(AssignmentExpression node) { mkNode(node); }
    override void visit(ConditionalExpression node) { mkNode(node); }
    override void visit(BinaryExpression node) { mkNode(node); }
    override void visit(CastExpression node) { mkNode(node); }
    override void visit(PrefixIncrementExpression node) { mkNode(node); }
    override void visit(BasicUnaryExpression node) { mkNode(node); }
    override void visit(SimpleSizeofExpression node) { mkNode(node); }
    override void visit(ComplexSizeofExpression node) { mkNode(node); }
    override void visit(ArrayAccessExpression node) { mkNode(node); }
    override void visit(FunctionCallExpression node) { mkNode(node); }
    override void visit(FieldAccessExpression node) { mkNode(node); }
    override void visit(IndirectFieldAccessExpression node) { mkNode(node); }
    override void visit(PostfixIncrementExpression node) { mkNode(node); }
    override void visit(IdentifierExpression node) { mkNode(node); }
    override void visit(EnumExpression node) { mkNode(node); }
    override void visit(IntegerExpression node) { mkNode(node); }
    override void visit(NumberExpression node) { mkNode(node); }
    override void visit(CharacterExpression node) { mkNode(node); }
    override void visit(StringExpression node) { mkNode(node); }
    override void visit(Identifier node) { mkNode(node); }
    override void visit(EnumValue node) { mkNode(node); }
    override void visit(CompoundStatement node) { mkNode(node); }
    override void visit(LabelStatement node) { mkNode(node); }
    override void visit(CaseStatement node) { mkNode(node); }
    override void visit(DefaultStatement node) { mkNode(node); }
    override void visit(ExpressionStatement node) { mkNode(node); }
    override void visit(IfStatement node) { mkNode(node); }
    override void visit(SwitchStatement node) { mkNode(node); }
    override void visit(ForStatement node) { mkNode(node); }
    override void visit(DoStatement node) { mkNode(node); }
    override void visit(WhileStatement node) { mkNode(node); }
    override void visit(GotoStatement node) { mkNode(node); }
    override void visit(ContinueStatement node) { mkNode(node); }
    override void visit(BreakStatement node) { mkNode(node); }
    override void visit(ReturnStatement node) { mkNode(node); }
}

void printAsDot(AstNode ast)
{
    writeln(`digraph ast {`);
    writeln(`    node [shape=record];`);

    ast.accept(new AstDotPrinter());

    writeln(`}`);
}

