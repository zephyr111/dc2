/* Copyright (c) 2018 <Jérôme Richard>
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

module semantics;

import std.stdio;
import interfaces.parser;
import interfaces.semantics;
import interfaces.go;
import interfaces.errors;


class SemanticAnalyser : ISemanticAnalyser
{
    private
    {
        IParser _parser;
        IErrorHandler _errorHandler;
    }

    this(IParser parser, IErrorHandler errorHandler)
    {
        _parser = parser;
        _errorHandler = errorHandler;
    }
}

