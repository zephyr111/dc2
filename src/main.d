/* Copyright (c) 2018 <Jérôme Richard>
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

module main;

import std.stdio;
import std.range;
import std.algorithm.searching;
import std.algorithm.iteration;
import std.getopt;
import std.process;
import std.file;

import interfaces.go;
import interfaces.lexer;
import interfaces.parser;
import interfaces.semantics;
import interfaces.errors;

import ErrorHandler;
import lexer;
import parser;
import SemanticAnalyser;


int main(string[] args)
{
    bool preprocessorOnly;
    string[] includePaths;
    auto helpInformation = getopt(args, config.passThrough, 
        config.caseSensitive, "E", "Only run the preprocessor", &preprocessorOnly,
        config.caseSensitive, "I", "Add the directory to the include search path", &includePaths
    );

    if(helpInformation.helpWanted)
    {
        defaultGetoptPrinter("A simple C89 compiler", helpInformation.options);
        return 0;
    }

    if(args[1..$].empty)
    {
        stderr.writeln("error: no input file");
        return 1;
    }

    auto badOptions = args[1..$].filter!(a => a.startsWith('-'));
    auto inputFiles = args[1..$].filter!(a => !a.startsWith('-'));
    auto badInputFiles = inputFiles.filter!(a => !a.exists);
    auto existingInputFiles = inputFiles.filter!(a => a.exists);

    foreach(const arg ; badOptions)
        stderr.writefln("error: unrecognized command line option `%s`", arg);

    if(!badOptions.empty)
        return 1;

    foreach(filename ; badInputFiles)
        stderr.writefln("error: unable to find the file `%s`", filename);

    if(!badInputFiles.empty)
        return 1;

    foreach(filename ; existingInputFiles)
    {
        auto errorHandler = new ErrorHandler(filename);

        try
        {
            auto lexer = new Lexer(filename, errorHandler);
            auto parser = new Parser(lexer, errorHandler);
            auto semAnalyser = new SemanticAnalyser(parser, errorHandler);

            foreach(path ; includePaths)
                lexer.addIncludePath(path);

            foreach(path ; environment.get("CPATH", "").splitter(":").filter!(a => !a.empty))
                lexer.addIncludePath(path);

            if(preprocessorOnly)
            {
                lexer.go();
            }
            else
            {
                // To be continued...
                parser.go();
            }
        }
        catch(HaltException err)
        {
            errorHandler.handleHalt(err);
            errorHandler.printReport();
        }

        if(errorHandler.countErrors > 0)
            return 1;
    }

    return 0;
}

