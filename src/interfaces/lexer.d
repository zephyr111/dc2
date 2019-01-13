/* Copyright (c) 2018 <Jérôme Richard>
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

module interfaces.lexer;

import std.typecons;
public import interfaces.types.tokens;


interface ILexer
{
    public void addIncludePath(string includePath);
    public const(string)[] includePaths() const;
    public Nullable!Token next();
}

