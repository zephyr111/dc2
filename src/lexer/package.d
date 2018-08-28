module lexer;

import std.stdio;
import std.range;
import std.algorithm.iteration;
import std.algorithm.mutation;
import std.traits;
import std.typecons;
import std.path;
import core.time;
import interfaces;
import lexer.fileLoading;
import lexer.types;


pragma(msg, "[BUG] [Issue 19020] findSkip, findSplit and findSplitBefore return wrong results (prefer using findSkip later)");
pragma(msg, "[NOTE] integers and numbers size are bounded by compiler");
pragma(msg, "[CHECK] check support of UTF-8 (code & filenames)");
pragma(msg, "[FIXME] implement TYPE/ENUM/(MACRO?) recognition by interacting with the parser");
public class Lexer : ILexer, IGo
{
    private
    {
        alias Range = ReturnType!(FileManager.computeFile);

        string _filename;
        IErrorHandler _errorHandler;
        FileManager _fileManager;
        Range _input;
        Nullable!StdToken result;
        bool _first = true;
    }


    this(string filename, IErrorHandler errorHandler)
    {
        _filename = filename;
        _fileManager = new FileManager(errorHandler, filename.dirName);
        _errorHandler = errorHandler;
    }

    override Nullable!StdToken next()
    {
        if(_first)
            _input = _fileManager.computeFile(_filename);
        _first = false;

        if(_input.empty)
            return Nullable!Token();

        auto res = _input.front.nullable;
        _input.popFront();
        return res;
    }

    override public void addIncludePath(string includePath)
    {
        _fileManager.addIncludePath(includePath);
    }

    override public const(string)[] includePaths() const
    {
        return _fileManager.includePaths().array;
    }

    // Only preprocessing
    override public void go()
    {
        version(report)
        {
            ulong tokenCount = 0;
            auto startTime = MonoTime.currTime;
        }

        auto ppcTokens = _fileManager.precomputeFile(_filename);
        auto stringified = ppcTokens.move.map!(a => a.toString!false);

        version(report)
            writeln(stringified.move.tee!((a) {tokenCount++;}).join);
        else
            writeln(stringified.move.join);

        version(report)
        {
            auto endTime = MonoTime.currTime;
            writefln("Report:");
            writefln("    - Completion time: %s", endTime-startTime);
            writefln("    - Number of tokens found: %d", tokenCount);
        }
    }
}

