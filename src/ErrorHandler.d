module ErrorHandler;

import std.stdio;
import std.format;
import interfaces;


class ErrorHandler : IErrorHandler
{
    private
    {
        string _filename;
        int _count = 0;
    }

    this(string filename)
    {
        _filename = filename;
    }

    override void warning(string message, string filename, ulong line, ulong col, ulong sliceLength = 0)
    {
        stderr.writefln("%s:%d:%d: warning: %s", filename, line, col, message);
    }

    override void error(string message, string filename, ulong line, ulong col, ulong sliceLength = 0)
    {
        stderr.writefln("%s:%d:%d: error: %s", filename, line, col, message);
        _count++;

        /*if(_count >= 5)
        {
            stderr.writeln("compilation halted: too many errors");
            halt();
        }*/
    }

    override void missingFile(string filename)
    {
        stderr.writeln("critical error: cannot open file \"%s\"".format(filename));
        halt();
    }

    override void handleHalt(HaltException err)
    {

    }

    override void printReport()
    {
        stderr.writefln("%d error(s) has occured", _count);
    }

    override int countErrors()
    {
        return _count;
    }

    private
    {
        void halt()
        {
            throw new HaltException("[program halted]");
        }
    }
}

