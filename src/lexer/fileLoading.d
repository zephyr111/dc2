/* Copyright (c) 2018 <Jérôme Richard>
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

module lexer.fileLoading;

import std.stdio;
import std.range;
import std.algorithm.iteration;
import std.file;
import std.utf;
import std.path;
import std.format;
import std.file;
import std.traits;
import std.exception;
import std.conv;
import interfaces : IErrorHandler;
import lexer.locationTracking;
import lexer.trigraphSubstitution;
import lexer.lineSplicing;
import lexer.ppcTokenization;
import lexer.preprocessing;
import lexer.macros;
import lexer.stringConcatenation;
import lexer.stdTokenization;


final class FileManager
{
    private
    {
        alias PpcTokenizationRange = ReturnType!tokenizedLoad;
        alias PreprocessingRange = Preprocessing!PpcTokenizationRange;
        alias StdTokenizationRange = StdTokenization!(StringConcatenation!PreprocessingRange);

        enum maxNestingLevel = 200;
        enum _defaultSystemPaths = ["/usr/include/x86_64-linux-musl/"];
        enum _stdFiles = ["assert.h", "locale.h", "stddef.h", "ctype.h",
                                "math.h", "stdio.h", "errno.h", "setjmp.h",
                                "stdlib.h", "float.h", "signal.h", "string.h",
                                "limits.h", "stdarg.h", "time.h"];

        IErrorHandler _errorHandler;
        string[string] _contentCache;
        string[] _userIncludePaths = [];
    }


    this(IErrorHandler errorHandler)
    {
        _errorHandler = errorHandler;

        alias errMsg = filename => format!"standard file `%s` not found"(filename);
        foreach(filename ; _stdFiles)
            assertNotThrown(locate(filename, true), errMsg(filename));
    }

    // Append an include path the the end of the user include path list
    public void addIncludePath(string includePath)
    {
        _userIncludePaths ~= includePath;
    }

    // Return the list of include path (in the highest-priority-first order)
    public auto includePaths() const
    {
        return chain(_userIncludePaths, _defaultSystemPaths);
    }

    // Find the true system file path from an include directive string
    private auto locate(string filename, bool isGlobal, string workingDirectory = ".")
    {
        alias fileExists = a => a.exists && (a.isFile || a.isSymlink);

        // Search the file in the default/user includes paths first
        // whatever the type of include
        foreach(includePath ; includePaths)
        {
            auto filePath = chainPath(includePath, filename);

            if(fileExists(filePath.save))
                return filePath.to!string;
        }

        if(!isGlobal)
        {
            auto filePath = chainPath(workingDirectory, filename);

            if(fileExists(filePath.save))
                return filePath.to!string;
        }

        throw new FileException(format!"unable to locate the file `%s`"(filename));
    }

    // Use an internal cache to get the content of already loaded files faster
    private auto load(string filePath)
    {
        auto foundContent = filePath in _contentCache;

        if(foundContent !is null)
            return *foundContent;

        try
            return (_contentCache[filePath] = readText(filePath));
        catch(FileException)
            throw new FileException(format!"unable to open the file `%s`"(filePath));
        catch(UTFException)
            throw new FileException(format!"unable to decode the file `%s` using UTF-8"(filePath));
    }

    private auto tokenizedLoad(string filename)
    {
        auto content = load(filename);

        version(withUnicodeInput)
            auto wideContent = content.byDchar;
        else
            auto wideContent = content.byChar;

        return wideContent.trackLocation(filename)
                        .substituteTrigraph
                        .spliceLines
                        .ppcTokenize(_errorHandler);
    }

    // Load a file and preprocess its content
    // Can throw a FileException
    public PreprocessingRange preprocessFile(string includedFilename, bool isGlobal, 
                                                string sourceFilename, 
                                                MacroDb macros, int nestingLevel = -1)
    {
        auto finalFilename = locate(includedFilename, isGlobal, 
                                    sourceFilename.dirName);

        // Avoid runaway recursion
        if(nestingLevel+1 >= maxNestingLevel)
            throw new FileException("#include nested too deeply");

        auto tokenized = tokenizedLoad(finalFilename);
        return tokenized.preprocess(this, _errorHandler, macros, nestingLevel+1);
    }

    // Compute only preprocessing phases for a given file
    public PreprocessingRange precomputeFile(string filename)
    {
        auto tokenized = tokenizedLoad(filename);
        return tokenized.preprocess(this, _errorHandler);
    }

    // Compute all lexing phases for a given file
    public StdTokenizationRange computeFile(string filename)
    {
        auto preprocessed = precomputeFile(filename);
        return preprocessed.concatStrings(_errorHandler)
                            .stdTokenize(_errorHandler);
    }
}

