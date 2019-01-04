/* Copyright (c) 2018 <Jérôme Richard>
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

module parser.astBase;

import std.array;
import std.traits;
import std.format;


// UDA used to register class in the AstVisitor interface
enum visited;

// Generate the code of a constructor for AST nodes
string genAstNodeConstructor(TargetClass)()
{
    auto acc = appender!string;

    acc.put("    this(");

    // Foreach attribute
    static foreach(i ; 0..TargetClass.tupleof.length)
    {{
        enum name = TargetClass.tupleof[i].stringof;
        enum type = typeof(__traits(getMember, TargetClass, name)).stringof;

        acc.put(format!"%s %s"(type, name));
        acc.put(", ");
    }}

    acc.put("AstNodeLocation loc)\n    {");
    acc.put("\n        super(loc);");

    // Foreach attribute
    static foreach(i ; 0..TargetClass.tupleof.length)
    {{
        enum name = TargetClass.tupleof[i].stringof;

        acc.put(format!"\n        this.%s = %s;"(name, name));
    }}

    acc.put("\n    }");

    return acc.data.dup;
}

// Generate the code of an accept method needed for visiting classes
string genAstNodeVisitMethod()
{
    //static assert(is(AstVisitor == interface));

    return `    override void accept(AstVisitor visitor)
                {
                    return visitor.visit(this);
                }`;
}

// Generate methods required to be in each AstNode-derived classes
string genAstNodeContent(TargetClass)()
{
    return genAstNodeConstructor!TargetClass ~ "\n" ~ genAstNodeVisitMethod;
}

// Generate a visitor interface based on @visited classes
string genAstVisitorInterface()
{
    auto acc = appender!string;

    // Foreach member of the parser.ast module
    foreach(item; __traits(allMembers, parser.ast))
    {
        alias Alias(alias Symbol) = Symbol;
        alias sym = Alias!(__traits(getMember, parser.ast, item));

        // If the member is a @visited class
        if(is(sym == class) && hasUDA!(sym, visited))
            acc.put(format!"    void visit(%s e);"(sym.stringof));
    }

    return acc.data.dup;
}

bool isVisitedAstNodeType(AstNodeType)()
{
    // If the member is a @visited class
    static if(__traits(hasMember, parser.ast, AstNodeType.stringof))
    {
        // Find the class in the module
        alias Alias(alias Symbol) = Symbol;
        alias sym = Alias!(__traits(getMember, parser.ast, AstNodeType.stringof));

        // If the member is a @visited class
        return (is(sym == interface) || is(sym == class)) && hasUDA!(sym, visited);
    }
    else
    {
        return false;
    }
}

