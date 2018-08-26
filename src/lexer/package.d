module lexer;

import std.stdio;
import std.range;
import std.file;
import std.utf;
import std.array;
import core.time;
import interfaces;
import lexer.locationTracking;
import lexer.trigraphSubstitution;
import lexer.lineSplicing;
import lexer.ppcTokenization;
import lexer.preprocessing;
import lexer.stringConcatenation;
import lexer.stdTokenization;


pragma(msg, "[BUG] [Issue 19020] findSkip, findSplit and findSplitBefore return wrong results (prefer using findSkip later)");
pragma(msg, "[NOTE] integers and numbers size are bounded by compiler");
pragma(msg, "[CHECK] check support of UTF-8 (code & filenames)");
pragma(msg, "[FIXME] implement TYPE/ENUM/(MACRO?) recognition by interacting with the parser");
public class Lexer : ILexer, IGo
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
        auto acc = appender!string;

        foreach(token ; dstr.trackLocation(_contexts[$-1].filename)
                                .substituteTrigraph
                                .spliceLines
                                .ppcTokenize(_errorHandler)
                                .preprocess(_errorHandler)
                                .concatStrings(_errorHandler)
                                .stdTokenize(_errorHandler))
        {
            //acc.put(token.toString!false);
            tokenCount++;
            //writeln("token: ", token);
        }
        //acc.data.writeln;
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

