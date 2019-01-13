/* Copyright (c) 2018 <Jérôme Richard>
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

module errorHandling;

import std.stdio;
import std.format;
import interfaces.errors;


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

    override void criticalError(string message, string filename, ulong line, ulong col, ulong sliceLength = 0)
    {
        stderr.writefln("%s:%d:%d: critical error: %s", filename, line, col, message);
        _count++;
        halt();
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

