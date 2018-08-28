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
import interfaces : IErrorHandler;
import lexer.locationTracking;
import lexer.trigraphSubstitution;
import lexer.lineSplicing;
import lexer.ppcTokenization;
import lexer.preprocessing;
import lexer.macros;
import lexer.stringConcatenation;
import lexer.stdTokenization;


pragma(msg, "[OPTION] check the CPATH environment variable");
pragma(msg, "[OPTION] check user-specified additional include paths");
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
        string[string] _locateCache;
        string _workingDirectory;
        string[] _userIncludePaths = [];
    }


    this(IErrorHandler errorHandler, string workingDirectory = null)
    {
        _errorHandler = errorHandler;

        if(workingDirectory is null)
            _workingDirectory = getcwd();
        else
            _workingDirectory = absolutePath(workingDirectory);

        alias errMsg = filename => format!"standard file `%s` not found"(filename);
        foreach(filename ; _stdFiles)
            assertNotThrown(locate(filename, true), errMsg(filename));
    }

    @property public string workingDirectory()
    {
        return _workingDirectory;
    }

    public void addIncludePath(string includePath)
    {
        _userIncludePaths ~= absolutePath(includePath, _workingDirectory);
    }

    public auto includePaths() const
    {
        return chain(_defaultSystemPaths, _userIncludePaths);
    }

    // Use an internal cache to fetch the file path of already located files faster
    public string locate(string filename, bool isGlobal)
    {
        auto foundPath = filename in _locateCache;

        if(foundPath !is null)
            return *foundPath;

        if(!isGlobal)
        {
            pragma(msg, "[FIXME] local file inclusion does not works well")
            auto filePath = filename.absolutePath(_workingDirectory);

            if(filePath.exists && (filePath.isFile || filePath.isSymlink))
            {
                _locateCache[filename] = filePath;
                return filePath;
            }
        }

        // Search the file in the include paths
        foreach(includePath ; includePaths)
        {
            auto path = absolutePath(filename, includePath);

            if(path.exists && (path.isFile || path.isSymlink))
            {
                _locateCache[filename] = path;
                return path;
            }
        }

        throw new FileException(format!"unable to locate the file `%s`"(filename));
    }

    // Use an internal cache to get the content of already loaded files faster
    private auto load(string filePath)
    {
        auto foundContent = filePath in _contentCache;

        if(foundContent !is null)
            return *foundContent;

        string content;

        try
            content = readText(filePath);
        catch(FileException)
            throw new FileException(format!"unable to open the file `%s`"(filePath));
        catch(UTFException)
            throw new FileException(format!"unable to decode the file `%s` using UTF-8"(filePath));

        _contentCache[filePath] = content;
        return content;
    }

    private auto tokenizedLoad(string filePath, string filename)
    {
        auto content = load(filePath);
        auto wideContent = content.byDchar;
        return wideContent.trackLocation(filename)
                        .substituteTrigraph
                        .spliceLines
                        .ppcTokenize(_errorHandler);
    }

    // Load a file and preprocess its content
    // Can throw a FileException
    public PreprocessingRange preprocessFile(string filename, bool isGlobal, MacroDb macros, int nestingLevel = -1)
    {
        auto filePath = locate(filename, isGlobal);

        // Avoid runaway recursion
        if(nestingLevel+1 >= maxNestingLevel)
            throw new FileException("#include nested too deeply");

        auto tokenized = tokenizedLoad(filePath, filename);
        return tokenized.preprocess(this, _errorHandler, macros, nestingLevel+1);
    }

    // Compute only preprocessing phases for a given file
    public PreprocessingRange precomputeFile(string filename)
    {
        auto tokenized = tokenizedLoad(filename, filename);
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

