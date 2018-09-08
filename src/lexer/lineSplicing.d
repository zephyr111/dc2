/* Copyright (c) 2018 <Jérôme Richard>
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

module lexer.lineSplicing;

import std.stdio;
import std.range;
import std.range.primitives;
import std.traits;
import std.algorithm.searching;


// Greedy lazy range: consume not more char than requested,
// while eating as much line split as possible
// Cannot take an InputRange as input due to look-ahead parsing
struct LineSplicing(Range)
{
    private
    {
        alias This = typeof(this);

        Range _input;
    }


    this(Range input)
    {
        _input = input;
        trim();
    }

    private void trim()
    {
        while(_input.startsWith('\\') && _input.save.dropOne.startsWith('\n'))
            _input.popFrontExactly(2);
    }

    @property bool empty()
    {
        return _input.empty;
    }

    @property auto front()
    {
        return _input.front;
    }

    void popFront()
    {
        _input.popFront();
        trim();
    }

    @property auto save()
    {
        return This(_input.save);
    }

    @property auto filename() const { return _input.filename; }
    @property auto line() const { return _input.line; }
    @property auto col() const { return _input.col; }
    @property auto pos() const { return _input.pos; }
}

LineSplicing!Range spliceLines(Range)(Range input)
    if(isForwardRange!Range && isSomeChar!(ElementEncodingType!Range) && !isConvertibleToString!Range)
{
    return LineSplicing!Range(input);
}


