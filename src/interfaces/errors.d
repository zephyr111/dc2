/* Copyright (c) 2018 <Jérôme Richard>
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

module interfaces.errors;

import std.exception;


class HaltException : Exception
{
    mixin basicExceptionCtors;
}

interface IErrorHandler
{
    // Note: error and missingFile functions can throw a class
    // derived from IHaltException to stop the program
    void warning(string message, string filename, ulong line, ulong col, ulong sliceLength = 0);
    void error(string message, string filename, ulong line, ulong col, ulong sliceLength = 0);
    void criticalError(string message, string filename, ulong line, ulong col, ulong sliceLength = 0);
    void missingFile(string filename);
    void handleHalt(HaltException err);
    void printReport();
    int countErrors();
}

